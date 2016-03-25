-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.

import Test (tests)

import Control.Distributed.Process.Scheduler
import Test.Driver

import Control.Concurrent
import Control.Exception
import Control.Monad
import Test.Tasty (testGroup)
import Test.Tasty.Environment
import System.Posix.Env (setEnv)


main :: IO ()
main = do
    setEnv "DP_SCHEDULER_ENABLED" "1" True
    (testArgs, runnerArgs) <- parseArgs
    tid <- myThreadId
    _ <- forkIO $ do threadDelay (30 * 60 * 1000000)
                     forever $ do threadDelay 100000
                                  throwTo tid (ErrorCall "Timeout")
    if schedulerIsEnabled then
      defaultMainWithArgs
        (fmap ( testGroup "replicated-log"
              . (: []) . testGroup "scheduler") . tests
              )
        testArgs
        runnerArgs
    else
      error "The scheduler is not enabled."
