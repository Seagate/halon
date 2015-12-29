-- | 
-- Copyright : (C) 2015 Seagate Technology Limited.
--
-- Set of tests that require ability to start mero while running tests and root priviledges.
-- Tests require that there should be no mero running and mero kernel modules beign loaded.
module Main
  ( main ) where

import Mero
import Network.RPC.RPCLite
import qualified HA.Castor.Story.Tests
import qualified HA.RecoveryCoordinator.Mero.Tests

import qualified HA.Network.Socket as TCP
import qualified Network.Socket as TCP
import qualified Network.Transport.TCP as TCP
import Network.Transport (Transport)

import Control.Monad
import Control.Concurrent
import Data.Maybe (isNothing)
import System.Environment (lookupEnv, getExecutablePath)
import System.Process

import Test.Tasty (TestTree, TestName, defaultMainWithIngredients, testGroup)
import Test.Tasty.HUnit (testCase)
import Test.Tasty.Ingredients.Basic (consoleTestReporter)
import Test.Tasty.Ingredients.FileReporter (fileTestReporter)
import Helper.Environment

main :: IO ()
main = withMeroEnvironment router wrapper where 
  router = do 
    minfo <- liftM2 (,) <$> lookupEnv "MERO_TEST"
                        <*> lookupEnv "TEST_LISTEN"
    case minfo of
      Just ("DUMMY_HALON", _host) -> return $ Just $ withM0Deferred $ do
        confdAddress <- getConfdEndpoint
        addr         <- getLnetNid
        initRPC
        _ <- withEndpoint (rpcAddress $ addr ++ ":12345:35:497") $ \ep ->
          withHASession ep (rpcAddress confdAddress) $ forever $ return ()
        finalizeRPC
      Just ("RCSyncToConfd", host) ->
        Just . withM0Deferred .
          HA.RecoveryCoordinator.Mero.Tests.testRCsyncToConfd host <$> mkTransport 
      Just ("DriveFailurePVer", _host) -> 
        Just . withM0Deferred .
          HA.Castor.Story.Tests.testDynamicPVer <$> mkTransport
      _ -> return Nothing
  wrapper = do
    maddr <- lookupEnv "TEST_LISTEN"
    when (isNothing maddr) 
         (error "environment variable TEST_LISTEN is not set; example: 192.0.2.1:0")
    defaultMainWithIngredients [fileTestReporter [consoleTestReporter]] $
      testGroup "mero-integration-tests"
        [ runExternalTest "DriveFailurePVer"
        , runExternalTest "RCSyncToConfd"
        ]
    threadDelay 1000000

runExternalTest :: TestName -> TestTree
runExternalTest name = testCase name $ do
  prog <- getExecutablePath
  callCommand $ "MERO_TEST=" ++ name ++ " " ++ prog

mkTransport :: IO Transport
mkTransport = do
  (host0,p0) <- maybe (error "environement variable TEST_LISTEN is not set; example: 192.0.2.1:0")
                      (break (== ':'))
                      <$> lookupEnv "TEST_LISTEN"
  let addr0 = host0 ++ p0
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
