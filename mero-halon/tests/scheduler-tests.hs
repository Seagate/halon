{-# LANGUAGE CPP #-}

-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.

module Main where

import qualified HA.Autoboot.Tests
import qualified HA.RecoveryCoordinator.Tests
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
import System.Environment hiding (setEnv)
import System.Posix.Env (setEnv)
import System.IO

ut :: String -> Transport -> IO TestTree
ut _host transport = return $
    testGroup "mero-halon" $ (:[]) $
    testGroup "scheduler"
      [ testCase "RCServiceRestarting" $
          HA.RecoveryCoordinator.Tests.testServiceRestarting transport
      , testCase "RCServiceNOTRestarting" $
          HA.RecoveryCoordinator.Tests.testServiceNotRestarting transport
      , testCase "RCHAEventsGotTrimmed" $
          HA.RecoveryCoordinator.Tests.testEQTrimming transport
      , testCase "RGHostResources" $
          HA.RecoveryCoordinator.Mero.Tests.testHostAddition transport
      , testCase "RGDriveResources" $
          HA.RecoveryCoordinator.Mero.Tests.testDriveAddition transport
      , testCase "RCServiceStopped" $
          HA.RecoveryCoordinator.Tests.testServiceStopped transport
      , testCase "RCNodeLocalMonitor" $
          HA.RecoveryCoordinator.Tests.testMonitorManagement transport
      , testCase "RCMasterMonitor" $
          HA.RecoveryCoordinator.Tests.testMasterMonitorManagement
            transport
      , testCase "RCNodeUpRace" $
          HA.RecoveryCoordinator.Tests.testNodeUpRace transport
      , testGroup "Autoboot" $
          HA.Autoboot.Tests.tests transport
      , testCase "RCToleratesDisconnections" $
          HA.Test.Disconnect.testDisconnect
            transport (error "breakConnection not supplied in test")
#ifdef USE_MERO
        -- Run these two only if we have USE_MERO as we needed some initial
        -- data preloaded
      , testCase "RCToleratesRejoins" $
          HA.Test.Disconnect.testRejoin
            _host transport (error "breakConnection not supplied in test")
      , testCase "RCToleratesRejoinsTimeout" $
          HA.Test.Disconnect.testRejoinTimeout
            _host transport (error "breakConnection not supplied in test")
      , testCase "RCToleratesRejoinsWithDeath" $
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
    argv <- getArgs
    (host0, _) <- case drop 1 $ dropWhile ("--" /=) argv of
      a0:_ -> return $ break (== ':') a0
      _ ->
        maybe (error "environment variable TEST_LISTEN is not set; example: 192.0.2.1:0")
              (break (== ':'))
              <$> lookupEnv "TEST_LISTEN"

    _ <- forkIO $ do threadDelay (30 * 60 * 1000000)
                     forever $ do threadDelay 100000
                                  throwTo tid (ErrorCall "Timeout")
    runTests (ut host0)
