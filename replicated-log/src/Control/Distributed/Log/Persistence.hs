-- |
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- An abstract interface for a persistent store
--
-- Provides a way to create persistent maps of keys to values.

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE Rank2Types #-}
module Control.Distributed.Log.Persistence where

import Data.ByteString.Lazy
import Data.Typeable

-- | An abstract interface for a persistent store
data PersistentStore = PersistentStore
    { -- | Runs a list of operations in a single transaction.
      atomically     :: [WriteOp] -> IO ()
      -- | Creates a map with the given name if it doesn't exist, otherwise
      -- it returns the existing map. This is useful to keep a set of keys
      -- grouped in the store.
    , getMap :: forall k. IsKey k => ByteString -> IO (PersistentMap k)
      -- | Closes the store.
      --
      -- All operations on the store and its maps are undefined after this call.
    , close :: IO ()
    }

-- | Operations that can modify the store
data WriteOp = -- | Inserts a key/value pair in the given map.
               forall k. IsKey k => Insert !(PersistentMap k) !k !ByteString
               -- | Eliminates from a map all the given keys.
             | forall k. IsKey k => Trim !(PersistentMap k) ![k]

-- | A class of types that can be converted to keys.
class Typeable k => IsKey k where

instance IsKey Int where
instance IsKey (Int, Int) where

-- | A persistent map from keys to values
data PersistentMap k = PersistentMap
    { -- | A piece of data that the implementation can use to distinguish the
      -- map
      mapId      :: ByteString
      -- | Looks up a key
    , lookup     :: k -> IO (Maybe ByteString)
      -- | Collects the key/value pairs in a map.
    , pairsOfMap :: IO [(k, ByteString)]
    }

