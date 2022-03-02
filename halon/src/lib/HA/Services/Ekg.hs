{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
-- |
-- Module    : HA.Services.Ekg
-- Copryight : (C) 2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- EKG service. "HA.Services.Ekg.RC" contains the main user interface.
--
-- The data collected by this service is not persisted and does not
-- serve as a knowledge base for the rest of the system. It's for
-- developer information and troubleshooting only.
--
-- This service does not poll information other than default GC
-- information ('registerGcMetrics'). It is up to the user to update
-- any data they wish to observe. It is also up to the user to persist
-- and send any data they wish to display across service restarts.
--
-- There is currently no built-in protection against out-of-order
-- messages. If the user calls 'GaugeSet' (or other similar,
-- destructive command), there is a race on which command gets to the
-- service first.
--
-- TODO: Timestamp destructive commands and throw away any out-of-date
-- messages. For this we need 'Binary' TimeSpec and for this we should
-- move our wrapper out of HA.Resources.Mero.
module HA.Services.Ekg
  ( -- * Core service stuff
    ekg
  , EkgConf(..)
  , EkgState(..)
  , interface
    -- * Metrics
  , CounterCmd(..)
  , CounterContent(..)
  , DistributionCmd(..)
  , DistributionContent(..)
  , DistributionStats(..)
  , EkgMetric(..)
  , GaugeCmd(..)
  , GaugeContent(..)
  , LabelCmd(..)
  , LabelContent(..)
  , ModifyMetric(..)
  , runEkgMetricCmdOnNode
    -- * Generated things
  , HA.Services.Ekg.Types.__remoteTable
  , HA.Services.Ekg.Types.__resourcesTable
  , __remoteTableDecl
  , ekg__static
  ) where

import Control.Concurrent
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static
import Data.ByteString.Char8 (pack)
import Data.Map (empty)
import GHC.Stats (getRTSStatsEnabled)
import HA.Service
import HA.Service.Interface
import HA.Services.Ekg.Types
import System.Remote.Monitoring

type instance ServiceState EkgConf = EkgState

remotableDecl [ [d|

  ekgFunctions :: ServiceFunctions EkgConf
  ekgFunctions = ServiceFunctions bootstrap mainloop teardown confirm where
    bootstrap (EkgConf host port) = do
      liftIO getRTSStatsEnabled >>= \case
        False -> return $ Left "ekg service can't run without -T RTS option"
        True -> do
          s <- liftIO $ forkServer (pack host) port
          return . Right $ EkgState s Data.Map.empty
    mainloop _ st = return
      [ receiveSvc interface $ \mm -> do
          say $ "metrics => Received " ++ show mm
          st' <- runModifyMetric st mm
          return (Continue, st')
      ]
    teardown _ (EkgState s _) = do
      -- TODO: wait for thread to die?
      liftIO . killThread $ serverThreadId s
    confirm _ _ = return ()

  ekg :: Service EkgConf
  ekg = Service (ifServiceName interface)
        $(mkStaticClosure 'ekgFunctions)
        ($(mkStatic 'someConfigDict)
          `staticApply` $(mkStatic 'configDictEkgConf))

 |] ]

-- | Send the 'ModifyMetric' command to the EKG service on the given 'Node'.
--
-- If you're using this command from RC, see "HA.Services.Ekg.RC"
-- module instead.
runEkgMetricCmdOnNode :: NodeId -> ModifyMetric -> Process ()
runEkgMetricCmdOnNode nid cmd = nsendRemote nid (serviceLabel ekg) cmd
