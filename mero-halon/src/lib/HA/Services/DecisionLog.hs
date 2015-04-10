{-# LANGUAGE Rank2Types      #-}
{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.DecisionLog
    ( DecisionLogConf(..)
    , EntriesLogged(..)
    , decisionLog
    , decisionLogService
    , decisionLogServiceName
    , HA.Services.DecisionLog.Types.__remoteTable
    , __remoteTableDecl
    , decisionLogService__sdict
    , decisionLogService__tdict
    , decisionLog__static
    ) where

import System.IO

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static
import Network.CEP

import HA.Service
import HA.Services.DecisionLog.CEP
import HA.Services.DecisionLog.Types

makeDecisionLogProcess :: (forall s. RuleM s ()) -> Process a
makeDecisionLogProcess rules = runProcessor () rules

decisionLogServiceName :: ServiceName
decisionLogServiceName = ServiceName "decision-log"

cleanupHandle :: Handle -> Process ()
cleanupHandle h = liftIO $ hClose h

openLogFile :: FilePath -> Process Handle
openLogFile path = liftIO $ do
    h <- openFile path AppendMode
    hSetBuffering h LineBuffering
    return h

remotableDecl [ [d|
    decisionLogService :: DecisionLogConf -> Process ()
    decisionLogService (DecisionLogConf path) =
        bracket (openLogFile path) cleanupHandle $ \h ->
          makeDecisionLogProcess $ decisionLogRules h

    decisionLog :: Service DecisionLogConf
    decisionLog = Service
                  decisionLogServiceName
                  $(mkStaticClosure 'decisionLogService)
                  ($(mkStatic 'someConfigDict)
                    `staticApply` $(mkStatic 'configDictDecisionLogConf))
    |] ]
