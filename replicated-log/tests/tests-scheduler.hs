-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.

import Test (tests)

import Test.Driver
import Test.Tasty.Environment

import Control.Distributed.Process.Scheduler
import System.Posix.Env (setEnv)


main :: IO ()
main = do
   setEnv "DP_SCHEDULER_ENABLED" "1" True
   (testArgs, runnerArgs) <- parseArgs
   if schedulerIsEnabled then
     defaultMainWithArgs tests testArgs runnerArgs
   else
     error "The scheduler is not enabled."
