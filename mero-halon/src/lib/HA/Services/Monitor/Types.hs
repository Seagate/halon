{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE TemplateHaskell           #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
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
import HA.Service
import HA.Service.TH

data MonitorConf = MonitorConf deriving (Eq, Generic, Show, Typeable)

instance Binary MonitorConf
instance Hashable MonitorConf

data Monitored = forall a. Configuration a => Monitored ProcessId (Service a)

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

newtype Processes =
    Processes [Slot]
    deriving (Show, Eq, Typeable, Binary, Hashable)

data Monitor = Monitor deriving (Eq, Show, Typeable, Generic)

instance Binary Monitor
instance Hashable Monitor

resourceDictProcesses :: Dict (Resource Processes)
resourceDictProcesses = Dict

relationDictMonitorProcesses :: Dict (
    Relation Monitor (Service MonitorConf) Processes
    )
relationDictMonitorProcesses = Dict

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
                                             ])

instance Resource Processes where
    resourceDict = $(mkStatic 'resourceDictProcesses)

instance Relation Monitor (Service MonitorConf) Processes where
    relationDict = $(mkStatic 'relationDictMonitorProcesses)
