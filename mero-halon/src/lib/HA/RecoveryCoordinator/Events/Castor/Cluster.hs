-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module HA.RecoveryCoordinator.Events.Castor.Cluster
  (
  -- * Requests
    ClusterStatusRequest(..)
  , ClusterStartRequest(..)
  , ClusterStopRequest(..)
  , StopMeroClientRequest(..)
  , StartMeroClientRequest(..)
  , StateChangeResult(..)
  , PoolRebalanceRequest(..)
  , PoolRepairRequest(..)
    -- ** Node
  , StartCastorNodeRequest(..)
  , StartProcessesOnNodeRequest(..)
  , StopProcessesOnNodeRequest(..)
  , StopProcessesOnNodeResult(..)
  , StartHalonM0dRequest(..)
  , StopHalonM0dRequest(..)
  , StartClientsOnNodeRequest(..)
  , M0KernelResult(..)
  , StartProcessesOnNodeResult(..)
  -- * Process
  , StopProcessesRequest(..)
  , StopProcessesResult(..)
  -- * Cluster state report
  , ReportClusterState(..)
  , ReportClusterHost(..)
  , ReportClusterProcess(..)
  -- * Internal events
  , BarrierPass(..)
  ) where

import Control.Distributed.Process
import qualified HA.Resources as R
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import qualified HA.Resources.Castor as Castor
import Data.Binary
import Data.Typeable
import Mero.ConfC
import Data.Aeson

import GHC.Generics

data ClusterStatusRequest = ClusterStatusRequest (SendPort ReportClusterState) deriving (Eq,Show,Generic)
instance Binary ClusterStatusRequest

data ClusterStartRequest = ClusterStartRequest (SendPort StateChangeResult) deriving (Eq, Show, Generic)
instance Binary ClusterStartRequest

data ClusterStopRequest = ClusterStopRequest (SendPort StateChangeResult) deriving (Eq, Show, Generic)
instance Binary ClusterStopRequest

newtype StopMeroClientRequest = StopMeroClientRequest Fid deriving (Eq, Show, Generic, Binary)

newtype StartMeroClientRequest = StartMeroClientRequest Fid deriving (Eq, Show, Generic, Binary)

data StateChangeResult
      = StateChangeError String
      | StateChangeOngoing M0.MeroClusterState
      | StateChangeStarted ProcessId
      | StateChangeFinished
      deriving (Show, Generic, Eq)

instance Binary StateChangeResult

newtype PoolRebalanceRequest = PoolRebalanceRequest M0.Pool
  deriving (Eq, Show, Binary, Typeable, Generic)

newtype PoolRepairRequest = PoolRepairRequest M0.Pool
  deriving (Eq, Show, Binary, Typeable, Generic)

-- | Notification that barrier was passed by the cluster.
newtype BarrierPass = BarrierPass M0.MeroClusterState deriving (Binary, Show)

data ReportClusterState = ReportClusterState
      { csrStatus     :: Maybe M0.MeroClusterState
      , csrSNS        :: [(M0.Pool, M0.PoolRepairInformation)]
      , csrInfo       :: Maybe (M0.Profile, M0.Filesystem)
      , csrHosts      :: [(Castor.Host, ReportClusterHost)]
      } deriving (Eq, Show, Typeable, Generic)

instance Binary ReportClusterState
instance ToJSON ReportClusterState
instance FromJSON ReportClusterState

data ReportClusterHost = ReportClusterHost
      { crnNodeStatus :: M0.StateCarrier M0.Node
      , crnProcesses  :: [(M0.Process, ReportClusterProcess)]
      , crpDevices    :: [(M0.SDev, M0.StateCarrier M0.SDev)]
      } deriving (Eq, Show, Typeable, Generic)

instance Binary ReportClusterHost
instance ToJSON ReportClusterHost
instance FromJSON ReportClusterHost

data ReportClusterProcess = ReportClusterProcess
      { crpState    :: M0.ProcessState
      , crpServices :: [(M0.Service, M0.ServiceState)]
      } deriving (Eq, Show, Typeable, Generic)

instance Binary ReportClusterProcess
instance ToJSON ReportClusterProcess
instance FromJSON ReportClusterProcess


newtype StartCastorNodeRequest = StartCastorNodeRequest R.Node deriving (Eq, Show, Generic, Binary)

newtype StartHalonM0dRequest = StartHalonM0dRequest M0.Node
  deriving (Eq, Show, Typeable, Generic, Binary)

newtype StopHalonM0dRequest = StopHalonM0dRequest M0.Node
  deriving (Eq, Show, Typeable, Generic, Binary)

-- | Request start of the 'ruleNewNode'.
newtype StartProcessesOnNodeRequest = StartProcessesOnNodeRequest M0.Node
  deriving (Eq, Show, Generic, Binary, Ord)

newtype StopProcessesOnNodeRequest = StopProcessesOnNodeRequest M0.Node
          deriving (Eq, Show, Generic, Binary, Ord)

data StopProcessesOnNodeResult
       = StopProcessesOnNodeOk
       | StopProcessesOnNodeTimeout
       | StopProcessesOnNodeStateChanged M0.MeroClusterState
       deriving (Eq, Show, Generic)

instance Binary StopProcessesOnNodeResult

newtype StartClientsOnNodeRequest = StartClientsOnNodeRequest M0.Node
         deriving (Eq, Show, Generic, Binary, Ord)

-- | Result of trying to start the M0 Kernel
data M0KernelResult
    = KernelStarted M0.Node
    | KernelStartFailure M0.Node
  deriving (Eq, Show, Generic)

instance Binary M0KernelResult

-- | Result of @StartProcessesOnNodeRequest@
data StartProcessesOnNodeResult
      = NodeProcessesStarted M0.Node
      | NodeProcessesStartTimeout M0.Node
      | NodeProcessesStartFailure M0.Node
  deriving (Eq, Show, Generic)

instance Binary StartProcessesOnNodeResult

-- | Request to stop specific processes on a node. This event
--   differs from @StopProcessesOnNodeRequest@ as that stops
--   all processes on the node in a staged manner. This event
--   should stop the precise processes without caring about the
--   overall cluster state.
data StopProcessesRequest = StopProcessesRequest M0.Node [M0.Process]
  deriving (Eq, Ord, Show, Generic)

instance Binary StopProcessesRequest

-- | Result of stopping processes. Note that in general most
--   downstream rules will not care about this, as they will
--   directly use the process state change notification.
data StopProcessesResult =
    StopProcessesResult M0.Node [(M0.Process, M0.ProcessState)]
  | StopProcessesTimeout M0.Node [M0.Process]
  deriving (Eq, Show, Generic)

instance Binary StopProcessesResult
