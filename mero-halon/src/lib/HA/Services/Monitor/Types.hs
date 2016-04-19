{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE TemplateHaskell           #-}
-- |
-- Copyright: (C) 2015  Seagate LLC
--
module HA.Services.Monitor.Types where

import Data.Typeable
import GHC.Generics

import Control.Distributed.Process
import Control.Distributed.Process.Closure (mkStatic)
import Data.Aeson
import Data.Binary
import Data.Hashable
import Options.Schema

import HA.ResourceGraph
import HA.Resources
import HA.Service
import HA.Service.TH

-- | Monitor type. Regular monitor, a.k.a node-local monitor, monitors every
--   services started on a particular node. There is only one regular monitor
--   per node. Master monitor on the other hand, monitors every regular monitors
--   . There is only one Master monitor per cluster.
data MonitorType = Regular | Master deriving Show

-- | Monitor service main configuration.
data MonitorConf = MonitorConf deriving (Eq, Generic, Show, Typeable)

instance Binary MonitorConf
instance Hashable MonitorConf
instance ToJSON MonitorConf

emptyMonitorConf :: MonitorConf
emptyMonitorConf = MonitorConf

-- | Used to carry a monitored service information. We hold a 'Service' value
-- to be able to send a proper 'ServiceFailed' message to the RC.
data Monitored = forall a. Configuration a =>
                 Monitored
                 { monPid :: !ProcessId
                   -- ^ Process where the `Service` is run.
                 , monSvc :: !(Service a)
                   -- ^ Service description.
                 , monRef :: MonitorRef
                   -- ^ Process monitor reference.
                 }

instance Show Monitored where
    show (Monitored pid svc ref ) = "(Monitored on "
                                ++ show pid ++ " - "
                                ++ snString (serviceName svc) ++ " by "
                                ++ show ref ++ ")"

-- | A resource used to retrieve Master Monitor 'ProcessId'.
data MasterMonitor = MasterMonitor deriving (Eq, Ord, Show, Typeable, Generic)

instance Binary MasterMonitor
instance Hashable MasterMonitor

-- | Request to add monitor to services.
data StartMonitoringRequest = StartMonitoringRequest ProcessId [ServiceStartedMsg]
  deriving (Typeable, Generic)

instance Binary StartMonitoringRequest

-- | Acknowledgement to 'StartMonitoringRequest' request.
-- If this reply was delivered this means that monitor started
-- to monitor services.
-- It's ok to send this reply directly to RecoveryCoordinator.
data StartMonitoringReply = StartMonitoringReply
  deriving (Eq, Ord, Show, Typeable, Generic)

instance Binary StartMonitoringReply

monitorSchema :: Schema MonitorConf
monitorSchema = pure emptyMonitorConf

monitorServiceName :: ServiceName
monitorServiceName = ServiceName "monitor"

masterMonitorServiceName :: ServiceName
masterMonitorServiceName = ServiceName "master-monitor"

resourceDictMasterMonitor :: Dict (Resource MasterMonitor)
resourceDictMasterMonitor = Dict

relationDictClusterMasterMonitorServiceProcess :: Dict (
    Relation MasterMonitor Cluster (ServiceProcess MonitorConf)
    )
relationDictClusterMasterMonitorServiceProcess = Dict

$(generateDicts ''MonitorConf)
$(deriveService ''MonitorConf 'monitorSchema [ 'relationDictClusterMasterMonitorServiceProcess
                                             , 'resourceDictMasterMonitor
                                             ])

instance Resource MasterMonitor where
    resourceDict = $(mkStatic 'resourceDictMasterMonitor)

instance Relation MasterMonitor Cluster (ServiceProcess MonitorConf) where
    relationDict = $(mkStatic 'relationDictClusterMasterMonitorServiceProcess)
