{-# LANGUAGE RecordWildCards, NamedFieldPuns #-}
module Tree where

import Data.List
import Control.Monad (msum)
-- Needed for compatibility with GHC 7.4.
import Control.Monad.Instances ()
import Control.Monad.Cont


type Level = Int

data Tree a = Tree { level :: Level
                   , leader :: a
                   , members :: [Tree a]
                   , position :: Float }
              deriving (Eq, Show)

type Forest a = [Tree a]

singleton :: a -> Tree a
singleton x = Tree 0 x [] 0

-- | Assumes all trees to merge are at the same level.
merge :: a                      -- ^ Elected leader node
      -> [Tree a]               -- ^ Trees to merge
      -> Tree a
merge leader [] = Tree 0 leader [] 0
merge leader ts@(Tree {level}:_) = Tree (level + 1) leader ts 0

-- | Cut out subtree with the designated leader and level from the forest.
cut :: Eq a => Level -> a -> Forest a -> (Forest a, Maybe (Tree a))
cut lvl x ts = let (t, mb) = cutFromTree $ merge undefined ts
               in (members t, mb)
    where cutFromTree Tree{..}
              | Just t <- find (\Tree{leader} -> leader == x) members =
                          let members' = filter (\Tree{leader=x'} -> x /= x') members
                          in (Tree{members=members',..}, Just t)
              | otherwise = let (members', mb) = combine $ map cutFromTree members
                            in (Tree{members=members',..}, mb)
          combine = fmap msum . unzip

mapk k k' f [] = k'
mapk k k' f (x:xs) = f (\x' -> k (x':xs)) (mapk (\xs' -> k (x:xs')) k' f xs) x

-- | Graft a tree as a new branch of the tree whose leader and level
-- is as given. If the leader at the given level does not exist, then
-- it is created.
graft :: Eq a => Level -> a -> Forest a -> Tree a -> Forest a
graft lvl x ts t = mapk id (Tree lvl x [t] 0 : ts) go ts where
    go k k' Tree{..} | level == lvl, leader == x = k Tree{members = t : members, ..}
                     | otherwise = mapk (\members -> k Tree{..}) k' go members

bfs :: Tree a -> [a]
bfs t = loop [t] [] where
  loop [] [] = []
  loop [] outs = loop outs []
  loop (Tree{..}:ins) outs = leader : loop ins (members ++ outs)