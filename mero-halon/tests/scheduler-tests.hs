{-# LANGUAGE CPP #-}

-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.

module Main where

import qualified HA.Autoboot.Tests
import qualified HA.RecoveryCoordinator.Tests
import qualified HA.RecoveryCoordinator.Mero.Tests
import qualified HA.Test.Disconnect

import Helper.Environment
import Test.Tasty (TestTree, defaultMainWithIngredients, testGroup)
import Test.Tasty.Ingredients.Basic (consoleTestReporter)
import Test.Tasty.Ingredients.FileReporter (fileTestReporter)
import Test.Tasty.HUnit (testCase)

import Control.Concurrent
import Control.Exception
import Control.Monad
import Network.Transport (Transport)
import Network.Transport.InMemory
import System.Environment hiding (setEnv)
import System.Posix.Env (setEnv)
import System.IO

ut :: String -> Transport -> IO TestTree
ut _host transport = return $
    testGroup "mero-halon" $ (:[]) $
    testGroup "scheduler"
      [ testCase "testServiceRestarting" $
          HA.RecoveryCoordinator.Tests.testServiceRestarting transport
      , testCase "testServiceNotRestarting" $
          HA.RecoveryCoordinator.Tests.testServiceNotRestarting transport
      , testCase "testEQTrimming" $
          HA.RecoveryCoordinator.Tests.testEQTrimming transport
      , testCase "testHostAddition" $
          HA.RecoveryCoordinator.Mero.Tests.testHostAddition transport
      , testCase "testDriveAddition" $
          HA.RecoveryCoordinator.Mero.Tests.testDriveAddition transport
      , testCase "testServiceStopped" $
          HA.RecoveryCoordinator.Tests.testServiceStopped transport
      , testCase "testMonitorManagement" $
          HA.RecoveryCoordinator.Tests.testMonitorManagement transport
      , testCase "testMasterMonitorManagement" $
          HA.RecoveryCoordinator.Tests.testMasterMonitorManagement
            transport
      , testCase "testNodeUpRace" $
          HA.RecoveryCoordinator.Tests.testNodeUpRace transport
      , testGroup "Autoboot" $
          HA.Autoboot.Tests.tests transport
      , testCase "testDisconnect" $
          HA.Test.Disconnect.testDisconnect
            transport (error "breakConnection not supplied in test")
#ifdef USE_MERO
        -- Run these two only if we have USE_MERO as we needed some initial
        -- data preloaded
      , testCase "testRejoin" $
          HA.Test.Disconnect.testRejoin
            _host transport (error "breakConnection not supplied in test")
      , testCase "testRejoinTimeout" $
          HA.Test.Disconnect.testRejoinTimeout
            _host transport (error "breakConnection not supplied in test")
      , testCase "testRejoinRCDeath" $
          HA.Test.Disconnect.testRejoinRCDeath
            _host transport (error "breakConnection not supplied in test")
#endif
      ]

runTests :: (Transport -> IO TestTree) -> IO ()
runTests tests = do
    transport <- createTransport
    defaultMainWithIngredients [fileTestReporter [consoleTestReporter]]
      =<< tests transport

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    setEnv "DP_SCHEDULER_ENABLED" "1" True
    tid <- myThreadId
    (host0, _) <- getTestListenSplit

    _ <- forkIO $ do threadDelay (30 * 60 * 1000000)
                     forever $ do threadDelay 100000
                                  throwTo tid (ErrorCall "Timeout")
    runTests (ut host0)
