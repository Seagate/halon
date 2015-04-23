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

import Data.ByteString.Lazy (ByteString)
import Data.Typeable
import GHC.Generics

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Internal.Types (remoteTable, processNode)
import Control.Distributed.Static (unstatic)
import Control.Monad.Reader
import Data.Binary
import Data.Binary.Get (runGet)
import Data.Binary.Put (runPut)
import Data.Hashable
import Options.Schema

import HA.ResourceGraph
import HA.Resources
import HA.Service
import HA.Service.TH

-- | Monitor service main configuration.
data MonitorConf = MonitorConf deriving (Eq, Generic, Show, Typeable)

instance Binary MonitorConf
instance Hashable MonitorConf

-- | Used to carry a monitored service information. We hold a 'Service' value
-- to be able to send a proper 'ServiceFailed' message to the RC.
data Monitored = forall a. Configuration a =>
                 Monitored
                 { monPid :: !ProcessId
                   -- ^ Process where the `Service` is run.
                 , monSvc :: !(Service a)
                 }

-- | A resource used to retrieve Master Monitor 'ProcessId'.
data MasterMonitor = MasterMonitor deriving (Eq, Ord, Show, Typeable, Generic)

instance Binary MasterMonitor
instance Hashable MasterMonitor

-- | A 'MonitoredSerialized' hold a serialized 'Monitored' value. It's used as a
--   mean to store a monitored service to the ResourceGraph.
newtype MonitoredSerialized =
    MonitoredSerialized ByteString
    deriving (Eq, Typeable, Binary, Hashable)

instance Show MonitoredSerialized where
    show _ = "MonitoredSerialized <<binary data>>"

-- | 'Processes' gathers every monitored services (serialized) from a
--   'Monitor'. Its only purpose is to be stored in the ReplicatedGraph.
newtype Processes =
    Processes [MonitoredSerialized]
    deriving (Show, Eq, Typeable, Binary, Hashable)

-- | A 'Relation' that allows retrieving monitor's 'Processes' out of
--   'ServiceProcess'.
data Monitor = Monitor deriving (Eq, Show, Typeable, Generic)

instance Binary Monitor
instance Hashable Monitor

resourceDictProcesses :: Dict (Resource Processes)
resourceDictProcesses = Dict

resourceDictMasterMonitor :: Dict (Resource MasterMonitor)
resourceDictMasterMonitor = Dict

relationDictMonitorProcesses :: Dict (
    Relation Monitor (ServiceProcess MonitorConf) Processes
    )
relationDictMonitorProcesses = Dict

relationDictClusterMasterMonitorServiceProcess :: Dict (
    Relation Cluster MasterMonitor (ServiceProcess MonitorConf)
    )
relationDictClusterMasterMonitorServiceProcess = Dict

monitorSchema :: Schema MonitorConf
monitorSchema = pure MonitorConf

monitorServiceName :: ServiceName
monitorServiceName = ServiceName "monitor"

-- | Deserializes a 'Monitored' out of a 'MonitoredSerialized'.
deserializedMonitored :: MonitoredSerialized -> Process Monitored
deserializedMonitored (MonitoredSerialized bs) =
    asks (go . remoteTable . processNode)
  where
    go rt = runGet (action rt) bs

    action rt = do
        d <- get
        case unstatic rt d of
          Right (SomeConfigurationDict (Dict :: Dict (Configuration s))) -> do
            pid                <- get
            (svc :: Service s) <- get
            return $ Monitored pid svc
          Left e -> error ("decode Monitored: " ++ e)

-- | Serialize a 'Monitored' to a 'MonitoredSerialized'.
encodeMonitored :: Monitored -> MonitoredSerialized
encodeMonitored (Monitored pid svc@(Service _ _ d)) =
    MonitoredSerialized $ runPut $ do
      put d
      put pid
      put svc

$(generateDicts ''MonitorConf)
$(deriveService ''MonitorConf 'monitorSchema [ 'relationDictMonitorProcesses
                                             , 'resourceDictProcesses
                                             , 'relationDictClusterMasterMonitorServiceProcess
                                             , 'resourceDictMasterMonitor
                                             ])

instance Resource Processes where
    resourceDict = $(mkStatic 'resourceDictProcesses)

instance Resource MasterMonitor where
    resourceDict = $(mkStatic 'resourceDictMasterMonitor)

instance Relation Monitor (ServiceProcess MonitorConf) Processes where
    relationDict = $(mkStatic 'relationDictMonitorProcesses)

instance Relation Cluster MasterMonitor (ServiceProcess MonitorConf) where
    relationDict = $(mkStatic 'relationDictClusterMasterMonitorServiceProcess)
