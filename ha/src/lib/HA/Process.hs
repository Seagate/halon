-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Convenience functions use 'Process'.
--

module HA.Process where

import Control.Distributed.Process
import Control.Distributed.Process.Internal.Types (LocalNode)
import Control.Distributed.Process.Node (runProcess)

import Control.Concurrent (myThreadId, throwTo)
import Control.Exception (SomeException)

-- | Taken from "Control.Distributed.Process.Platform.Test".
tryRunProcess :: LocalNode -> Process () -> IO ()
tryRunProcess node p = do
  tid <- liftIO myThreadId
  runProcess node $ catch p (\e -> liftIO $ throwTo tid (e::SomeException))
