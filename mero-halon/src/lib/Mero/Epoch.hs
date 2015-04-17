-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--

module Mero.Epoch
       (
         sendEpochBlocking
       ) where

import qualified HA.Network.Transport
import qualified Network.RPC.RPCLite as Lite
import Control.Exception (bracket)
import Control.Monad (void)
import Data.Word ( Word64 )

-- | Connects to a given 'Address', sends a given epoch and disconnects.
sendEpochBlocking :: ServerEndpoint
                  -> RPC.RPCAddress    -- ^ recepient address
                  -> Word64            -- ^ our epoch
                  -> Int               -- ^ timeout in seconds
                  -> IO (Maybe Word64) -- ^ their epoch
sendEpochBlocking ep addr epoch timeout_s = do
    bracket
      (Lite.connect_se ep addr connectTimeout)
      (\c -> void $ Lite.disconnect c connectTimeout)
      (\c -> Lite.sendEpochBlocking c epoch timeout_s)
  where
    connectTimeout = 3

