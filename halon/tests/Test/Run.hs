-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}

module Test.Run (runTests) where

import Test.Tasty (TestTree, defaultMainWithIngredients)
import Test.Tasty.Ingredients.Basic (consoleTestReporter)
import Test.Tasty.Ingredients.FileReporter (fileTestReporter)

import Control.Applicative ((<$>))
import Network.Transport (Transport)
import System.Environment (lookupEnv, getArgs)
import System.IO (hSetBuffering, BufferMode(..), stdout, stderr)

#ifdef USE_RPC
import Test.Framework (testSuccess)
import Test.Tasty (testGroup)
import Control.Concurrent (threadDelay)
#else
import qualified HA.Network.Socket as TCP
import qualified Network.Socket as TCP
import qualified Network.Transport.TCP as TCP
#endif

#if USE_RPC
runTests :: (Transport -> IO TestTree) -> IO ()
#else
runTests :: (Transport -> TCP.TransportInternals -> IO TestTree) -> IO ()
#endif
runTests tests = do
    -- TODO: Remove threadDelay after RPC transport closes cleanly
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    argv <- getArgs
    addr <- case argv of
            a0:_ -> return a0
            _    ->
#if USE_RPC
                    maybe (error "TEST_LISTEN environment variable is not set") id <$> lookupEnv "TEST_LISTEN"
#else
                    maybe "127.0.0.1:0" id <$> lookupEnv "TEST_LISTEN"
#endif
#ifdef USE_RPC
    transport <- RPC.createTransport "s1" addr RPC.defaultRPCParameters
    writeNetworkGlobalIVar transport
#else
    let TCP.SockAddrInet port hostaddr = TCP.decodeSocketAddress addr
    hostname <- TCP.inet_ntoa hostaddr
    (transport, internals) <- either (error . show) id <$>
        TCP.createTransportExposeInternals hostname (show port) TCP.defaultTCPParameters
#endif
    defaultMainWithIngredients [fileTestReporter [consoleTestReporter]]
#ifdef USE_RPC
      =<< testGroup "uncleanRPCClose" [ tests transport
                                     , testSuccess "" $ threadDelay 2000000 ])
#else
      =<< tests transport internals
#endif
