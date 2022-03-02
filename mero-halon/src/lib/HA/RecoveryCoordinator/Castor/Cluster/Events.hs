{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StrictData                 #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
-- |
-- Module    : HA.RecoveryCoordinator.Castor.Cluster.Events
-- Copyright : (C) 2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Events pertaining to cluster as a whole.
module HA.RecoveryCoordinator.Castor.Cluster.Events
  (
  -- * Requests
    ClusterStatusRequest(..)
  , ClusterStartRequest(..)
  , ClusterStartResult(..)
  , ClusterStopRequest(..)
  , ClusterStopResult(..)
  , StateChangeResult(..)
  , PoolRebalanceRequest(..)
  , PoolRebalanceStarted(..)
  , PoolRepairRequest(..)
  , PoolRepairStartResult(..)
  , ClusterResetRequest(..)
  -- * Cluster state report
  , ReportClusterState(..)
  , ReportClusterHost(..)
  , ReportClusterProcess(..)
  , ReportClusterService(..)
  , ClusterLiveness(..)
  -- * Internal events
  , ClusterStateChange(..)
  -- * Debug
  , MarkProcessesBootstrapped(..)
  -- * Cluster stop monitoring
  , MonitorClusterStop(..)
  , ClusterStopDiff(..)
  ) where

import           Control.Distributed.Process
import           Data.Binary
import           Data.Typeable
import           GHC.Generics
import           HA.Aeson
import           HA.RecoveryCoordinator.Castor.Node.Events
import qualified HA.Resources.Castor as Castor
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           HA.SafeCopy

-- | Request the status of the cluster.
newtype ClusterStatusRequest =
  ClusterStatusRequest (SendPort ReportClusterState)
  -- ^ Request the status of the cluster. The reply of
  -- 'ReportClusterState' will be sent on the provided 'SendPort'.
  deriving (Eq,Show,Generic)

-- | Request that the cluster starts. Cluster replies with
-- 'ClusterStartResult'.
data ClusterStartRequest = ClusterStartRequest
  deriving (Eq, Show, Generic, Ord)

-- | A reply to 'ClusterStartResult'.
data ClusterStartResult
      = ClusterStartOk
      -- ^ The cluster started OK: no fatal issues were detected
      -- during bootstrap.
      | ClusterStartTimeout [(M0.Node, [(M0.Process, M0.ProcessState)])]
      -- ^ Cluster start timed out. Reports the nodes which failed
      -- along with processes on those nodes which have failed to
      -- properly start and their state.
      | ClusterStartFailure String [StartProcessesOnNodeResult]
      -- ^ Cluster failed to start. Reports the reason as well as
      -- process start results back to the user.
      deriving (Eq, Show, Generic, Typeable)
instance Binary ClusterStartResult

-- | Request that the cluster stops.
data ClusterStopRequest = ClusterStopRequest String (SendPort StateChangeResult)
  -- ^ Request that the cluster stops with the provided reason. The
  -- 'StateChangeResult' is sent back on the provided 'SendPort'.
  deriving (Eq, Show, Generic, Ord)

-- | Request that the cluster stops.
data ClusterStopResult =
  ClusterStopOk
  -- ^ Cluster stopped successfully.
  | ClusterStopFailed String
  -- ^ Cluster failed to stop with the provided reason.
  deriving (Eq, Show, Generic)
instance Binary ClusterStopResult

-- | A reply on 'ClusterStopRequest' channel.
data StateChangeResult =
  StateChangeStarted
  -- ^ The cluster started to shut down.
  | StateChangeFinished
  -- ^ The cluster is already in stopped state.
  deriving (Show, Generic, Eq)
instance Binary StateChangeResult

-- | Request SNS rebalance on the given pool. Replied to with
-- 'PoolRebalanceStarted'.
newtype PoolRebalanceRequest = PoolRebalanceRequest M0.Pool
  deriving (Eq, Show, Ord, Typeable, Generic)

-- | Reply to 'PoolRebalanceRequest'.
data PoolRebalanceStarted =
  PoolRebalanceStarted M0.Pool
  -- ^ SNS rebalance procedure started on the given 'M0.Pool'.
  | PoolRebalanceFailedToStart M0.Pool
  -- ^ SNS rebalance procedure not started on the given 'M0.Pool'.
  deriving (Show, Eq, Ord, Typeable, Generic)
instance Binary PoolRebalanceStarted

-- | Request SNS repair on the given 'M0.Pool'. Replied to with
-- 'PoolRepairStartResult'.
newtype PoolRepairRequest = PoolRepairRequest M0.Pool
  deriving (Eq, Show, Ord, Typeable, Generic)

-- | Reply to 'PoolRepairRequest'.
data PoolRepairStartResult
  = PoolRepairStarted M0.Pool
  -- ^ SNS repair has started on the given 'M0.Pool'.
  | PoolRepairFailedToStart M0.Pool String
  -- ^ SNS repair has failed to start on the given 'M0.Pool' with the
  -- provided reason.
  deriving (Show, Eq, Ord, Typeable, Generic)
instance Binary PoolRepairStartResult

-- | Internal event sent when the cluster changes state.
data ClusterStateChange =
  ClusterStateChange (Maybe M0.MeroClusterState) M0.MeroClusterState
  -- ^ @ClusterStateChange oldState newState@
  deriving (Eq, Show, Generic, Typeable)
instance Binary ClusterStateChange

-- | Request sent to reset the cluster. This should be done if the
-- cluster gets into a 'stuck' state from which we cannot recover in
-- the regular manner. In general, 'reset' should only be called if
-- the cluster is in a 'steady state' - e.g. there should be no SMs
-- running.
data ClusterResetRequest = ClusterResetRequest
  { _crr_deep_reset :: !Bool
  -- ^ Request a deeper reset which will purge the EQ and restart RC.
  } deriving (Eq, Show, Typeable, Generic)

-- | Structure containing information about the cluster state.
data ReportClusterState = ReportClusterState
      { csrStatus     :: Maybe M0.MeroClusterState
      -- ^ Current 'M0.MeroClusterState'.
      , csrSnsPools   :: [(M0.Pool, M0.PoolId)]
      , csrDixPool    :: Maybe M0.Pool
      , csrProfile    :: Maybe M0.Profile
      , csrSNS        :: [(M0.Pool, M0.PoolRepairStatus)]
      -- ^ Ongoing SNS operations.
      , csrStats      :: Maybe M0.FilesystemStats
      , csrHosts      :: [(Castor.Host, ReportClusterHost)]
      -- ^ Information about every 'Castor.Host';
      -- see 'ReportClusterHost' for details.
      , csrPrincipalRM :: Maybe M0.Service
      -- ^ Current principal resource management service.
      } deriving (Eq, Show, Typeable, Generic)

instance Binary ReportClusterState
instance ToJSON ReportClusterState
instance FromJSON ReportClusterState

-- | Information about a 'Castor.Host' inside the cluster.
data ReportClusterHost = ReportClusterHost
      { crnNodeFid    :: Maybe M0.Node
      -- ^ Associated 'M0.Node'.
      , crnNodeStatus :: M0.StateCarrier M0.Node
      -- ^ Halon state of 'crnNodeFid'.
      , crnNodeId     :: Maybe NodeId
      -- ^ NodeId of the associated 'HA.Resources.Node'.
      , crnIsRC       :: Bool
      -- ^ Is this host running RC?
      , crnProcesses  :: [(M0.Process, ReportClusterProcess)]
      -- ^ Information about processes on the cluster. See
      -- 'ReportClusterProcess' for details.
      } deriving (Eq, Show, Typeable, Generic, Ord)

instance Binary ReportClusterHost
instance ToJSON ReportClusterHost
instance FromJSON ReportClusterHost

-- | Information about a 'M0.Process'.
data ReportClusterProcess = ReportClusterProcess
      { cprType :: String
      -- ^ 'Type' of the process, such as ios, m0t1fs etc
      , crpState    :: M0.ProcessState
      -- ^ 'M0.ProcessState' of the 'M0.Process'.
      , crpServices :: [ReportClusterService]
      -- ^ 'M0.Service's and their states associated with this
      -- 'M0.Process'.
      } deriving (Eq, Show, Typeable, Generic, Ord)

instance Binary ReportClusterService
instance ToJSON ReportClusterService
instance FromJSON ReportClusterService

-- | Information about a 'M0.Service'.
data ReportClusterService = ReportClusterService
      { crsState      :: M0.ServiceState
      -- ^ 'M0.ServiceState' of the 'M0.Service'
      , crsService    :: M0.Service
      -- ^ 'M0.Service'
      , crsDevices    :: [( M0.SDev
                          , M0.StateCarrier M0.SDev
                          , Maybe Castor.Slot
                          , Maybe Castor.StorageDevice
                          )]
      -- ^ Information about devices attached at this particular service.
      } deriving (Eq, Show, Typeable, Generic, Ord)

instance Binary ReportClusterProcess
instance ToJSON ReportClusterProcess
instance FromJSON ReportClusterProcess

-- | Request that every process in the cluster as
-- previously-bootstrapped. This means that the processes will not go
-- through configure (mkfs) stage. It should be used with great care
-- during recovery of a cluster after a bad state &c. See
-- 'ruleMarkProcessesBootstrapped'.
newtype MarkProcessesBootstrapped = MarkProcessesBootstrapped (SendPort ())
  deriving (Eq, Show, Generic, Typeable)

-- * Messages used for cluster stop monitoring

-- | Signal that the 'ProcessId' is interested in
-- 'ClusterStopProgress' messages.
newtype MonitorClusterStop = MonitorClusterStop ProcessId
  deriving (Show, Eq, Typeable, Generic)

-- | A structure representing somewhat of a diff between a previous
-- and ‘current’ cluster state. This allows the consumer to report
-- progress (or regress) as cluster is stopping.
data ClusterStopDiff = ClusterStopDiff
  { _csp_procs :: [(M0.Process, M0.ProcessState, M0.ProcessState)]
    -- ^ @(Process, old state, new state)@
  , _csp_servs :: [(M0.Service, M0.ServiceState, M0.ServiceState)]
    -- ^ @(Service, old state, new state)@
  , _csp_disposition :: Maybe (M0.Disposition, M0.Disposition)
    -- ^ Cluster 'M0.Disposition'
  , _csp_progress :: (Rational, Rational)
    -- ^ Percentage of cluster stopped, @(old, new)@
  , _csp_cluster_stopped :: Maybe ClusterStopResult
    -- ^ Is cluster considered stopped
  , _csp_warnings :: [String]
    -- ^ Any warnings user could want to see found when calculating the diff.
  } deriving (Show, Eq, Typeable, Generic)
instance Binary ClusterStopDiff

-- | Cluster liveness information.
data ClusterLiveness = ClusterLiveness
      { clPVers :: Bool
      -- ^ Do we have PVers?
      , clOngoingSNS :: Bool
      -- ^ Is SNS on-going?
      , clHaveQuorum :: Bool
      -- ^ Do we have quorum?
      , clPrincipalRM :: Bool
      -- ^ Is principal RM chosen?
      } deriving (Show, Eq, Typeable, Generic)

deriveSafeCopy 0 'base ''ClusterResetRequest
deriveSafeCopy 0 'base ''ClusterStartRequest
deriveSafeCopy 0 'base ''ClusterStatusRequest
deriveSafeCopy 0 'base ''ClusterStopRequest
deriveSafeCopy 0 'base ''MarkProcessesBootstrapped
deriveSafeCopy 0 'base ''MonitorClusterStop
deriveSafeCopy 0 'base ''PoolRebalanceRequest
deriveSafeCopy 0 'base ''PoolRepairRequest
deriveSafeCopy 0 'base ''ClusterLiveness
