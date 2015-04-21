{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.Monitor
    ( MonitorConf
    , monitorServiceName
    , prepareMonitorService
    , HA.Services.Monitor.Types.__remoteTable
    , __remoteTableDecl
    , monitorService__sdict
    , monitorService__tdict
    , monitor__static
    , monitorServiceRules
    ) where

import Control.Distributed.Process hiding (monitor)
import Control.Distributed.Process.Closure
import Control.Distributed.Static
import Network.CEP

import HA.EventQueue.Producer
import HA.RecoveryCoordinator.Mero (GetMultimapProcessId(..), LoopState)
import HA.Resources (Node(..))
import HA.Service
import HA.Services.Monitor.CEP
import HA.Services.Monitor.Types

timeout :: Int
timeout = 10 * 1000000

remotableDecl [ [d|
    monitorService :: MonitorConf -> Process ()
    monitorService _ = _monitoring

    _monitoring :: Process ()
    _monitoring = do
        mmid <- _lookupMultiMapPid
        st   <- loadPrevProcesses monitor mmid
        _spawnHeartbeatProcess
        runProcessor st monitorRules

    _lookupMultiMapPid :: Process ProcessId
    _lookupMultiMapPid = do
        self <- getSelfPid
        _    <- promulgate (GetMultimapProcessId self)
        res  <- expectTimeout timeout
        case res of
          Just pid -> return pid
          _        -> do
            let node = Node $ processNodeId self
                msg  = encodeP $ ServiceFailed node monitor self
            promulgate msg

    _spawnHeartbeatProcess :: Process ()
    _spawnHeartbeatProcess = do
        self <- getSelfPid
        _    <- spawnLocal $ heartbeatProcess self
        return ()

    monitor :: Service MonitorConf
    monitor = Service
              monitorServiceName
              $(mkStaticClosure 'monitorService)
              ($(mkStatic 'someConfigDict)
                `staticApply` $(mkStatic 'configDictMonitorConf))
    |] ]

prepareMonitorService :: (Service MonitorConf, MonitorConf)
prepareMonitorService = (monitor, MonitorConf)

monitorServiceRules :: RuleM LoopState ()
monitorServiceRules = monitorServiceRulesF monitor
