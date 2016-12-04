-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell            #-}
module HA.RecoveryCoordinator.Castor.Cluster.Events
  (
  -- * Requests
    ClusterStatusRequest(..)
  , ClusterStartRequest(..)
  , ClusterStartResult(..)
  , ClusterStopRequest(..)
  , StopMeroClientRequest(..)
  , StartMeroClientRequest(..)
  , StateChangeResult(..)
  , PoolRebalanceRequest(..)
  , PoolRebalanceStarted(..)
  , PoolRepairRequest(..)
  , PoolRepairStartResult(..)
  , ClusterResetRequest(..)
    -- ** Node
  , StartCastorNodeRequest(..)
  , StartProcessesOnNodeRequest(..)
  , StartProcessesOnNodeResult(..)
  , StopProcessesOnNodeRequest(..)
  , StopProcessesOnNodeResult(..)
  , StartHalonM0dRequest(..)
  , StopHalonM0dRequest(..)
  , StartClientsOnNodeRequest(..)
  , StartClientsOnNodeResult(..)
  , StopClientsOnNodeRequest(..)
  , M0KernelResult(..)
  -- * Process
  , StopProcessesRequest(..)
  , StopProcessesResult(..)
  -- * Cluster state report
  , ReportClusterState(..)
  , ReportClusterHost(..)
  , ReportClusterProcess(..)
  -- * Internal events
  , ClusterStateChange(..)
  -- * Debug
  , MarkProcessesBootstrapped(..)
  -- * Cluster stop monitoring
  , MonitorClusterStop(..)
  , ClusterStopDiff(..)
  ) where

import Control.Distributed.Process
import qualified HA.Resources as R
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import qualified HA.Resources.Castor as Castor
import HA.Aeson
import HA.SafeCopy
import Data.Binary
import Data.Typeable
import Mero.ConfC
import GHC.Generics

data ClusterStatusRequest = ClusterStatusRequest (SendPort ReportClusterState) deriving (Eq,Show,Generic)

data ClusterStartRequest = ClusterStartRequest deriving (Eq, Show, Generic, Ord)

data ClusterStartResult
      = ClusterStartOk
      | ClusterStartTimeout [(M0.Node, [(M0.Process, M0.ProcessState)])]
      | ClusterStartFailure String [StartProcessesOnNodeResult] [StartClientsOnNodeResult]
      deriving (Eq, Show, Generic, Typeable)
instance Binary ClusterStartResult

data ClusterStopRequest = ClusterStopRequest (SendPort StateChangeResult) deriving (Eq, Show, Generic)

newtype StopMeroClientRequest = StopMeroClientRequest Fid deriving (Eq, Show, Generic)

newtype StartMeroClientRequest = StartMeroClientRequest Fid deriving (Eq, Show, Generic)

data StateChangeResult
      = StateChangeError String
      | StateChangeOngoing M0.MeroClusterState
      | StateChangeStarted ProcessId
      | StateChangeFinished
      deriving (Show, Generic, Eq)

instance Binary StateChangeResult

newtype PoolRebalanceRequest = PoolRebalanceRequest M0.Pool
  deriving (Eq, Show, Ord, Typeable, Generic)

data PoolRebalanceStarted = PoolRebalanceStarted M0.Pool
                          | PoolRebalanceFailedToStart M0.Pool
  deriving (Show, Eq, Ord, Typeable, Generic)
instance Binary PoolRebalanceStarted 

newtype PoolRepairRequest = PoolRepairRequest M0.Pool
  deriving (Eq, Show, Ord, Typeable, Generic)

data PoolRepairStartResult
  = PoolRepairStarted M0.Pool
  | PoolRepairFailedToStart M0.Pool String
  deriving (Show, Eq, Ord, Typeable, Generic)

instance Binary PoolRepairStartResult

-- | Internal event sent when the cluster changes state.
data ClusterStateChange =
    ClusterStateChange
      (Maybe M0.MeroClusterState) -- Old state (if it exists)
      M0.MeroClusterState -- New state
  deriving (Eq, Show, Generic, Typeable)

instance Binary ClusterStateChange

-- | Request sent to reset the cluster. This should be done if the cluster
--   gets into a 'stuck' state from which we cannot recover in the regular
--   manner. In general, 'reset' should only be called if the cluster is in
--   a 'steady state' - e.g. there should be no SMs running.
--
--   The optional Bool parameter determines whether to do a deeper reset,
--   which will also purge the EQ and restart the RC.
newtype ClusterResetRequest = ClusterResetRequest Bool
  deriving (Eq, Show, Typeable, Generic)

data ReportClusterState = ReportClusterState
      { csrStatus     :: Maybe M0.MeroClusterState
      , csrSNS        :: [(M0.Pool, M0.PoolRepairStatus)]
      , csrInfo       :: Maybe (M0.Profile, M0.Filesystem)
      , csrStats      :: Maybe M0.FilesystemStats
      , csrHosts      :: [(Castor.Host, ReportClusterHost)]
      } deriving (Eq, Show, Typeable, Generic)

instance Binary ReportClusterState
instance ToJSON ReportClusterState
instance FromJSON ReportClusterState

data ReportClusterHost = ReportClusterHost
      { crnNodeFid    :: Maybe M0.Node
      , crnNodeStatus :: M0.StateCarrier M0.Node
      , crnProcesses  :: [(M0.Process, ReportClusterProcess)]
      , crpDevices    :: [( M0.SDev
                          , M0.StateCarrier M0.SDev
                          , Castor.StorageDevice
                          , [Castor.DeviceIdentifier]
                          )]
      } deriving (Eq, Show, Typeable, Generic, Ord)

instance Binary ReportClusterHost
instance ToJSON ReportClusterHost
instance FromJSON ReportClusterHost

