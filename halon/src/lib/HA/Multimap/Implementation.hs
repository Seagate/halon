-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Functions for updating the replicator Multimap
--
-- See 'HA.Replicator.Multimap.StoreUpdate' for semantics.
--
--  * 'HA.Replicator.Multimap.InsertMany' is implemented by 'insertMany'.
--
--  * 'HA.Replicator.Multimap.DeleteValues' is implemented by 'deleteValues'.
--
--  * 'HA.Replicator.Multimap.DeleteKeys' is implemented by 'deleteKeys'.
--
{-# LANGUAGE FlexibleInstances #-}

module HA.Multimap.Implementation
  ( Multimap
  , insertMany
  , deleteValues
  , deleteKeys
  , empty
  , fromList
  , toList
  ) where

import HA.Multimap ( Key, Value )

import Control.Arrow ( second )
import Data.Binary ( Binary(..) )
import Data.HashMap.Lazy ( HashMap )
import qualified Data.HashMap.Strict as Map
import Data.HashSet ( HashSet )
import qualified Data.HashSet as Set
import Data.List ( foldl' )
import Data.Typeable ( Typeable )

-- | A multimap associates 'Key's with 'Value's.
--
-- Each 'Key' can have multiple associated 'Value's or none.
--
-- A single 'Value' can be associated only once to a 'Key'.
-- Trying to associate a 'Value' more than once has no effect.
--
newtype Multimap = Multimap { unMultimap :: HashMap Key (HashSet Value) }
  deriving (Eq, Typeable)

instance Binary Multimap where
  put = put . toList
  get = fmap fromList get

-- | Create an empty Multimap.
empty :: Multimap
empty = Multimap Map.empty

-- | Converts an association list into a 'Multimap'.
fromList :: [(Key,[Value])] -> Multimap
fromList = Multimap . Map.fromListWith Set.union . map (second Set.fromList)

-- | Converts a 'Multimap' into an association list.
toList :: Multimap -> [(Key,[Value])]
toList = map (second Set.toList) . Map.toList . unMultimap

-- | Inserts values from an association list into a Multimap.
insertMany :: [(Key,[Value])] -> Multimap -> Multimap
insertMany kvs mm = Multimap $ foldl'
    (\mm' (k,s) -> Map.insertWith (const $ union s) k (Set.fromList s) mm')
    (unMultimap mm) kvs
  where
    union = flip $ foldl' $ flip Set.insert

-- | Deletes 'Value's in an association list from a Multimap.
deleteValues :: [(Key,[Value])] -> Multimap -> Multimap
deleteValues kvs mm = Multimap $ foldl'
    (\mm' (k,s) -> Map.adjust (difference s) k mm')
    (unMultimap mm) kvs
  where
    difference = flip $ foldl' $ flip Set.delete

-- | Deletes 'Key's from a Multimap.
deleteKeys :: [Key] -> Multimap -> Multimap
deleteKeys keys mm = Multimap $ foldl' (flip Map.delete) (unMultimap mm) keys
