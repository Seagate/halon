{-# OPTIONS_GHC -fno-warn-orphans      #-}

-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

import           BenchHelpers
import           Criterion.Main
import           HA.ResourceGraph hiding (__remoteTable)

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
mkGCBench i p = bench (show i) $ nf garbageCollectRoot (mkGraph mkEmptyGraph)
  where
    mkGraph = buildGraph i p
