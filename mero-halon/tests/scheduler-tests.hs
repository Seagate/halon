{-# LANGUAGE CPP #-}

-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.

module Main where

import qualified HA.Autoboot.Tests
import qualified HA.RecoveryCoordinator.Tests
import qualified HA.RecoveryCoordinator.Mero.Tests
import HA.Replicator.Log
import qualified HA.Test.Disconnect
import Helper.Environment
import Test.Tasty (TestTree, defaultMainWithIngredients, testGroup)
import Test.Tasty.Ingredients.Basic (consoleTestReporter)
import Test.Tasty.Ingredients.FileReporter (fileTestReporter)
import Test.Tasty.HUnit (testCase)

import Control.Concurrent
import Control.Exception
import Control.Monad
import Data.Proxy
import Network.Transport (Transport)
import Network.Transport.InMemory
import System.Posix.Env (setEnv)
import System.IO

#ifdef USE_MERO
import Mero
import qualified Mero.Notification.Tests
import Test.Framework (withTmpDirectory)
#endif


ut :: String -> Transport -> IO TestTree
ut _host transport = do
  let pg = Proxy :: Proxy RLogGroup
  return $
    testGroup "mero-halon" $ (:[]) $
    testGroup "scheduler"
      [ testCase "testServiceRestarting" $
           HA.RecoveryCoordinator.Tests.testServiceRestarting transport pg
      , testCase "testServiceNotRestarting" $
          HA.RecoveryCoordinator.Tests.testServiceNotRestarting transport pg
      , testCase "testEQTrimming" $
          HA.RecoveryCoordinator.Tests.testEQTrimming transport pg
      , testCase "testDriveAddition" $
          HA.RecoveryCoordinator.Mero.Tests.testDriveAddition transport pg
      , testCase "testServiceStopped" $
          HA.RecoveryCoordinator.Tests.testServiceStopped transport pg
      , testGroup "Autoboot" $
          HA.Autoboot.Tests.tests transport
      , testCase "testDisconnect" $
          HA.Test.Disconnect.testDisconnect
            transport (error "breakConnection not supplied in test")
#ifdef USE_MERO
        -- Run these two only if we have USE_MERO as we needed some initial
        -- data preloaded
      , testCase "testRejoin [disabled: HALON-486]" $
          if True
          then return ()
          else HA.Test.Disconnect.testRejoin
                 transport (error "breakConnection not supplied in test")
      , testCase "testRejoinTimeout" $
          HA.Test.Disconnect.testRejoinTimeout
            transport (error "breakConnection not supplied in test")
      , testCase "testRejoinRCDeath [disabled] " $
          if True
          then return ()
          else HA.Test.Disconnect.testRejoinRCDeath
                 transport (error "breakConnection not supplied in test")
      , Mero.Notification.Tests.tests transport
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
    prepare $ runTests (ut host0)
  where
#ifdef USE_MERO
    prepare = withTmpDirectory . withM0
#else
    prepare = id
#endif
