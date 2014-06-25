-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}

module Main where

import qualified HA.RecoveryCoordinator.Mero.Tests ( tests )

import Test.Tasty (TestTree, defaultMainWithIngredients)
import Test.Tasty.Ingredients.Basic (consoleTestReporter)
import Test.Tasty.Ingredients.FileReporter (fileTestReporter)

import Control.Applicative ((<$>))
import System.Environment (lookupEnv, getArgs)
import System.IO (hSetBuffering, BufferMode(..), stdout, stderr)

import Network.Transport (Transport)

import Test.Tasty (testGroup)
import Test.Tasty.HUnit (testCase)

import Control.Concurrent (threadDelay)

#ifndef USE_RPC
import qualified HA.Network.Socket as TCP
import qualified Network.Socket as TCP
import qualified Network.Transport.TCP as TCP
#endif

ut :: Transport -> IO TestTree
ut transport = return $
    testGroup "ut"
      [ testCase "RC" $ HA.RecoveryCoordinator.Mero.Tests.tests transport 
      , testCase "uncleanRPCClose" $ threadDelay 2000000
      ]

runTests :: (Transport -> IO TestTree) -> IO ()
runTests tests = do
    -- TODO: Remove threadDelay after RPC transport closes cleanly
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    argv  <- getArgs
    addr0 <- case argv of
               a0:_ -> return a0
               _ ->
#ifdef USE_RPC
                 maybe (error "environement variable TEST_LISTEN is not set") id <$> lookupEnv "TEST_LISTEN"
#else
                 maybe "127.0.0.1:0" id <$> lookupEnv "TEST_LISTEN"
#endif
#ifdef USE_RPC
    transport <- RPC.createTransport "s1" addr0 RPC.defaultRPCParameters
    writeNetworkGlobalIVar transport
#else
    let TCP.SockAddrInet port hostaddr = TCP.decodeSocketAddress addr0
    hostname <- TCP.inet_ntoa hostaddr
    transport <- either (error . show) id <$>
                 TCP.createTransport hostname (show port) TCP.defaultTCPParameters
#endif
    defaultMainWithIngredients [fileTestReporter [consoleTestReporter]]
      =<< tests transport

main :: IO ()
main = runTests ut
