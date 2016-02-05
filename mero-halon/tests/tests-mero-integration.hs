-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
--
-- Set of tests that require ability to start mero while running tests and root priviledges.
-- Tests require that there should be no mero running and mero kernel modules beign loaded.
module Main
  ( main ) where

import Mero
import qualified HA.Castor.Story.Tests
import qualified HA.RecoveryCoordinator.Mero.Tests

import qualified HA.Network.Socket as TCP
import qualified Network.Socket as TCP
import qualified Network.Transport.TCP as TCP
import Network.Transport (Transport)

import Control.Monad
import Control.Concurrent
import System.Environment (lookupEnv, getExecutablePath)
import System.Process
import System.IO

import Helper.Environment
import Test.Tasty (TestTree, TestName, defaultMainWithIngredients, testGroup)
import Test.Tasty.HUnit (testCase)
import Test.Tasty.Ingredients.Basic (consoleTestReporter)
import Test.Tasty.Ingredients.FileReporter (fileTestReporter)


main :: IO ()
main = withMeroEnvironment router wrapper where
  router = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    minfo <- liftM2 (,) <$> lookupEnv "MERO_TEST"
                        <*> lookupEnv "TEST_LISTEN"
    case minfo of
      Just ("RCSyncToConfd", host) -> do
        transport <- mkTransport
        return $ Just $ withM0Deferred $ do
          HA.RecoveryCoordinator.Mero.Tests.testRCsyncToConfd host transport
          threadDelay 1000000
      Just ("DriveFailurePVer", _host) -> do
        transport <- mkTransport
        return $ Just $ withM0Deferred $ do
          HA.Castor.Story.Tests.testDynamicPVer transport
          threadDelay 1000000
      _ -> return Nothing
  wrapper = do
    defaultMainWithIngredients [fileTestReporter [consoleTestReporter]] $
      testGroup "mero-integration-tests"
        [ runExternalTest "RCSyncToConfd"
        -- , runExternalTest "DriveFailurePVer" -- Disabled until strategy based generation will arrive
        ]

runExternalTest :: TestName -> TestTree
runExternalTest name = testCase name $ do
  prog <- getExecutablePath
  callCommand $ "MERO_TEST=" ++ name ++ " " ++ prog

mkTransport :: IO Transport
mkTransport = do
  addr0 <- getTestListen
  let TCP.SockAddrInet port hostaddr = TCP.decodeSocketAddress addr0
  hostname <- TCP.inet_ntoa hostaddr
  (transport, _internals) <- either (error . show) id <$>
     TCP.createTransportExposeInternals hostname (show port)
     TCP.defaultTCPParameters
        { TCP.tcpNoDelay = True
        , TCP.tcpUserTimeout = Just 2000
        , TCP.transportConnectTimeout = Just 2000000
        }
  return transport
