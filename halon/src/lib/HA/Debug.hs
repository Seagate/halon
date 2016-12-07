-- |
-- Copyright:  (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Debug functions that make use of eventlog subsystem.
module HA.Debug
  ( labelProcess
  , spawnLocalName
  , traceMarkerP
  ) where

import Control.Distributed.Process
import GHC.Conc
import Debug.Trace

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
traceMarkerP :: String -> Process ()
traceMarkerP = liftIO . traceMarkerIO
