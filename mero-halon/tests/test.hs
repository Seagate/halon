-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}

module Main where

import qualified HA.RecoveryCoordinator.Mero.Tests
import qualified HA.RecoveryCoordinator.Tests
import qualified HA.Autoboot.Tests
#ifdef USE_MERO
#ifdef USE_MOCK_REPLICATOR
import qualified HA.RecoveryCoordinator.SSPL.Tests
#endif
import qualified HA.Castor.Tests
import qualified HA.Castor.Story.Repair
import qualified HA.Castor.Story.Tests
#endif
import qualified HA.Test.Disconnect
import qualified HA.Test.Cluster
import qualified HA.Test.SSPL

import Test.Tasty.Ingredients.Basic (consoleTestReporter)
import Test.Tasty.Ingredients.FileReporter (fileTestReporter)

import System.IO (hSetBuffering, BufferMode(..), stdout, stderr)

import Network.Transport (Transport, EndPointAddress)

import Helper.Environment
import Test.Framework
import Test.Tasty.HUnit (testCase)

import Control.Concurrent (threadDelay, forkIO)
import Control.Concurrent.MVar
import Control.Exception

#ifdef USE_MERO
import Mero
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

#ifdef USE_MERO
#define MERO_TEST(K, S, X, D) (K (S) (X))
#else
#define MERO_TEST(K, S, X, D) (K (S ++ " [disabled due to unset USE_MERO]") (D))
#endif

#ifdef USE_MOCK_REPLICATOR
#define MOCK_TEST(K, S, X, D) MERO_TEST(K, S, X, D)
#else
#define MOCK_TEST(K, S, X, D) MERO_TEST(K, (S ++ " [disabled due to unset USE_MOCK_REPLICATOR]"), D, D)
#endif


ut :: String -> Transport -> (EndPointAddress -> EndPointAddress -> IO ()) -> IO TestTree
ut _host transport breakConnection = do
  ssplTest <- HA.Test.SSPL.mkTests
#ifdef USE_MERO
  driveFailureTests <- HA.Castor.Story.Tests.mkTests
#endif
  return $
    testGroup "mero-halon" $ (:[]) $
#ifdef USE_MOCK_REPLICATOR
    testGroup "integration-tests with mock-replicator"
#else
    testGroup "integration-tests without mock replicator"
#endif
      [ testCase "uncleanRPCClose" $ threadDelay 2000000
      , testGroup "RC" $ HA.RecoveryCoordinator.Tests.tests transport
      , testGroup "Autoboot" $
        HA.Autoboot.Tests.tests transport
      , HA.Test.Cluster.tests transport
      , testGroup "mero" $
          HA.RecoveryCoordinator.Mero.Tests.tests _host transport
      , MERO_TEST(testGroup,"Castor",HA.Castor.Tests.tests _host transport
                 , [testCase "Ignore me" $ return ()])
      , MERO_TEST( testGroup, "DriveFailure", driveFailureTests transport
                 , [testCase "Ignore me" $ return ()])
      , testGroup "disconnect" $
        [ MERO_TEST(testCase, "testRejoinTimeout", HA.Test.Disconnect.testRejoinTimeout _host transport breakConnection, return ())
        , MERO_TEST(testCase, "testRejoin", HA.Test.Disconnect.testRejoin _host transport breakConnection, return ())
        , MOCK_TEST(testCase, "testRejoinRCDeath", HA.Test.Disconnect.testRejoinRCDeath _host transport breakConnection, return ())
#if !defined(USE_RPC) && !defined(USE_MOCK_REPLICATOR)
        , testCase "testDisconnect" $
            HA.Test.Disconnect.testDisconnect transport breakConnection
#else
        , testCase "testDisconnect [disabled by compilation flags]" $
            const (return ()) $
              HA.Test.Disconnect.testDisconnect transport breakConnection
#endif
        ]
      , MOCK_TEST( testGroup, "Service-SSPL"
                 , HA.RecoveryCoordinator.SSPL.Tests.utTests transport
                 , [testCase "Ignore me" $ return ()]
                 )
      , ssplTest transport
      , MERO_TEST(testGroup, "Repair", HA.Castor.Story.Repair.tests transport, return ())
      ]

-- | Set up a 'Transport' and a way to break connections before
-- passing it off to the given test tree.
runTests :: (String -> Transport -> (EndPointAddress -> EndPointAddress -> IO ()) -> IO TestTree) -> IO ()
runTests tests = do
    -- TODO: Remove threadDelay after RPC transport closes cleanly
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    (host0, p0)<- getTestListenSplit
    let addr0 = host0 ++ ":" ++ p0
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
    defaultMainWithIngredients [fileTestReporter [consoleTestReporter]]
      =<< tests host0 transport connectionBreak

main :: IO ()
main = prepare $ runTests ut where
#ifdef USE_MERO
  prepare = withTmpDirectory . withM0
#else
  prepare = id
#endif
