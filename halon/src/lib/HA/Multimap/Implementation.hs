-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
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
{-# LANGUAGE TypeSynonymInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module HA.Multimap.Implementation
  ( Multimap
  , insertMany
  , deleteValues
  , deleteKeys
  , Map.empty
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

-- | A multimap associates 'Key's with 'Value's.
--
-- Each 'Key' can have multiple associated 'Value's or none.
--
-- A single 'Value' can be associated only once to a 'Key'.
-- Trying to associate a 'Value' more than once has no effect.
--
type Multimap = HashMap Key (HashSet Value)

instance Binary Multimap where
  put = put . toList
  get = fmap fromList get

-- | Converts an association list into a 'Multimap'.
fromList :: [(Key,[Value])] -> Multimap
fromList = Map.fromListWith Set.union . map (second Set.fromList)

-- | Converts a 'Multimap' into an association list.
toList :: Multimap -> [(Key,[Value])]
toList = map (second Set.toList) . Map.toList

-- | Inserts values from an association list into a Multimap.
insertMany :: [(Key,[Value])] -> Multimap -> Multimap
insertMany = flip $ foldl' $
    \mm' (k,s) -> Map.insertWith (const $ union s) k (Set.fromList s) mm'
  where
    union = flip $ foldl' $ flip Set.insert

-- | Deletes 'Value's in an association list from a Multimap.
deleteValues :: [(Key,[Value])] -> Multimap -> Multimap
deleteValues = flip $ foldl' $
    \mm' (k,s) -> Map.adjust (difference s) k mm'
  where
    difference = flip $ foldl' $ flip Set.delete

-- | Deletes 'Key's from a Multimap.
deleteKeys :: [Key] -> Multimap -> Multimap
deleteKeys = flip $ foldl' (flip Map.delete)
