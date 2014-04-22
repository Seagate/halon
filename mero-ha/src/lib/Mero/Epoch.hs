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
import qualified Network.Transport.RPC as RPC
import qualified Network.Transport.RPC.RPCLite as Lite
#endif

#ifdef USE_RPC
import Control.Exception (bracket)
import Control.Monad (void)
#endif
import HA.Network.Address
import Data.Word ( Word64 )

-- | Connects to a given 'Address', sends a given epoch and disconnects.
sendEpochBlocking :: Network           -- ^ transport to create connection with
                  -> Address           -- ^ recepient address
                  -> Word64            -- ^ our epoch
                  -> Int               -- ^ timeout in seconds
                  -> IO (Maybe Word64) -- ^ their epoch
#ifdef USE_RPC
sendEpochBlocking (Network tr) addr epoch timeout_s =
  do
    bracket
      (Lite.connect_se (RPC.serverEndPoint tr) addr slots connectTimeout)
      (\c -> void $ Lite.disconnect c connectTimeout)
      (\c -> Lite.sendEpochBlocking c epoch timeout_s)
  where
    slots = 1
    connectTimeout = 3
#else
-- Reserved for compatibility with non-RPC builds.
sendEpochBlocking _ _ _ _ =
    return Nothing
#endif
