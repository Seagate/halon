-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}
module Test.Integration (tests) where

import Test.Framework
import qualified HA.EventQueue.Tests ( tests )
import qualified HA.Multimap.ProcessTests ( tests )
import qualified HA.NodeAgent.Tests (tests)
import qualified HA.RecoverySupervisor.Tests ( tests )
import qualified HA.ResourceGraph.Tests ( tests )

import Control.Applicative ( (<$>) )
import System.Environment (lookupEnv)
import System.IO ( hSetBuffering, BufferMode(..), stdout, stderr )

#ifndef USE_RPC
import qualified HA.Network.Socket as TCP
import qualified Network.Socket as TCP
import qualified Network.Transport.TCP as TCP
#endif

tests :: [String] -> IO TestTree
tests argv = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
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
    testGroup "it" <$> sequence
      [
#ifdef USE_RPC
        testGroup "EQ" <$> HA.EventQueue.Tests.tests transport
#else
        testGroup "EQ" <$> HA.EventQueue.Tests.tests transport internals
#endif
      , testGroup "MM-process-tests" <$> return
        [ HA.Multimap.ProcessTests.tests transport ]
      , testGroup "RG" <$> HA.ResourceGraph.Tests.tests transport
      , testGroup "RS" <$> HA.RecoverySupervisor.Tests.tests False transport
        -- Next test is commented since it doesn't pass reliably.
        -- TODO: fix liveness of paxos.
--    , HA.RecoverySupervisor.Tests.tests transport False
      , testGroup "NA" <$> HA.NodeAgent.Tests.tests transport
      ]
