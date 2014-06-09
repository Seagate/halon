-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--

module Mero.FakeEpoch
       (
         sendEpochBlocking
       ) where

import HA.Network.Address
import Data.Word ( Word64 )
import Control.Monad (when)
import System.IO.Error

-- | Connects to a given 'Address', sends a given epoch and disconnects.
sendEpochBlocking :: Network           -- ^ transport to create connection with
                  -> Address           -- ^ recepient address
                  -> Word64            -- ^ our epoch
                  -> Int               -- ^ timeout in seconds
                  -> IO (Maybe Word64) -- ^ their epoch
sendEpochBlocking _ addr epoch _ =
    do currentEpoch <- fmap read (readFile fname) 
         `catchIOError` (\_ -> return 0)
       when (epoch > currentEpoch) $ do
         putStrLn ("EPOCH: Setting epoch on "++show addr++
             " to "++show epoch)
         writeFile fname (show epoch)
       return (Just epoch)
  where
    fname = "fakeEpoch-" ++ show addr
