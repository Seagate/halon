{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright: (C) 2015  Seagate LLC
--
-- Monitor Service. A monitor track every service started by the Resource
-- Coordinator (RC). When a service died, monitor notifies the RC. Currently,
-- there are 2 types of monitors. Master monitor and node monitor.
--
-- Master monitor manages every node monitor. There is only one per tracking
-- station.
--
-- Node monitors manage every service started by the RC (monitor excluded).
-- There is one node monitor per node.
--
-- Despite of a different name, Master and Node monitors share the same
-- set of CEP rules. There are small differences on how they are
-- bootstrapped.
module HA.Services.Monitor
    ( MasterMonitorConf
    , MonitorConf
    , Processes
    , SaveMasterProcesses(..)
    , SaveProcesses(..)
    , masterMonitorServiceName
    , monitorServiceName
    , masterMonitor
    , regularMonitor
    , HA.Services.Monitor.__remoteTable
    , __remoteTableDecl
    , regularMonitorService__sdict
    , regularMonitorService__tdict
    , masterMonitorService__sdict
    , masterMonitorService__tdict
    , regularMonitor__static
    , masterMonitor__static
    , emptyMonitorConf
    , emptyMasterMonitorConf
    , monitorConf
    ) where

import Control.Distributed.Process hiding (monitor)
import Control.Distributed.Process.Closure
import Control.Distributed.Static
import Network.CEP

import HA.Service
import HA.Services.Monitor.CEP
import HA.Services.Monitor.Master
import HA.Services.Monitor.Types

spawnHeartbeatProcess :: Process ()
spawnHeartbeatProcess = do
    self <- getSelfPid
    _    <- spawnLocal $ heartbeatProcess self
    return ()

monitorProcess :: MonitorType -> Processes -> Process ()
monitorProcess typ ps = do
    st <- monitorState ps
    spawnHeartbeatProcess
    runProcessor st (monitorRules typ)

remotableDecl [ [d|
    regularMonitorService :: MonitorConf -> Process ()
    regularMonitorService (MonitorConf ps) =
        monitorProcess Regular ps

    masterMonitorService :: MasterMonitorConf -> Process ()
    masterMonitorService (MasterMonitorConf ps) =
        monitorProcess Master ps

    regularMonitor :: Service MonitorConf
    regularMonitor = Service
              monitorServiceName
              $(mkStaticClosure 'regularMonitorService)
              ($(mkStatic 'someConfigDict)
                `staticApply` $(mkStatic 'configDictMonitorConf))

    masterMonitor :: Service MasterMonitorConf
    masterMonitor = Service
              monitorServiceName
              $(mkStaticClosure 'masterMonitorService)
              ($(mkStatic 'someConfigDict)
                `staticApply` $(mkStatic 'configDictMasterMonitorConf))
    |] ]

__remoteTable :: RemoteTable -> RemoteTable
__remoteTable = HA.Services.Monitor.Master.__remoteTable .
                HA.Services.Monitor.Types.__remoteTable
