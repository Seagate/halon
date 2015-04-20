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
    ) where

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static
import Network.CEP

import HA.EventQueue.Producer
import HA.RecoveryCoordinator.Mero (GetMultimapProcessId(..))
import HA.ResourceGraph
import HA.Service
import HA.Services.Monitor.CEP
import HA.Services.Monitor.Types

remotableDecl [ [d|
    monitorService :: MonitorConf -> Process ()
    monitorService _ = _monitoring

    _monitoring :: Process ()
    _monitoring = do
        self <- getSelfPid
        _    <- promulgate (GetMultimapProcessId self)
        mmid <- expect
        st   <- loadPrevProcesses mmid
        runProcessor st (monitorRules mmid)
      where
        loadPrevProcesses mmid = do
            rg <- getGraph mmid
            case connectedTo monitor Monitor rg of
              [ps] -> monitorState ps
              _    -> return emptyMonitorState

    monitor :: Service MonitorConf
    monitor = Service
              monitorServiceName
              $(mkStaticClosure 'monitorService)
              ($(mkStatic 'someConfigDict)
                `staticApply` $(mkStatic 'configDictMonitorConf))
    |] ]

prepareMonitorService :: (Service MonitorConf, MonitorConf)
prepareMonitorService = (HA.Services.Monitor.monitor, MonitorConf)
