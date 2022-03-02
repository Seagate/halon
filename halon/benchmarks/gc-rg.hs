{-# LANGUAGE CPP                       #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# OPTIONS_GHC -fno-warn-orphans      #-}
{-# OPTIONS_GHC -fno-warn-unused-binds #-}

-- |
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--

import           Control.DeepSeq (NFData(rnf))
import           Criterion.Main
import           Data.Binary (Binary)
import           Data.Hashable
import           Data.List (foldl')
import           Data.Typeable (Typeable)
import           GHC.Generics (Generic)
import           HA.ResourceGraph hiding (__remoteTable)
import           HA.Resources.TH

--------------------------------------------------------------------------------
-- Types                                                                      --
--------------------------------------------------------------------------------

data NodeA = NodeA Int
  deriving (Eq, Typeable, Generic, Show)

instance Hashable NodeA
instance Binary NodeA

data EdgeA = EdgeA Int
  deriving (Eq, Typeable, Generic, Show)

instance Hashable EdgeA
instance Binary EdgeA

$(mkDicts
  [ ''NodeA ]
  [ (''NodeA, ''EdgeA, ''NodeA) ]
 )

$(mkResRel
  [ ''NodeA ]
  [ (''NodeA, ''EdgeA, ''NodeA) ]
  [ ]
 )

instance NFData Graph where
  -- Good enough for GC?
  rnf g = let gr = getGraphResources g
              l = length gr
              l' = concatMap snd gr
          in l `seq` l' `seq` ()


--------------------------------------------------------------------------------
-- Tests                                                                      --
--------------------------------------------------------------------------------
defaultGroup :: String -> ConnectFilter -> Benchmark
defaultGroup s p = makeGCBenchGroup s [100, 500, 1000] p

main :: IO ()
main = defaultMain [
    defaultGroup "noneConnected" noneConnected
  , defaultGroup "allConnected" allConnected
  , makeGCBenchGroup "linearConnectedAll" [100, 500, 1000, 10000] linearConnectedAll
  , makeGCBenchGroup "linearConnectedHalf" [100, 500, 1000, 10000] linearConnectedHalf
  , defaultGroup "linearConnectedSplit" (linearConnectedSplit 10)
  ]

-- | Helper for groups of 'mkGCBench'.
makeGCBenchGroup :: String
                 -> [Int]
                 -> ConnectFilter
                 -> Benchmark
makeGCBenchGroup s ns p = bgroup s $ map (flip mkGCBench p) ns

-- | Create a benchmark using 'buildGraph'.
mkGCBench :: Int -> ConnectFilter -> Benchmark
mkGCBench i p = bench (show i) $ nf garbageCollectRoot (mkGCGraph mkGraph)
  where
    mkGraph = buildGraph i p

-- | Creates a graph with @n@ unconnected vertices.
mkGCGraph :: (Graph -> Graph)
          -> Graph
mkGCGraph f = f $ emptyGraph mmchan
  where
    mmchan = error "gc-rg.hs: error, Graph's mmchan used in benchmark"

-- | Create a graph with the given number of nodes and the given edges.
--
-- @NodeA 1@ is the root node.
buildGraph :: Int -- ^ Number of nodes in graph
           -> ConnectFilter -- ^ Edges to connect in the graph
           -> Graph -> Graph
buildGraph n p = addRootNode (NodeA 1) . addEdges where
  addEdges g0 = foldl' (\g (a, b) -> connect (NodeA a) (EdgeA 0) (NodeA b) g) g0
              $ p n

-- * Connect filters

-- | Connection criteria: given @n@ nodes, return a list of nodes we
-- should connect.
type ConnectFilter = Int -> [(Int, Int)]

-- | No nodes connected at all.
noneConnected :: ConnectFilter
noneConnected _ = []

-- | All nodes connected to all other nodes, including themselves.
allConnected :: ConnectFilter
allConnected n = [ (a, b) | a <- [1 .. n], b <- [1 .. n] ]

-- | All nodes connected in a line, @1 --> 2 --> … --> n - 1 --> n@
linearConnectedAll :: ConnectFilter
linearConnectedAll n = [ (i-1, i) | i <- [2 .. n]]

-- | Like 'linearConnectedAll' but half the nodes are not connected at
-- all.
linearConnectedHalf :: ConnectFilter
linearConnectedHalf n = linearConnectedAll (n `div` 2)

-- | Connect all nodes just like in 'linearConnectedAll' but up every
-- @i@th connection, effectively splitting the graph into groups of
-- size @i@.
linearConnectedSplit :: Int -> ConnectFilter
linearConnectedSplit i n = filter p (linearConnectedAll n)
  where
    p (a, _) = a `mod` i /= 0
