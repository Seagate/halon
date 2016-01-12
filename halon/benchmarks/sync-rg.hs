{-# LANGUAGE CPP                        #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TemplateHaskell            #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

import Control.DeepSeq (NFData(rnf))
import Control.Monad (void)
import Criterion.Main
import Data.Binary (Binary)
import Data.Hashable (Hashable)
import Data.List (foldl')
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import HA.Multimap (MetaInfo)
import HA.Multimap.Implementation (Multimap)
import HA.ResourceGraph hiding (__remoteTable)
import HA.ResourceGraph.Tests (rGroupTest, syncWait)
import HA.Resources.TH
import Network.Transport (Transport)
import Test.Transport
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock (MC_RG)
#else
import HA.Replicator.Log (MC_RG)
#endif
--------------------------------------------------------------------------------
-- Types                                                                      --
--------------------------------------------------------------------------------

-- avoid orphan instance
newtype TransportNF = TransportNF Transport

instance NFData TransportNF where
  rnf (TransportNF a) = seq a ()

data NodeA = NodeA Int
  deriving (Eq, Typeable, Generic, Show)

instance Hashable NodeA
instance Binary NodeA

data EdgeA = EdgeA
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
  []
 )

--------------------------------------------------------------------------------
-- Test helpers                                                               --
--------------------------------------------------------------------------------

makeTransport :: IO TransportNF
makeTransport = mkInMemoryTransport >>= return . TransportNF . getTransport

--------------------------------------------------------------------------------
-- Tests                                                                      --
--------------------------------------------------------------------------------

main :: IO ()
main = defaultMain [
    env makeTransport $ \ t -> bgroup "small" [
      bench "1" $ whnfIO $ testSyncLarge t 1
    , bench "3" $ whnfIO $ testSyncLarge t 3
    , bench "5" $ whnfIO $ testSyncLarge t 5
    , bench "7" $ whnfIO $ testSyncLarge t 7
    , bench "9" $ whnfIO $ testSyncLarge t 9
    ]
  , env makeTransport $ \ t -> bgroup "medium" [
      bench "10" $ whnfIO $ testSyncLarge t 10
    , bench "30" $ whnfIO $ testSyncLarge t 30
    , bench "50" $ whnfIO $ testSyncLarge t 50
    , bench "70" $ whnfIO $ testSyncLarge t 70
    , bench "90" $ whnfIO $ testSyncLarge t 90
    ]

  , env makeTransport $ \ t -> bgroup "large" [
      bench "100" $ whnfIO $ testSyncLarge t 100
    , bench "300" $ whnfIO $ testSyncLarge t 300
{-
    , bench "500" $ whnfIO $ testSyncLarge t 500
    , bench "700" $ whnfIO $ testSyncLarge t 700
    , bench "900" $ whnfIO $ testSyncLarge t 900
-}
    ]

  ]


testSyncLarge :: TransportNF -> Int -> IO ()
testSyncLarge (TransportNF t) n = rGroupTest t g $ \mmchan -> do
    g1 <- syncWait =<< getGraph mmchan
    let g2 = buildCompleteGraph n g1
    void $ syncWait g2
  where
    g = undefined :: MC_RG (MetaInfo, Multimap)

buildCompleteGraph :: Int -> Graph -> Graph
buildCompleteGraph n = addEdges . addResources where
  addResources g0 = foldl' (\g n' -> newResource (NodeA n') g) g0 range
  addEdges g0 = foldl' (\g (a,b) -> connect (NodeA a) EdgeA (NodeA b) g) g0
              $ pairs range
  range = [1 .. n]
  pairs :: [a] -> [(a,a)]
  pairs [] = []
  pairs (x:xs) = [(x,y)|y <- xs] ++ pairs xs
