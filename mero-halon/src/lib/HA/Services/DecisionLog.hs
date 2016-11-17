{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TypeFamilies      #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.DecisionLog
    ( DecisionLogConf(..)
    , EntriesLogged(..)
    , decisionLog
    , fileOutput
    , processOutput
    , standardOutput
    , HA.Services.DecisionLog.Types.__remoteTable
    , __remoteTableDecl
    , decisionLog__static
    , printLogs
    ) where

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static

import HA.Service
import HA.Services.DecisionLog.Types

type instance ServiceState DecisionLogConf = WriteLogs

remotableDecl [ [d|

    decisionLogFunctions :: ServiceFunctions DecisionLogConf
    decisionLogFunctions = ServiceFunctions  bootstrap mainloop teardown confirm where
      bootstrap (DecisionLogConf out) =
         return (Right (newWriteLogs out))
      mainloop _ wl =
        return [match $ \logs -> writeLogs wl logs >> return (Continue, wl) ]
      teardown _ _ = return ()
      confirm  _ _ = return () 

    decisionLog :: Service DecisionLogConf
    decisionLog = Service "decision-log"
                  $(mkStaticClosure 'decisionLogFunctions)
                  ($(mkStatic 'someConfigDict)
                    `staticApply` $(mkStatic 'configDictDecisionLogConf))
    |] ]
