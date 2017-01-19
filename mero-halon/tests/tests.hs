-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

module Main where

import           Control.Concurrent (forkIO)
import           Control.Concurrent.MVar
import           Control.Exception
import           Data.Proxy
import qualified HA.Autoboot.Tests
import qualified HA.Network.Socket as TCP
import qualified HA.RecoveryCoordinator.Tests
import           HA.Replicator.Log
import qualified HA.Test.Cluster
import qualified HA.Test.Disconnect
import qualified HA.Test.SSPL
import           Helper.Environment
import qualified Network.Socket as TCP
import           Network.Transport (Transport, EndPointAddress)
import qualified Network.Transport.TCP as TCP
import           System.Directory (getCurrentDirectory)
import           System.IO (hSetBuffering, BufferMode(..), stdout, stderr)
import           Test.Framework
import           Test.Tasty.Ingredients.Basic (consoleTestReporter)
import           Test.Tasty.Ingredients.FileReporter (fileTestReporter)

import qualified HA.RecoveryCoordinator.SSPL.Tests
import qualified HA.Test.InternalStateChanges
import qualified HA.Test.NotificationSort
import qualified HA.Castor.Story.Process
import qualified HA.RecoveryCoordinator.Mero.Tests
import qualified HA.Castor.Tests
import qualified HA.Castor.Story.Tests

tests :: Transport -> (EndPointAddress -> EndPointAddress -> IO ()) -> IO TestTree
tests transport breakConnection = do
  -- For mock replicator, change to 'Proxy RLocalGroup'
  let pg = Proxy :: Proxy RLogGroup
  ssplTest <- HA.Test.SSPL.mkTests
  driveFailureTests <- HA.Castor.Story.Tests.mkTests pg
  processTests <- HA.Castor.Story.Process.mkTests pg
  internalSCTests <- HA.Test.InternalStateChanges.mkTests pg
  return $ testGroup "mero-halon:tests"
      [ testGroup "RC" $ HA.RecoveryCoordinator.Tests.tests transport pg
      , testGroup "Autoboot" $ HA.Autoboot.Tests.tests transport
      , HA.Test.Cluster.tests transport
      , testGroup "Castor" $ HA.Castor.Tests.tests transport pg
      , testGroup "[require-mero] DriveFailure" $ driveFailureTests transport
      , testGroup "InternalStateChanges" $ internalSCTests transport
      , testGroup "Mero" $ HA.RecoveryCoordinator.Mero.Tests.tests transport pg
      , testGroup "NotificationSort" HA.Test.NotificationSort.tests
      , testGroup "Process" $ processTests transport
      , testGroup "Service-SSPL" $ HA.RecoveryCoordinator.SSPL.Tests.utTests transport pg
      , HA.Test.Disconnect.tests transport breakConnection
      , ssplTest transport
      ]

-- | Set up a 'Transport' and a way to break connections before
-- passing it off to the given test tree.
runTests :: (Transport -> (EndPointAddress -> EndPointAddress -> IO ()) -> IO TestTree) -> IO ()
runTests tests' = do
    -- TODO: Remove threadDelay after RPC transport closes cleanly
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    Just (host0, p0)<- getTestListenSplit
    let addr0 = host0 ++ ":" ++ show p0

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
    defaultMainWithIngredients [fileTestReporter [consoleTestReporter]]
      =<< tests' transport connectionBreak

main :: IO ()
main = prepare $ do
  dir <- getCurrentDirectory
  putStrLn $ "Running tests in " ++ dir
  runTests tests
  where
    prepare = withTmpDirectory
