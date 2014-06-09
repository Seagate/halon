-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This is the Key-value API.
--
-- It allows to modify- and query the key-value store of the Replicator
-- component. It is intended to be used by the Recovery Coordinator.
-- Conceptually, the key-value store is a set of key-"set of values" pairs:
--
-- > store `in` Store = 2^(Key x 2^Value)
--

{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
module HA.Multimap
    ( Key, Value, StoreUpdate(..), getKeyValuePairs, updateStore )where

import Control.Distributed.Process (ProcessId, Process )
import HA.Call (callAt)

import Control.Monad ( join )
import Data.ByteString ( ByteString )
import Data.Binary ( Binary )
import Data.Typeable ( Typeable )
import GHC.Generics ( Generic )


-- | Types of keys
type Key = ByteString
-- | Types of values
type Value = ByteString

-- | Update operations for the store
--
-- More formally, a value of type @StoreUpdate@ is a function on stores:
-- @Store -> Store@
--
data StoreUpdate =

    -- | Inserts key-value pairs in the store.
    -- If the key is already associated to the value, the pair is
    -- ignored.
    --
    -- More formally:
    --
    -- >  InsertMany xs store = normalize (xs `union` store)
    -- >    where
    -- >      normalize st = { (k,sets k st) | (k,_)<-st }
    -- >      sets k st = mconcat { s | (k’,s)<-st, k==k’ }
    --
    InsertMany [(Key,[Value])]

    -- | Deletes specific values from the store.
    -- If the value is not associated to the key, or the key is
    -- not in the store, the pair is ignored.
    --
    -- More formally:
    --
    -- >  DeleteValues xs store = { (k,s `difference` sets k xs) | (k,s)<-st }
    --
  | DeleteValues [(Key,[Value])]

    -- | Deletes keys and all its associated values from the store.
    -- If a key is not in the store, it is ignored.
    --
    -- More formally:
    --
    -- >  DeleteKeys xs store = { (k,s) | (k,s)<-store, k `notMember` xs }
    --
  | DeleteKeys [Key]

 deriving (Generic,Typeable)

instance Binary StoreUpdate

-- | @getKeyValuePairs multimapPid@ yields all the keys and values in the store.
--
-- @multimapPid@ is the pid of the process running
-- 'HA.Replicator.Multimap.Process.multimap'.
--
-- This may change to a streaming interface if the store turns out to be too big
-- to transfer in one piece.
--
-- Yields @Nothing@ in case of error.
--
getKeyValuePairs :: ProcessId -> Process (Maybe [(Key,[Value])])
getKeyValuePairs mmPid =
    callAt mmPid () >>= return . join

-- | The type of @updateStore@. It updates the store with a batch of operations.
--
-- The Replicator component finishes the RPC after the updates
-- have been performed.
--
-- More formally: @updateStore xs store = foldr ($) store xs@
--
-- Yields @Nothing@ in case of error.
--
updateStore :: ProcessId -> [StoreUpdate] -> Process (Maybe ())
updateStore mmPid upds =
    callAt mmPid upds >>= return . join
