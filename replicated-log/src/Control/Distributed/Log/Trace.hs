-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Provides tracing functions.
--

module Control.Distributed.Log.Trace where

import Control.Distributed.Process
import Control.Distributed.Process.Scheduler
import Control.Monad (when)
import System.Environment
import System.IO
import System.IO.Unsafe

-- | A tracing function for debugging purposes.
logTrace :: String -> Process ()
logTrace msg = do
    let b = unsafePerformIO $
              maybe False (elem "replicated-log" . words)
                <$> lookupEnv "HALON_TRACING"
    when b $ if schedulerIsEnabled
      then do self <- getSelfPid
              liftIO $ hPutStrLn stderr $
                show self ++ ": [replicated-log] " ++ msg
      else say $ "[replicated-log] " ++ msg
