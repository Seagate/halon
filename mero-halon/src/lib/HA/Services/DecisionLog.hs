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
    ) where

import System.IO

import           Control.Distributed.Process
import           Control.Distributed.Process.Closure
import           Control.Distributed.Static
import qualified Data.ByteString.Lazy as Lazy
import           Data.ByteString.Lazy.Char8 (pack)
import           Network.CEP

import HA.Service
import HA.Services.DecisionLog.CEP
import HA.Services.DecisionLog.Types

makeDecisionLogProcess ::  Definitions () () -> Process ()
makeDecisionLogProcess rules = execute () rules

decisionLogServiceName :: ServiceName
decisionLogServiceName = ServiceName "decision-log"

cleanupHandle :: Handle -> Process ()
cleanupHandle h = liftIO $ hClose h

mkWriteLogs :: DecisionLogOutput -> (WriteLogs -> Process ()) -> Process ()
mkWriteLogs (FileOutput path) k =
    bracket (openLogFile path) cleanupHandle $ \h -> do
      let wl = WriteLogs $ \logs -> liftIO $ do
            Lazy.hPut h $ pack $ show logs
            Lazy.hPut h "\n"

      k wl
mkWriteLogs (ProcessOutput pid) k =
    k $ WriteLogs (usend pid)
mkWriteLogs StandardOutput k =
    let wl = WriteLogs $ \logs -> liftIO $ putStrLn $ show logs in k wl

openLogFile :: FilePath -> Process Handle
openLogFile path = liftIO $ do
    h <- openFile path AppendMode
    hSetBuffering h LineBuffering
    return h

remotableDecl [ [d|
    decisionLogService :: DecisionLogConf -> Process ()
    decisionLogService (DecisionLogConf out) =
        mkWriteLogs out (makeDecisionLogProcess . decisionLogRules)

    decisionLog :: Service DecisionLogConf
    decisionLog = Service
                  decisionLogServiceName
                  $(mkStaticClosure 'decisionLogService)
                  ($(mkStatic 'someConfigDict)
                    `staticApply` $(mkStatic 'configDictDecisionLogConf))
    |] ]
