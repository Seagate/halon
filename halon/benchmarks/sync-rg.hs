{-# LANGUAGE CPP #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

import BenchHelpers
import Control.DeepSeq (NFData(rnf), ($!!))
import Control.Monad (void)
import Criterion.Main
import HA.Multimap (MetaInfo)
import HA.Multimap.Implementation (Multimap)
import HA.ResourceGraph hiding (__remoteTable)
import HA.ResourceGraph.Tests (rGroupTest, syncWait)
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
      benchLarge 1 t
    , benchLarge 3 t
    , benchLarge 5 t
    , benchLarge 7 t
    , benchLarge 9 t
    ]
  , env makeTransport $ \ t -> bgroup "medium" [
      benchLarge 10 t
    , benchLarge 30 t
    , benchLarge 50 t
    , benchLarge 70 t
    , benchLarge 90 t
    ]
  , env makeTransport $ \ t -> bgroup "large" [
      benchLarge 100 t
    , benchLarge 300 t
    , benchLarge 500 t
    , benchLarge 700 t
    , benchLarge 900 t
    ]
  ]

benchLarge :: Int -> TransportNF -> Benchmark
benchLarge n t =
  let g = buildGraph n allConnected mkEmptyGraph
  in bench (show n) . whnfIO $ testSyncLarge t $!! g

testSyncLarge :: TransportNF -> Graph -> IO ()
testSyncLarge (TransportNF t) gr = rGroupTest t g $ \mmchan ->
  void (syncWait $ gr { grMMChan = mmchan })
  where
    g = undefined :: MC_RG (MetaInfo, Multimap)
