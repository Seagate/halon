{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Rank2Types        #-}
{-# LANGUAGE TemplateHaskell   #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.DecisionLog
    ( DecisionLogConf(..)
    , EntriesLogged(..)
    , decisionLog
    , decisionLogService
    , decisionLogServiceName
    , fileOutput
    , processOutput
    , standardOutput
    , HA.Services.DecisionLog.Types.__remoteTable
    , __remoteTableDecl
    , decisionLogService__sdict
    , decisionLogService__tdict
    , decisionLog__static
    , printLogs
    ) where

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static
import Network.CEP

import HA.Service
import HA.Services.DecisionLog.CEP
import HA.Services.DecisionLog.Types

makeDecisionLogProcess ::  Definitions () () -> Process ()
makeDecisionLogProcess rules = execute () rules

decisionLogServiceName :: ServiceName
decisionLogServiceName = ServiceName "decision-log"

remotableDecl [ [d|
    decisionLogService :: DecisionLogConf -> Process ()
    decisionLogService (DecisionLogConf out) = do
        let wl = newWriteLogs out
        makeDecisionLogProcess $ decisionLogRules wl

    decisionLog :: Service DecisionLogConf
    decisionLog = Service
                  decisionLogServiceName
                  $(mkStaticClosure 'decisionLogService)
                  ($(mkStatic 'someConfigDict)
                    `staticApply` $(mkStatic 'configDictDecisionLogConf))
    |] ]
