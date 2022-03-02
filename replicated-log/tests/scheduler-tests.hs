-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.

import Test (tests)

import Control.Distributed.Process.Scheduler

import Control.Concurrent
import Control.Exception
import Control.Monad
import Test.Tasty
import Test.Tasty.Environment
import Test.Tasty.Ingredients.FileReporter
import Test.Tasty.Ingredients.Basic
import System.Posix.Env (setEnv)
import System.Environment (withArgs)


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

defaultMainWithArgs :: ([String] -> IO TestTree)
                    -- ^ Action taking a list of 'String' from stdarg and returning
                    -- 'Tests's to run.
                    -> [String]
                    -- ^ Arguments to pass to tast framework.
                    -> [String]
                    -- ^ Arguments to pass to test creation action.
                    -> IO ()
defaultMainWithArgs testsF runnerArgs testArgs = do
    testsF testArgs >>= withArgs runnerArgs .
      defaultMainWithIngredients [fileTestReporter [consoleTestReporter]]
