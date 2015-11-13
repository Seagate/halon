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
    ( MonitorConf
    , SaveProcesses(..)
    , SetMasterMonitor(..)
    , MasterMonitor(..)
    , masterMonitorServiceName
    , monitorServiceName
    , masterMonitor
    , regularMonitor
    , HA.Services.Monitor.Types.__remoteTable
    , __remoteTableDecl
    , regularMonitor__static
    , masterMonitor__static
    , emptyMonitorConf
    -- * Internal
    , monitorProcess
    , MonitorType(..)
    ) where

import Control.Distributed.Process hiding (monitor)
import Control.Distributed.Process.Closure
import Control.Distributed.Static
import Network.CEP

import HA.EventQueue.Producer (promulgate)
import HA.Service
import HA.Services.Monitor.CEP
import HA.Services.Monitor.Types

spawnHeartbeatProcess :: Process ()
spawnHeartbeatProcess = do
    self <- getSelfPid
    _    <- spawnLocal $ link self >> heartbeatProcess self
    return ()

monitorProcess :: MonitorType -> Process ()
monitorProcess typ = run `finally` logDeath
  where
    run = do
      self <- getSelfPid
      say $ show typ ++ " Monitor started on " ++ show self
      spawnHeartbeatProcess
      bootstrapMonitor typ
      execute emptyMonitorState monitorRules
    logDeath = do
      say $ show typ ++ " Monitor exit."

bootstrapMonitor :: MonitorType -> Process ()
bootstrapMonitor Regular = return ()
bootstrapMonitor Master  = do
    pid <- getSelfPid
    _   <- promulgate $ SetMasterMonitor (ServiceProcess pid)
    return ()

remotableDecl [ [d|

    _monitorService :: MonitorConf -> Process ()
    _monitorService MonitorConf = monitorProcess Regular

    _masterMonitorService :: MonitorConf -> Process ()
    _masterMonitorService MonitorConf = monitorProcess Master

    regularMonitor :: Service MonitorConf
    regularMonitor = Service
        monitorServiceName
        $(mkStaticClosure '_monitorService)
        ($(mkStatic 'someConfigDict)
          `staticApply` $(mkStatic 'configDictMonitorConf))

    masterMonitor :: Service MonitorConf
    masterMonitor = Service
        masterMonitorServiceName
        $(mkStaticClosure '_masterMonitorService)
        ($(mkStatic 'someConfigDict)
          `staticApply` $(mkStatic 'configDictMonitorConf))
    |] ]
