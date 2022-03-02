-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.

{-# LANGUAGE CPP #-}

module Main where

import qualified HA.Autoboot.Tests (tests)
import qualified HA.RecoverySupervisor.Tests (tests)
import HA.Replicator.Log
import Test.Run (runTests)

import Control.Concurrent
import Control.Exception
import Control.Monad
import Data.Proxy
import Test.Tasty (testGroup)
import System.Posix.Env (setEnv)


main :: IO ()
main = do
  setEnv "DP_SCHEDULER_ENABLED" "1" True
  tid <- myThreadId
  _ <- forkIO $ do threadDelay (30 * 60 * 1000000)
                   forever $ do threadDelay 100000
                                throwTo tid (ErrorCall "Timeout")
  let pg = Proxy :: Proxy RLogGroup
  runTests $ \transport ->
    (testGroup "halon" . (:[]) . testGroup "scheduler") <$> sequence
      [ testGroup "RS" <$> HA.RecoverySupervisor.Tests.tests transport pg
      , testGroup "AB" <$> HA.Autoboot.Tests.tests transport
      ]
