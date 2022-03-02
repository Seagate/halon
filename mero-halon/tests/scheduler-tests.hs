{-# LANGUAGE CPP #-}

-- |
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.

module Main (main) where

import           Control.Concurrent
import           Control.Exception
import           Control.Monad
import           Data.Proxy
import qualified HA.Autoboot.Tests
import qualified HA.RecoveryCoordinator.Tests
import           HA.Replicator.Log
import qualified HA.Test.Disconnect
import           Network.Transport (Transport)
import           Network.Transport.InMemory
import           System.Posix.Env (setEnv)
import           Test.Tasty (TestTree, defaultMainWithIngredients, testGroup)
import           Test.Tasty.HUnit (testCase)
import           Test.Tasty.Ingredients.Basic (consoleTestReporter)
import           Test.Tasty.Ingredients.FileReporter (fileTestReporter)

main :: IO ()
main = do
    setEnv "DP_SCHEDULER_ENABLED" "1" True
    tid <- myThreadId

    _ <- forkIO $ do threadDelay (30 * 60 * 1000000)
                     forever $ do threadDelay 100000
                                  throwTo tid (ErrorCall "Timeout")
    transport <- createTransport
    defaultMainWithIngredients [fileTestReporter [consoleTestReporter]]
      $ tests transport
  where
    pg = Proxy :: Proxy RLogGroup

    tests :: Transport -> TestTree
    tests transport = testGroup "mero-halon:scheduler"
      [ testCase "testServiceRestarting" $
           HA.RecoveryCoordinator.Tests.testServiceRestarting transport pg
      , testCase "testServiceNotRestarting" $
          HA.RecoveryCoordinator.Tests.testServiceNotRestarting transport pg
      , testCase "testEQTrimming" $
          HA.RecoveryCoordinator.Tests.testEQTrimming transport pg
      , testCase "testServiceStopped" $
          HA.RecoveryCoordinator.Tests.testServiceStopped transport pg
      , testGroup "Autoboot" $
          HA.Autoboot.Tests.tests transport
      , HA.Test.Disconnect.tests transport
          (error "scheduler-tests: breakConnection not supplied in test")
      ]
