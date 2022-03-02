{-# LANGUAGE CPP                        #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TemplateHaskell            #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--

import Control.DeepSeq (NFData(rnf))
import Control.Distributed.Process
  ( Process
  , ProcessId
  , spawnLocal
  , liftIO
  , catch
  , getSelfNode
  , unClosure
  )
import Control.Distributed.Process.Closure (mkStatic, remotable)
import Control.Distributed.Process.Internal.Types (LocalNode)
import Control.Distributed.Process.Node (newLocalNode)
import Control.Distributed.Process.Serializable (SerializableDict(..))
import Control.Exception (SomeException, bracket)
import Control.Monad (void)
import Criterion.Main

import Data.Binary (Binary)
import Data.Hashable (Hashable)
import Data.List (foldl', sort, (\\))
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Network.Transport (Transport)

import HA.Multimap (getKeyValuePairs)
import HA.Multimap.Implementation (Multimap, fromList)
import HA.Multimap.Process (multimap)
import HA.Process
import HA.Replicator (RGroup(..))
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock (MC_RG)
#else
import HA.Replicator.Log (MC_RG)
#endif
import HA.ResourceGraph hiding (__remoteTable)
import HA.Resources.TH

import RemoteTables (remoteTable)
import Test.Framework hiding (defaultMain)
import Test.Transport

--------------------------------------------------------------------------------
-- Types                                                                      --
--------------------------------------------------------------------------------

instance NFData Transport where
  rnf a = seq a ()

mmSDict :: SerializableDict Multimap
mmSDict = SerializableDict

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
  [ 'mmSDict ]
 )

--------------------------------------------------------------------------------
-- Test helpers                                                               --
--------------------------------------------------------------------------------

makeTransport :: IO Transport
makeTransport = mkInMemoryTransport >>= return . getTransport

-- | Run the given action on a newly created local node.
withLocalNode :: Transport -> (LocalNode -> IO a) -> IO a
withLocalNode transport action =
    bracket
      (newLocalNode transport (__remoteTable remoteTable))
      -- FIXME: Why does this cause gibberish to be output?
      -- closeLocalNode
      (const (return ()))
      action

-- | FIXME: Why do we need tryRunProcess?
tryRunProcessLocal :: Transport -> Process () -> IO ()
tryRunProcessLocal transport process =
    withTmpDirectory $
      withLocalNode transport $ \node ->
        tryRunProcess node process

rGroupTest :: (RGroup g, Typeable g)
           => Transport -> g Multimap -> (ProcessId -> Process ()) -> IO ()
rGroupTest transport g p =
    tryRunProcessLocal transport $
      flip catch (\e -> liftIO $ print (e :: SomeException)) $ do
        nid <- getSelfNode
        rGroup <- newRGroup $(mkStatic 'mmSDict) 20 1000000 4000000 [nid]
                            (fromList [])
                    >>= unClosure >>= (`asTypeOf` return g)
        mmpid <- spawnLocal $ catch (multimap rGroup) $
          (\e -> liftIO $ print (e :: SomeException))
        p mmpid

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
    , bench "500" $ whnfIO $ testSyncLarge t 500
    , bench "700" $ whnfIO $ testSyncLarge t 700
    , bench "900" $ whnfIO $ testSyncLarge t 900
    ]
  ]


testSyncLarge :: Transport -> Int -> IO ()
testSyncLarge t n = rGroupTest t g $ \pid -> do
    g1 <- sync =<< getGraph pid
    let g2 = buildCompleteGraph n g1
    void $ sync g2
  where
    g = undefined :: MC_RG Multimap

buildCompleteGraph :: Int -> Graph -> Graph
buildCompleteGraph n = addEdges where
  addEdges = foldl' (.) id
              $ fmap (\(a,b) -> connect (NodeA a) EdgeA (NodeA b))
              $ pairs range
  range = [1 .. n]
  pairs :: [a] -> [(a,a)]
  pairs [] = []
  pairs (x:xs) = [(x,y)|y <- xs] ++ pairs xs
