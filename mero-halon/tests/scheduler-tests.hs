-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.

module Main where

import qualified HA.Autoboot.Tests
import qualified HA.RecoveryCoordinator.Mero.Tests
import qualified HA.Test.Disconnect

import Test.Tasty (TestTree, defaultMainWithIngredients, testGroup)
import Test.Tasty.Ingredients.Basic (consoleTestReporter)
import Test.Tasty.Ingredients.FileReporter (fileTestReporter)
import Test.Tasty.HUnit (testCase)

import Control.Concurrent
import Control.Exception
import Control.Monad
import Network.Transport (Transport)
import Network.Transport.InMemory
import System.IO
import System.Posix.Env (setEnv)


ut :: Transport -> IO TestTree
ut transport = return $
    testGroup "scheduler"
      [ testCase "RCServiceRestarting" $
          HA.RecoveryCoordinator.Mero.Tests.testServiceRestarting transport
      , testCase "RCServiceNOTRestarting" $
          HA.RecoveryCoordinator.Mero.Tests.testServiceNotRestarting transport
      , testCase "RCHAEventsGotTrimmed" $
          HA.RecoveryCoordinator.Mero.Tests.testEQTrimming transport
      , testCase "RGHostResources" $
          HA.RecoveryCoordinator.Mero.Tests.testHostAddition transport
      , testCase "RGDriveResources" $
          HA.RecoveryCoordinator.Mero.Tests.testDriveAddition transport
      , testCase "RCServiceStopped" $
          HA.RecoveryCoordinator.Mero.Tests.testServiceStopped transport
      , testCase "RCNodeLocalMonitor" $
          HA.RecoveryCoordinator.Mero.Tests.testMonitorManagement transport
      , testCase "RCMasterMonitor" $
          HA.RecoveryCoordinator.Mero.Tests.testMasterMonitorManagement
            transport
      , testCase "RCNodeUpRace [disabled]" $
          HA.RecoveryCoordinator.Mero.Tests.testNodeUpRace transport
      , testGroup "Autoboot" $
          HA.Autoboot.Tests.tests transport
        -- TODO: fails very often
      , testCase "RCToleratesDisconnections [disabled]" $ const (return ()) $
          HA.Test.Disconnect.testDisconnect
            transport (error "breakConnection not supplied in test")
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
    _ <- forkIO $ do threadDelay (9 * 60 * 1000000)
                     forever $ do threadDelay 100000
                                  throwTo tid (ErrorCall "Timeout")
    runTests ut
