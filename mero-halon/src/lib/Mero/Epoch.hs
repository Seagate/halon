-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE CPP #-}

module Mero.Epoch
       (
         sendEpochBlocking
       ) where

#ifdef USE_RPC
import qualified HA.Network.Transport
import qualified Network.Transport.RPC as RPC
import qualified Network.Transport.RPC.RPCLite as Lite
import Control.Exception (bracket)
import Control.Monad (void)
import Data.Word ( Word64 )
#endif

-- XXX We probably want USE_MERO here, rather than USE_RPC.
#ifdef USE_RPC
-- | Connects to a given 'Address', sends a given epoch and disconnects.
sendEpochBlocking :: RPC.RPCAddress    -- ^ recepient address
                  -> Word64            -- ^ our epoch
                  -> Int               -- ^ timeout in seconds
                  -> IO (Maybe Word64) -- ^ their epoch
sendEpochBlocking addr epoch timeout_s = do
    transport <- readTransportGlobalIVar
    bracket
      (Lite.connect_se (RPC.serverEndPoint transport) addr slots connectTimeout)
      (\c -> void $ Lite.disconnect c connectTimeout)
      (\c -> Lite.sendEpochBlocking c epoch timeout_s)
  where
    slots = 1
    connectTimeout = 3
#else
-- | Only supported when compiled with RPC. Defined to be bottom elsewhere.
sendEpochBlocking :: a
sendEpochBlocking = error "sendEpochBlocking: Need support for RPC"
#endif
