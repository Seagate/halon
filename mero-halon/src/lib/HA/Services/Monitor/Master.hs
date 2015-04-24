{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
-- |
-- Copyright: (C) 2015  Seagate LLC
--
module HA.Services.Monitor.Master where

import Data.Typeable
import GHC.Generics

import Data.Binary
import Data.Hashable
import Options.Schema

import HA.Service
import HA.Service.TH
import HA.Services.Monitor.Types (Processes, emptyProcesses)

-- | Master Monitor service main configuration.
data MasterMonitorConf =
    MasterMonitorConf Processes
    deriving (Eq, Generic, Show, Typeable)

instance Binary MasterMonitorConf
instance Hashable MasterMonitorConf

emptyMasterMonitorConf :: MasterMonitorConf
emptyMasterMonitorConf = MasterMonitorConf emptyProcesses

masterMonitorConf :: Processes -> MasterMonitorConf
masterMonitorConf = MasterMonitorConf

masterMonitorSchema :: Schema MasterMonitorConf
masterMonitorSchema = pure emptyMasterMonitorConf

masterMonitorServiceName :: ServiceName
masterMonitorServiceName = ServiceName "master-monitor"

$(generateDicts ''MasterMonitorConf)
$(deriveService ''MasterMonitorConf 'masterMonitorSchema [])
