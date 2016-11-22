{-# LANGUAGE GADTs #-}
module HA.Services.DecisionLog.Trace
  ( newTracer
  , traceLogs
  ) where

import qualified Data.ByteString.Lazy as B
import qualified Data.ByteString.Lazy.Char8 as B8
import qualified Data.Aeson as JSON
import Data.Binary
import Control.Distributed.Process
import Data.Functor (void)
import Data.Time (getCurrentTime)
import System.IO
import Network.CEP.Log as CL
import HA.RecoveryCoordinator.Log as Log

import HA.Services.DecisionLog.Types
import HA.Services.DecisionLog.Logger

-- | Create new logger that will dump raw traces.
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
