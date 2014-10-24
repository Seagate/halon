-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module HA.Network.Address
     ( Address
     , parseAddress
     , Network(..)
     , startNetwork
     , getNetworkTransport
     , readNetworkGlobalIVar
     , networkBreakConnection
     , hostOfAddress ) where

import Network.Transport (Transport)

import Control.Applicative ((<$>))
import Control.Concurrent (MVar, readMVar, tryPutMVar, newEmptyMVar)
import Control.Exception (evaluate)
import Control.Monad (when)
import System.IO.Unsafe (unsafePerformIO)

import Network.Transport (EndPointAddress)
#ifdef USE_RPC
import qualified Network.Transport.RPC as RPC
import Data.ByteString.Char8 as B8
#else
import Control.Concurrent (threadDelay)
import qualified Network.Socket as TCP
import qualified HA.Network.Socket as TCP
import qualified Network.Transport.TCP as TCP
import Network.Socket (sClose)
#endif

-- | An abstract 'Address' type whose definition depends on which
-- transport was selected when building HA.
#ifdef USE_RPC
type Address = RPC.RPCAddress
#else
type Address = TCP.SockAddr
#endif

-- | Returns the host name of an 'Address'.
hostOfAddress :: Address -> String
hostOfAddress =
#ifdef USE_RPC
    \(RPC.RPCAddress addr) ->
      Prelude.takeWhile (/= '@') $ B8.unpack addr
#else
    fst . break (== ':') . show
#endif

-- | Parse an 'Address' from a string. The format depends on the
-- selected transport when HA is built.
parseAddress :: String -> Maybe Address
#ifdef USE_RPC
parseAddress = Just . RPC.rpcAddress
#else
parseAddress = Just . TCP.decodeSocketAddress
#endif

-- | An abstract transport datatype whose definition depends on which
-- transport was selected when building HA.
#ifdef USE_RPC
data Network = Network RPC.RPCTransport
getNetworkTransport :: Network -> Transport
getNetworkTransport (Network rpctrans) = RPC.networkTransport rpctrans
#else
data Network = Network Transport TCP.TransportInternals
getNetworkTransport :: Network -> Transport
getNetworkTransport (Network trans _) = trans
#endif

-- | Creates a transport that communicates through the provided 'Address'.
startNetwork :: Address -> IO Network
startNetwork endpoint = do
#ifdef USE_RPC
    n <- Network <$>
         RPC.createTransport "s1" endpoint RPC.defaultRPCParameters
#else
    let TCP.SockAddrInet port host = endpoint
    hostname <- TCP.inet_ntoa host
    n <- uncurry Network <$>
         either (error . show) id
              <$> TCP.createTransportExposeInternals hostname (show port) TCP.defaultTCPParameters
#endif
    writeNetworkGlobalIVar n
    return n

-- | Used for testing purposes, so the behavior of code when connections fail is
-- rehearsed.
networkBreakConnection :: Network -> EndPointAddress -> EndPointAddress -> IO ()
#ifdef USE_RPC
networkBreakConnection _ _ _ = error "networkBreakConnection: unimplemented."
#else
networkBreakConnection (Network _ internals) ep1 ep2 = do
    sock <- TCP.socketBetween internals ep1 ep2
    sClose sock
    threadDelay 10000
#endif

-- | A write-once global variable to hold the transport used by CH.
--
-- The tracking station is expected to initialize this variable
-- before starting the RC with
-- 'HA.RecoveryCoordinator.RecoveryCoordinator.recoveryCoordinator'.
--
networkGlobalVariable :: MVar Network
networkGlobalVariable = unsafePerformIO $ newEmptyMVar
{-# NOINLINE networkGlobalVariable #-}

-- | Reads the value of a global variable holding the transport in use.
readNetworkGlobalIVar :: IO Network
readNetworkGlobalIVar = readMVar networkGlobalVariable

-- | Write the value of the global variable. Throws an exception if the value
-- has been alread set.
writeNetworkGlobalIVar :: Network -> IO ()
writeNetworkGlobalIVar n = do
  ok <- tryPutMVar networkGlobalVariable n
  when (not ok) $ evaluate $ error
    $ "writeNetworkGlobalIVar: the network global variable has been already"
    ++ " set. You can write only once to an immutable variable."
