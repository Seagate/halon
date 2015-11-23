-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}

module Main where

import qualified HA.RecoveryCoordinator.Mero.Tests
import qualified HA.Autoboot.Tests
#ifdef USE_MERO
import qualified HA.Castor.Tests
import qualified HA.Castor.Story.Tests
#endif
import qualified HA.Test.Disconnect
import qualified HA.Test.Cluster
import qualified HA.Test.SSPL

import Test.Tasty (TestTree, defaultMainWithIngredients)
import Test.Tasty.Ingredients.Basic (consoleTestReporter)
import Test.Tasty.Ingredients.FileReporter (fileTestReporter)

import System.IO (hSetBuffering, BufferMode(..), stdout, stderr)

import Network.Transport (Transport, EndPointAddress)

import Test.Tasty (testGroup)
import Test.Tasty.HUnit (testCase)

import Control.Concurrent (threadDelay, forkIO)
import Control.Concurrent.MVar
import Control.Exception

#ifdef USE_MERO
import Control.Monad (when)
import Data.Maybe (catMaybes)
import System.Directory
import System.Exit
import System.FilePath
import System.Process
#endif

#ifdef USE_RPC
import qualified Network.Transport.RPC as RPC
import HA.Network.Transport (writeTransportGlobalIVar)
#else
import qualified HA.Network.Socket as TCP
import qualified Network.Socket as TCP
import qualified Network.Transport.TCP as TCP
#endif
import Prelude
import System.Environment


ut :: String -> Transport -> (EndPointAddress -> EndPointAddress -> IO ()) -> IO TestTree
ut _host transport breakConnection = do
  ssplTest <- HA.Test.SSPL.mkTests
#ifdef USE_MERO
  driveFailureTests <- HA.Castor.Story.Tests.mkTests
#endif
  return $
#ifdef USE_MOCK_REPLICATOR
    testGroup "ut"
#else
    testGroup "it"
#endif
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
      , HA.Test.Cluster.tests transport
#ifdef USE_MERO
      , testGroup "Castor" $
        HA.Castor.Tests.tests _host transport
      , testGroup "DriveFailure" $
        driveFailureTests transport
      , testCase "RCsyncToConfd" $
          HA.RecoveryCoordinator.Mero.Tests.testRCsyncToConfd _host transport
      , testCase "RCToleratesRejoins" $
          HA.Test.Disconnect.testRejoin _host transport breakConnection
      , testCase "RCToleratesRejoinsTimeout" $
          HA.Test.Disconnect.testRejoinTimeout _host transport breakConnection
      , testCase "RCToleratesRejoinsWithDeath" $
          HA.Test.Disconnect.testRejoinRCDeath
            _host transport (error "breakConnection not supplied in test")
#endif
#if !defined(USE_RPC) && !defined(USE_MOCK_REPLICATOR)
      , testCase "RCToleratesDisconnections" $
          HA.Test.Disconnect.testDisconnect transport breakConnection
#else
      , testCase "RCToleratesDisconnections [disabled by compilation flags]" $
          const (return ()) $
            HA.Test.Disconnect.testDisconnect transport breakConnection
#endif
      , ssplTest transport
      ]

runTests :: (String -> Transport -> (EndPointAddress -> EndPointAddress -> IO ()) -> IO TestTree) -> IO ()
runTests tests = do
    -- TODO: Remove threadDelay after RPC transport closes cleanly
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    argv  <- getArgs
    (host0, p0) <- case drop 1 $ dropWhile ("--" /=) argv of
               a0:_ -> return $ break (== ':') a0
               _ ->
                 maybe (error "environement variable TEST_LISTEN is not set; example: 192.0.2.1:0")
                       (break (== ':'))
                       <$> lookupEnv "TEST_LISTEN"
    let addr0 = host0 ++ p0
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
    let -- XXX: Could use enclosed-exceptions here. Note that the worker
        -- is not killed in case of an exception.
        ignoreSyncExceptions action = do
          mv <- newEmptyMVar
          _ <- forkIO $ action `finally` putMVar mv ()
          takeMVar mv
        connectionBreak here there = do
          ignoreSyncExceptions $
            TCP.socketBetween internals here there >>= TCP.close
          ignoreSyncExceptions $
            TCP.socketBetween internals there here >>= TCP.close
#endif
    withArgs (takeWhile ("--" /=) argv) $
      defaultMainWithIngredients [fileTestReporter [consoleTestReporter]]
        =<< tests host0 transport connectionBreak

main :: IO ()
main = do
#ifdef USE_MERO
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
  when (userid == (0 :: Int)) $ do
    runTests ut
#else
  runTests ut
#endif
