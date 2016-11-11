module HA.Debug
  ( labelProcess
  , spawnLocalName
  , traceMarkerP
  ) where

import Control.Distributed.Process
import GHC.Conc
import Debug.Trace

labelProcess :: String -> Process ()
labelProcess label = liftIO $ do
  tid <- myThreadId
  labelThread tid label

spawnLocalName :: String -> Process () -> Process ProcessId
spawnLocalName label action = spawnLocal $ labelProcess label >> action

-- | Lifted version of the 'traceMarkerIO'
traceMarkerP :: String -> Process ()
traceMarkerP = liftIO . traceMarkerIO
