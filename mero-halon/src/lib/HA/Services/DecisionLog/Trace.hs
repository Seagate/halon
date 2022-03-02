{-# LANGUAGE GADTs #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- decision-log trace facilities
module HA.Services.DecisionLog.Trace
  ( newTracer
  , traceLogs
  ) where

import           Control.Distributed.Process
import           Data.Binary
import qualified Data.ByteString.Lazy as B
import qualified Data.ByteString.Lazy.Char8 as B8
import           Data.Functor (void)
import           Data.Time (getCurrentTime)
import qualified HA.Aeson as JSON
import           HA.RecoveryCoordinator.Log as Log
import           HA.Services.DecisionLog.Logger
import           HA.Services.DecisionLog.Types
import           Network.CEP.Log as CL
import           System.IO

-- | Create new logger that will dump raw traces.
--
-- No fancy sends are needed here: logger processes are co-located and
-- linked to main process so they are guaranteed to be the same
-- version.
newTracer :: TraceLogOutput -> Logger
newTracer TraceNull = self where
  self = Logger loop
  loop :: LoggerQuery a -> Process a
  loop WriteLogger{} = return self
  loop CloseLogger = return ()
newTracer TraceTextDP = self where
  self = Logger loop
  loop :: LoggerQuery a -> Process a
  loop (WriteLogger x) = say (B8.unpack $ JSON.encode x) >> return self
  loop CloseLogger = return ()
newTracer (TraceProcess p) = self where
  self = Logger loop
  loop :: LoggerQuery a -> Process a
  loop (WriteLogger x) = usend p x >> return self
  loop CloseLogger = return ()
newTracer (TraceText path) = self where
  self = Logger loop
  loop :: LoggerQuery a -> Process a
  loop (WriteLogger lg) = liftIO $ withFile path AppendMode $ \h -> do
    hPutStrLn h . show =<< getCurrentTime
    B8.hPutStrLn h $ JSON.encode lg
    return self
  loop CloseLogger = return ()
newTracer (TraceBinary path) = self where
   self = Logger loop
   loop :: LoggerQuery a -> Process a
   loop (WriteLogger lg) = liftIO $ withBinaryFile path AppendMode $ \h -> do
     B.hPut h (encode lg)
     return self
   loop CloseLogger = return ()

-- | Helper for default trace storage.
traceLogs :: CL.Event Log.Event -> Process ()
traceLogs msg = void $ writeLogs (newTracer TraceTextDP) msg
