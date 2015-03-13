-- |
-- Copyright : (C) 2015 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- An abstract interface for a persistent store
--
-- Provides a way to create persistent maps of keys to values.

module Control.Distributed.Log.Persistence where

import Data.ByteString.Lazy


-- | An abstract interface for a persistent store
data PersistentStore = PersistentStore
    { -- | Runs a list of operations in a single transaction.
      atomically     :: [WriteOp] -> IO ()
      -- | Creates a map with the given key if it doesn't exist otherwise
      -- it returns the existing map. This is useful to keep a set of keys
      -- grouped in the store.
    , getMap :: ByteString -> IO PersistentMap
      -- | Closes the store.
      --
      -- All operations on the store and its maps are undefined after this call.
    , close :: IO ()
    }

-- | Operations that can modify the store
data WriteOp = -- | Inserts a key/value pair in the given map.
               Insert PersistentMap Int ByteString
               -- | Eliminates from a map all the keys smaller than the given
               -- key.
             | Trim PersistentMap Int

-- | A persistent map from keys to values
data PersistentMap = PersistentMap
    { -- | A piece of data that the implementation can use to distinguish the
      -- map
      mapId      :: ByteString
      -- | Looks up a key
    , lookup     :: Int -> IO (Maybe ByteString)
      -- | Collects the key/value pairs in a map.
    , pairsOfMap :: IO [(Int, ByteString)]
    }

