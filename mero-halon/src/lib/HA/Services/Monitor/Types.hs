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
import Control.Distributed.Process.Internal.Types (remoteTable, processNode)
import Control.Distributed.Static (unstatic)
import Control.Monad.Reader
import Data.Binary
import Data.Binary.Get (runGet)
import Data.Binary.Put (runPut)
import Data.Hashable
import Options.Schema

import HA.ResourceGraph
import HA.Service
import HA.Service.TH

-- | Monitor service main configuration.
data MonitorConf = MonitorConf Processes deriving (Eq, Generic, Show, Typeable)

instance Binary MonitorConf
instance Hashable MonitorConf

emptyMonitorConf :: MonitorConf
emptyMonitorConf = MonitorConf emptyProcesses

monitorConf :: Processes -> MonitorConf
monitorConf = MonitorConf

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

emptyProcesses :: Processes
emptyProcesses = Processes []

monitorSchema :: Schema MonitorConf
monitorSchema = pure emptyMonitorConf

monitorServiceName :: ServiceName
monitorServiceName = ServiceName "monitor"

masterMonitorServiceName :: ServiceName
masterMonitorServiceName = ServiceName "master-monitor"

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
$(deriveService ''MonitorConf 'monitorSchema [])
