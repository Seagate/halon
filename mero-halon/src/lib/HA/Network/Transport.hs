-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Global variable to store the transport. Only needed for Mero RPC and even
-- then only transitionally.

-- TODO remove this module entirely.

{-# LANGUAGE CPP #-}

module HA.Network.Transport
  ( readTransportGlobalIVar
  , writeTransportGlobalIVar
  ) where

#ifdef USE_RPC
import Network.Transport.RPC (RPCTransport)
import System.IO.Unsafe (unsafePerformIO)
import Control.Concurrent (MVar, readMVar, tryPutMVar, newEmptyMVar)
import Control.Exception (evaluate)
import Control.Monad (when)
#endif

#ifdef USE_RPC
networkGlobalVariable :: MVar RPCTransport
networkGlobalVariable = unsafePerformIO $ newEmptyMVar
{-# NOINLINE networkGlobalVariable #-}

-- | Reads the value of a global variable holding the transport in use.
readTransportGlobalIVar :: IO RPCTransport
readTransportGlobalIVar = readMVar networkGlobalVariable

-- | Write the value of the global variable. Throws an exception if the value
-- has been alread set.
writeTransportGlobalIVar :: RPCTransport -> IO ()
writeTransportGlobalIVar n = do
  ok <- tryPutMVar networkGlobalVariable n
  when (not ok) $ evaluate $ error
    $ "writeNetworkGlobalIVar: the network global variable has been already"
    ++ " set. You can write only once to an immutable variable."
#else
-- | Only supported when compiled with RPC. Defined to be bottom elsewhere.
readTransportGlobalIVar, writeTransportGlobalIVar :: a
readTransportGlobalIVar = error "readTransportGlobalIVar: only for RPC."
writeTransportGlobalIVar = error "writeNetworkGlobalIVar: only for RPC."
#endif
