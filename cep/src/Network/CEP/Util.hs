-- |
-- Copyright: (C) 2014 Tweag I/O Limited
-- 
-- Assorted utility functions, mostly on multimaps.
-- 

{-# LANGUAGE TupleSections #-}

module Network.CEP.Util where

import qualified Data.Map as Map
import qualified Data.MultiMap as MultiMap
import Data.MultiMap (MultiMap)

-- | Remove all instances of a value from a 'MultiMap'.
deleteValue :: Eq v => v -> MultiMap k v -> MultiMap k v
deleteValue v = MultiMap.fromMap
  . Map.mapMaybe (predToMaybe (not . null) . filter (/= v)) . MultiMap.toMap
  where predToMaybe p x = if p x then Just x else Nothing

-- | Return pairs of lists of all elements in either 'MultiMap',
-- matching up pairs by key.  Elements that have no counterpart in the
-- other map will be paired with an empty list.
joinOnKey :: Ord k => MultiMap k v -> MultiMap k v' -> [([v], [v'])]
joinOnKey m m' = Map.elems $ Map.unionWith
                   (\(xs, ys) (xs', ys') -> (xs ++ xs', ys ++ ys'))
                   (Map.map (,[]) $ MultiMap.toMap m )
                   (Map.map ([],) $ MultiMap.toMap m')

