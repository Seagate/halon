-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}

module Main where

import qualified HA.RecoverySupervisor.Tests (tests)
import Test.Run (runTests)
import Test.Tasty (testGroup)

import System.Posix.Env (setEnv)


main :: IO ()
main = do
  setEnv "DP_SCHEDULER_ENABLED" "1" True
  runTests $ \transport -> testGroup "scheduler" <$> sequence
      [ testGroup "RS" <$> HA.RecoverySupervisor.Tests.tests transport ]
