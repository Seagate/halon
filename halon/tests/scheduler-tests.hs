-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}

module Main where

import qualified HA.Autoboot.Tests (tests)
import qualified HA.RecoverySupervisor.Tests (tests)
import Test.Run (runTests)

import Control.Concurrent
import Control.Exception
import Control.Monad
import Test.Tasty (testGroup)
import System.Posix.Env (setEnv)


main :: IO ()
main = do
  setEnv "DP_SCHEDULER_ENABLED" "1" True
  tid <- myThreadId
  _ <- forkIO $ do threadDelay (30 * 60 * 1000000)
                   forever $ do threadDelay 100000
                                throwTo tid (ErrorCall "Timeout")
  runTests $ \transport ->
    (testGroup "halon" . (:[]) . testGroup "scheduler") <$> sequence
      [ testGroup "RS" <$> HA.RecoverySupervisor.Tests.tests transport
      , testGroup "AB" <$> HA.Autoboot.Tests.tests transport
      ]
