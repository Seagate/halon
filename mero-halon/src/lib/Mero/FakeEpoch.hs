-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE CPP #-}

module Mero.FakeEpoch
       (
         sendEpochBlocking
       ) where

#ifdef USE_RPC
import qualified Network.Transport.RPC as RPC
import Data.Word ( Word64 )
import Control.Monad (when)
import System.IO.Error
#endif

-- XXX We probably want USE_MERO here, rather than USE_RPC.
#ifdef USE_RPC
-- | Connects to a given 'Address', sends a given epoch and disconnects.
sendEpochBlocking :: RPC.RPCAddress    -- ^ recepient address
                  -> Word64            -- ^ our epoch
                  -> Int               -- ^ timeout in seconds
                  -> IO (Maybe Word64) -- ^ their epoch
sendEpochBlocking addr epoch _ =
    do currentEpoch <- fmap read (readFile fname)
         `catchIOError` (\_ -> return 0)
       when (epoch > currentEpoch) $ do
         putStrLn ("EPOCH: Setting epoch on "++show addr++
             " to "++show epoch)
         writeFile fname (show epoch)
       return (Just epoch)
  where
    fname = "fakeEpoch-" ++ show addr
#else
-- | Only supported when compiled with RPC. Defined to be bottom elsewhere.
sendEpochBlocking :: a
sendEpochBlocking = error "sendEpochBlocking: Need support for RPC"
#endif
