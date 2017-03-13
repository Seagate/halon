{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TypeFamilies      #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.DecisionLog
    ( DecisionLogConf(..)
    , decisionLog
    , traceLogs
    , processOutput
    , decisionLog__static
    , HA.Services.DecisionLog.Types.__remoteTable
    , HA.Services.DecisionLog.Types.__resourcesTable
    , __remoteTableDecl
    ) where

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static

import HA.Service
import HA.Services.DecisionLog.Types
import HA.Services.DecisionLog.Logger
import HA.Services.DecisionLog.Trace

import System.IO (stdout, stderr)

type instance ServiceState DecisionLogConf = (Logger, Logger)

-- for tets.
processOutput :: ProcessId -> DecisionLogConf
processOutput ps = DecisionLogConf LogDP (TraceProcess ps)

newLogger :: DecisionLogOutput -> Logger
newLogger (LogTextFile path)   = mkLogger $ mkTextPrinter (dumpTextToFile path) (return ())
newLogger (LogBinaryFile path) = mkLogger $ mkBinaryPrinter (dumpBinaryToFile path) (return ())
newLogger LogDP                = mkLogger $ mkTextPrinter dumpTextToDp (return ())
newLogger LogStdout            = mkLogger $ mkTextPrinter (dumpTextToHandle stdout) (return ())
newLogger LogStderr            = mkLogger $ mkTextPrinter (dumpTextToHandle stderr) (return ())
newLogger LogDB{}              = error "not yet implemented"

remotableDecl [ [d|

    decisionLogFunctions :: ServiceFunctions DecisionLogConf
    decisionLogFunctions = ServiceFunctions  bootstrap mainloop teardown confirm where
      bootstrap (DecisionLogConf logOpts traceOpts) = do
         let logger = newLogger logOpts
         let tracer = newTracer traceOpts
         return (Right (logger, tracer))
      mainloop _ (logger,tracer) = return
        [ match $ \msg -> do
            logger' <- writeLogs logger msg
            tracer' <- writeLogs tracer msg
            return (Continue, (logger', tracer'))
        ]
      teardown _ (logger, tracer) = do
        closeLogger logger
        closeLogger tracer
      confirm  _ _ = return ()

    decisionLog :: Service DecisionLogConf
    decisionLog = Service "decision-log"
                  $(mkStaticClosure 'decisionLogFunctions)
                  ($(mkStatic 'someConfigDict)
                    `staticApply` $(mkStatic 'configDictDecisionLogConf))
    |] ]
