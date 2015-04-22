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

data MonitorConf = MonitorConf deriving (Eq, Generic, Show, Typeable)

instance Binary MonitorConf
instance Hashable MonitorConf

data Monitored = forall a. Configuration a => Monitored ProcessId (Service a)

data MasterMonitor = MasterMonitor deriving (Eq, Ord, Show, Typeable, Generic)

instance Binary MasterMonitor
instance Hashable MasterMonitor

data Slot =
    Slot
    { sPid :: !ProcessId  -- ^ Monitored Process
    , sSvc :: !ByteString -- ^ Serialized Service
    } deriving (Typeable, Generic)

instance Eq Slot where
    Slot p _ == Slot v _ = p == v

instance Binary Slot
instance Hashable Slot

instance Show Slot where
    show (Slot p _) = "Slot " ++ show p

data Processes =
    Processes
    { psNode :: !Node
    , psSlot :: ![Slot]
    }
    deriving (Show, Eq, Typeable, Generic)

instance Binary Processes
instance Hashable Processes

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

decodeSlot :: Slot -> Process Monitored
decodeSlot (Slot _ bs) = fmap go $ asks (remoteTable . processNode)
  where
    go rt = runGet (action rt) bs

    action rt = do
        d <- get
        case unstatic rt d of
          Right (SomeConfigurationDict (Dict :: Dict (Configuration s))) -> do
            pid                <- get
            (svc :: Service s) <- get
            return $ Monitored pid svc
          Left e -> error ("decode Slot: " ++ e)

encodeMonitored :: Monitored -> Slot
encodeMonitored (Monitored pid svc@(Service _ _ d)) =
    Slot pid $ runPut $ do
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
