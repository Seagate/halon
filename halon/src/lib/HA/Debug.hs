-- |
-- Copyright: (C) 2016-2018 Seagate Technology LLC and/or its Affiliates
-- License:   Apache License, Version 2.0
--
-- Debug functions that make use of eventlog subsystem.
-- Eventlog provides a way to offline monitor program. And
-- especially useful during developemnt process and benchmarking.
--
-- To read more about perfomance profiling refer to
-- <http://www.well-typed.com/blog/2014/02/ghc-events-analyze/>
module HA.Debug
  ( labelProcess
  , spawnLocalName
  , traceMarkerP
  , traceEventP
  ) where

import Control.Distributed.Process (Process, ProcessId, liftIO, spawnLocal)
import GHC.Conc (labelThread, myThreadId)
import Debug.Trace (traceEventIO, traceMarkerIO)
import Network.CEP (MonadProcess(liftProcess))

-- | Add label to the 'Process', this way haskell thread
-- will have a label in the event logs.
labelProcess :: String -> Process ()
labelProcess label = liftIO $ do
  tid <- myThreadId
  labelThread tid label

-- | Works like 'spawnLocal' but additionally set label to
-- the new process. Same as
--
-- @spawnLocal $ labelProcess label >> action@
spawnLocalName :: String -> Process () -> Process ProcessId
spawnLocalName label action = spawnLocal $ labelProcess label >> action

-- | Lifted version of the 'traceMarkerIO'.
traceMarkerP :: MonadProcess p => String -> p ()
traceMarkerP = liftProcess . liftIO . traceMarkerIO

-- | Lifted version of the 'traceEventIO'.
traceEventP :: MonadProcess p => String -> p ()
traceEventP = liftProcess . liftIO . traceEventIO
