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

import HA.Service
import HA.Services.Monitor.CEP
import HA.Services.Monitor.Types

monitoring :: Process ()
monitoring = runProcessor emptyMonitorState monitorRules

remotableDecl [ [d|
    monitorService :: MonitorConf -> Process ()
    monitorService _ = monitoring

    monitor :: Service MonitorConf
    monitor = Service
              monitorServiceName
              $(mkStaticClosure 'monitorService)
              ($(mkStatic 'someConfigDict)
                `staticApply` $(mkStatic 'configDictMonitorConf))
    |] ]

prepareMonitorService :: (Service MonitorConf, MonitorConf)
prepareMonitorService = (HA.Services.Monitor.monitor, MonitorConf)