data ReportClusterProcess = ReportClusterProcess
      { crpState    :: M0.ProcessState
      , crpServices :: [(M0.Service, M0.ServiceState)]
      } deriving (Eq, Show, Typeable, Generic, Ord)

instance Binary ReportClusterProcess
instance ToJSON ReportClusterProcess
instance FromJSON ReportClusterProcess


newtype StartCastorNodeRequest = StartCastorNodeRequest R.Node deriving (Eq, Show, Generic, Binary)

newtype StartHalonM0dRequest = StartHalonM0dRequest M0.Node
  deriving (Eq, Show, Typeable, Generic)

newtype StopHalonM0dRequest = StopHalonM0dRequest M0.Node
  deriving (Eq, Show, Typeable, Generic)

-- | Request start of the 'ruleNewNode'.
newtype StartProcessesOnNodeRequest = StartProcessesOnNodeRequest M0.Node
  deriving (Eq, Show, Generic, Ord)

newtype StopProcessesOnNodeRequest = StopProcessesOnNodeRequest M0.Node
          deriving (Eq, Show, Generic, Ord)

data StopProcessesOnNodeResult
       = StopProcessesOnNodeOk
       | StopProcessesOnNodeTimeout
       | StopProcessesOnNodeStateChanged M0.MeroClusterState
       deriving (Eq, Show, Generic)

instance Binary StopProcessesOnNodeResult

newtype StartClientsOnNodeRequest = StartClientsOnNodeRequest M0.Node
         deriving (Eq, Show, Generic, Ord)

data StartClientsOnNodeResult
       = ClientsStartOk M0.Node
       | ClientsStartFailure M0.Node String
       deriving (Eq, Show, Generic)
instance Binary StartClientsOnNodeResult

newtype StopClientsOnNodeRequest = StopClientsOnNodeRequest M0.Node
         deriving (Eq, Show, Generic, Binary, Ord)

-- | Result of trying to start the M0 Kernel
data M0KernelResult
    = KernelStarted M0.Node
    | KernelStartFailure M0.Node
  deriving (Eq, Show, Generic)

-- | Result of @StartProcessesOnNodeRequest@
data StartProcessesOnNodeResult
      = NodeProcessesStarted M0.Node
      | NodeProcessesStartTimeout M0.Node [(M0.Process, M0.ProcessState)]
      | NodeProcessesStartFailure M0.Node [(M0.Process, M0.ProcessState)]
  deriving (Eq, Show, Generic)

instance Binary StartProcessesOnNodeResult

-- | Request to stop specific processes on a node. This event
--   differs from @StopProcessesOnNodeRequest@ as that stops
--   all processes on the node in a staged manner. This event
--   should stop the precise processes without caring about the
--   overall cluster state.
data StopProcessesRequest = StopProcessesRequest M0.Node [M0.Process]
  deriving (Eq, Ord, Show, Generic)

-- | Result of stopping processes. Note that in general most
--   downstream rules will not care about this, as they will
--   directly use the process state change notification.
data StopProcessesResult =
    StopProcessesResult M0.Node [(M0.Process, M0.ProcessState)]
  | StopProcessesTimeout M0.Node [M0.Process]
  deriving (Eq, Show, Generic)

instance Binary StopProcessesResult

-- | Request to mark all processes as finished mkfs.
newtype MarkProcessesBootstrapped = MarkProcessesBootstrapped (SendPort ())
  deriving (Eq, Show, Generic, Typeable)

-- * Messages used for cluster stop monitoring

-- | Signal that the 'ProcessId' is interested in
-- 'ClusterStopProgress' messages.
newtype MonitorClusterStop = MonitorClusterStop ProcessId
  deriving (Show, Eq, Typeable, Generic)

data ClusterStopDiff = ClusterStopDiff
  { _csp_procs :: [(M0.Process, M0.ProcessState, M0.ProcessState)]
    -- ^ @(Process, old state, new state)@
  , _csp_servs :: [(M0.Service, M0.ServiceState, M0.ServiceState)]
    -- ^ @(Service, old state, new state)@
  , _csp_disposition :: Maybe (M0.Disposition, M0.Disposition)
    -- ^ Cluster 'M0.Disposition'
  , _csp_progress :: (Rational, Rational)
    -- ^ Percentage of cluster stopped, @(old, new)@
  , _csp_cluster_stopped :: Bool
    -- ^ Is cluster considered stopped
  , _csp_warnings :: [String]
    -- ^ Any warnings user could want to see found when calculating the diff.
  }
  deriving (Show, Eq, Typeable, Generic)

instance Binary ClusterStopDiff

deriveSafeCopy 0 'base ''ClusterResetRequest
deriveSafeCopy 0 'base ''ClusterStartRequest
deriveSafeCopy 0 'base ''ClusterStatusRequest
deriveSafeCopy 0 'base ''ClusterStopRequest
deriveSafeCopy 0 'base ''M0KernelResult
deriveSafeCopy 0 'base ''MarkProcessesBootstrapped
deriveSafeCopy 0 'base ''MonitorClusterStop
deriveSafeCopy 0 'base ''PoolRebalanceRequest
deriveSafeCopy 0 'base ''PoolRepairRequest
deriveSafeCopy 0 'base ''StartClientsOnNodeRequest
deriveSafeCopy 0 'base ''StartHalonM0dRequest
deriveSafeCopy 0 'base ''StartMeroClientRequest
deriveSafeCopy 0 'base ''StartProcessesOnNodeRequest
deriveSafeCopy 0 'base ''StopHalonM0dRequest
deriveSafeCopy 0 'base ''StopMeroClientRequest
deriveSafeCopy 0 'base ''StopProcessesOnNodeRequest
deriveSafeCopy 0 'base ''StopProcessesRequest
