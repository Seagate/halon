-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}
module Test.Unit (tests) where

import Test.Framework
import qualified HA.EventQueue.Tests (tests)
import qualified HA.Multimap.Tests ( tests )
import qualified HA.Multimap.ProcessTests ( tests )
import qualified HA.NodeAgent.Tests (tests)
import qualified HA.RecoverySupervisor.Tests ( tests )
import qualified HA.ResourceGraph.Tests ( tests )

import Control.Applicative ((<$>))
import System.Environment (lookupEnv)
import System.IO

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
#ifdef USE_RPC
                    maybe (error "TEST_LISTEN environment variable is not set") id <$> lookupEnv "TEST_LISTEN"
#else
                    maybe "localhost:0" id <$> lookupEnv "TEST_LISTEN"
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
    fmap (testGroup "ut") $ sequence
        [
#ifdef USE_RPC
          testGroup "EQ" <$> HA.EventQueue.Tests.tests transport
#else
          testGroup "EQ" <$> HA.EventQueue.Tests.tests transport internals
#endif
        , testGroup "MM" <$> return
            [ testGroup "pure" HA.Multimap.Tests.tests
            , testGroup "process"
              [ HA.Multimap.ProcessTests.tests transport ]
            ]
        , testGroup "RS" <$> HA.RecoverySupervisor.Tests.tests True transport
        , testGroup "RG" <$> HA.ResourceGraph.Tests.tests transport
        , testGroup "NA" <$> HA.NodeAgent.Tests.tests transport
        ]
