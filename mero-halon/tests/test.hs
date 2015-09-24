-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}

module Main where

import qualified HA.RecoveryCoordinator.Mero.Tests
import qualified HA.Autoboot.Tests
#ifdef USE_MERO
import qualified HA.Castor.Tests
#endif
import qualified HA.Test.Disconnect

import Test.Tasty (TestTree, defaultMainWithIngredients)
import Test.Tasty.Ingredients.Basic (consoleTestReporter)
import Test.Tasty.Ingredients.FileReporter (fileTestReporter)

import System.IO (hSetBuffering, BufferMode(..), stdout, stderr)

import Network.Transport (Transport, EndPointAddress)

import Test.Tasty (testGroup)
import Test.Tasty.HUnit (testCase)

import Control.Concurrent (threadDelay)

#ifdef USE_RPC
import Control.Monad (when)
import Data.Maybe (catMaybes)
import HA.Network.Transport (writeTransportGlobalIVar)
import qualified Network.Transport.RPC as RPC
import System.Directory
import System.Exit
import System.FilePath
import System.Process
#else
import qualified HA.Network.Socket as TCP
import qualified Network.Socket as TCP
import qualified Network.Transport.TCP as TCP
#endif
import Prelude
import System.Environment


ut :: Transport -> (EndPointAddress -> EndPointAddress -> IO ()) -> IO TestTree
ut transport breakConnection = return $
    testGroup "ut"
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
      , testCase "uncleanRPCClose" $ threadDelay 2000000
      , testCase "RCDecisionLogOutput" $
        HA.RecoveryCoordinator.Mero.Tests.testDecisionLog transport
      , testCase "RCServiceStopped" $
        HA.RecoveryCoordinator.Mero.Tests.testServiceStopped transport
      , testCase "RCNodeLocalMonitor" $
        HA.RecoveryCoordinator.Mero.Tests.testMonitorManagement transport
      , testCase "RCMasterMonitor" $
        HA.RecoveryCoordinator.Mero.Tests.testMasterMonitorManagement transport
      , testCase "RCNodeUpRace" $
        HA.RecoveryCoordinator.Mero.Tests.testNodeUpRace transport
      , testGroup "Autoboot" $
        HA.Autoboot.Tests.tests transport
#ifdef USE_MERO
      , testGroup "Castor" $
        HA.Castor.Tests.tests transport
#endif
#if !defined(USE_RPC) && !defined(USE_MOCK_REPLICATOR)
      , testCase "RCToleratesDisconnections [disabled]" $ const (return ()) $
          HA.Test.Disconnect.testDisconnect transport breakConnection
#else
      , testCase "RCToleratesDisconnections [disabled by compilation flags]" $
          const (return ()) $
            HA.Test.Disconnect.testDisconnect transport breakConnection
#endif
      ]

runTests :: (Transport -> (EndPointAddress -> EndPointAddress -> IO ()) -> IO TestTree) -> IO ()
runTests tests = do
    -- TODO: Remove threadDelay after RPC transport closes cleanly
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    argv  <- getArgs
    addr0 <- case drop 1 $ dropWhile ("--" /=) argv of
               a0:_ -> return a0
               _ ->
#ifdef USE_RPC
                 maybe (error "environement variable TEST_LISTEN is not set") id <$> lookupEnv "TEST_LISTEN"
#else
                 maybe "127.0.0.1:0" id <$> lookupEnv "TEST_LISTEN"
#endif
#ifdef USE_RPC
    rpcTransport <- RPC.createTransport "s1"
                       (RPC.rpcAddress addr0) RPC.defaultRPCParameters
    writeTransportGlobalIVar rpcTransport
    let transport = RPC.networkTransport rpcTransport
        connectionBreak = undefined
#else
    let TCP.SockAddrInet port hostaddr = TCP.decodeSocketAddress addr0
    hostname <- TCP.inet_ntoa hostaddr
    (transport, internals) <- either (error . show) id <$>
                 TCP.createTransportExposeInternals hostname (show port)
                   TCP.defaultTCPParameters
                     { TCP.tcpNoDelay = True
                     , TCP.tcpUserTimeout = Just 2000
                     , TCP.transportConnectTimeout = Just 2000000
                     }
    let connectionBreak here there = do
          TCP.socketBetween internals here there >>= TCP.close
          TCP.socketBetween internals there here >>= TCP.close
#endif
    withArgs (takeWhile ("--" /=) argv) $
      defaultMainWithIngredients [fileTestReporter [consoleTestReporter]]
        =<< tests transport connectionBreak

main :: IO ()
main = do
#if USE_RPC
    args <- getArgs
    prog <- getExecutablePath
    -- test if we have root privileges
    ((userid, _): _ ) <- reads <$> readProcess "id" ["-u"] ""
    when (userid /= (0 :: Int)) $ do
      -- change directory so mero files are produced under the dist folder
      let testDir = takeDirectory (takeDirectory $ takeDirectory prog)
                  </> "test"
      createDirectoryIfMissing True testDir
      setCurrentDirectory testDir
      putStrLn $ "Changed directory to: " ++ testDir
      -- Invoke again with root privileges
      putStrLn $ "Calling test with sudo ..."
      mld <- fmap ("LD_LIBRARY_PATH=" ++) <$> lookupEnv "LD_LIBRARY_PATH"
      mtl <- fmap ("TEST_LISTEN=" ++) <$> lookupEnv "TEST_LISTEN"
      callProcess "sudo" $ catMaybes [mld, mtl] ++ prog : args
      exitSuccess
#endif
    runTests ut
