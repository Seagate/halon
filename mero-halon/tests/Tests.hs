-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}
module Tests (tests) where

import Test.Framework
import qualified HA.RecoveryCoordinator.Mero.Tests ( tests )

#ifdef USE_RPC
import qualified Network.Transport.RPC as RPC
#else
import qualified Network.Transport.TCP as TCP
import qualified HA.Network.Socket as TCP
import qualified Network.Socket as TCP
#endif

import Control.Applicative ((<$>))
import System.Environment (lookupEnv)
import System.IO


-- | Temporary wrapper for components whose unit tests have not been broken up
-- into independent small tests.
monolith :: String -> IO () -> IO TestTree
monolith name = return . testSuccess name . withTmpDirectory

tests :: [String] -> IO TestTree
tests argv = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
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
    monolith "RC" $ HA.RecoveryCoordinator.Mero.Tests.tests transport
