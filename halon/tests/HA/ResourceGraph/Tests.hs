-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module HA.ResourceGraph.Tests ( tests ) where

import Control.Distributed.Process
import Control.Distributed.Process.Closure (mkStatic, remotable)
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable (SerializableDict(..))

import Control.Arrow ((>>>))
import Control.Exception (SomeException, fromException, throwIO)
import Data.Binary (Binary)
import Data.Hashable (Hashable)
import qualified Data.HashSet as S
import Data.List (sort, (\\))
import Data.Typeable (Typeable)
import GHC.Generics (Generic)

import Network.Transport (Transport)

import HA.Multimap (defaultMetaInfo, MetaInfo, StoreChan)
import HA.Multimap.Implementation (Multimap, fromList)
import HA.Multimap.Process (startMultimap)
import HA.Replicator (RGroup(..))
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock (MC_RG)
#else
import HA.Replicator.Log (MC_RG)
#endif
import HA.ResourceGraph hiding (__remoteTable)

import RemoteTables (remoteTable)
import Test.Framework
import Test.Helpers (assertBool)

--------------------------------------------------------------------------------
-- Types                                                                      --
--------------------------------------------------------------------------------

data NodeA = NodeA Int
  deriving (Eq, Typeable, Generic, Show)

instance Hashable NodeA
instance Binary NodeA

data NodeB = NodeB Int
  deriving (Eq, Typeable, Generic, Show)

instance Hashable NodeB
instance Binary NodeB

data HasA = HasA
  deriving (Eq, Typeable, Generic, Show)

instance Hashable HasA
instance Binary HasA

data HasB = HasB
  deriving (Eq, Typeable, Generic, Show)

instance Hashable HasB
instance Binary HasB

resourceDictNodeA :: Dict (Resource NodeA)
resourceDictNodeB :: Dict (Resource NodeB)

resourceDictNodeA = Dict
resourceDictNodeB = Dict

relationDictHasBNodeANodeB :: Dict (Relation HasB NodeA NodeB)
relationDictHasANodeBNodeA :: Dict (Relation HasA NodeB NodeA)

relationDictHasBNodeANodeB = Dict
relationDictHasANodeBNodeA = Dict

mmSDict :: SerializableDict (MetaInfo, Multimap)
mmSDict = SerializableDict

remotable
  [ 'resourceDictNodeA
  , 'resourceDictNodeB
  , 'relationDictHasBNodeANodeB
  , 'relationDictHasANodeBNodeA
  , 'mmSDict
  ]

instance Resource NodeA where
  resourceDict = $(mkStatic 'resourceDictNodeA)
instance Resource NodeB where
  resourceDict = $(mkStatic 'resourceDictNodeB)

instance Relation HasB NodeA NodeB where
  relationDict = $(mkStatic 'relationDictHasBNodeANodeB)
instance Relation HasA NodeB NodeA where
  relationDict = $(mkStatic 'relationDictHasANodeBNodeA)

--------------------------------------------------------------------------------
-- Test helpers                                                               --
--------------------------------------------------------------------------------

tryRunProcessLocal :: Transport -> Process () -> IO ()
tryRunProcessLocal transport process =
    withTmpDirectory $
      withLocalNode transport (__remoteTable remoteTable) $ \node ->
        runProcess node process

rGroupTest :: (RGroup g, Typeable g)
           => Transport -> g (MetaInfo, Multimap)
           -> (StoreChan -> Process ()) -> IO ()
rGroupTest transport g p =
    tryRunProcessLocal transport $ do
      nid <- getSelfNode
      rGroup <- newRGroup $(mkStatic 'mmSDict) 20 1000000 [nid] (defaultMetaInfo, fromList [])
                  >>= unClosure >>= (`asTypeOf` return g)
      (mmpid, mmchan) <- startMultimap rGroup $ \loop -> do
        catch loop (liftIO . handler)
      link mmpid
      p mmchan
  where
    handler :: SomeException -> IO a
    handler e | Just ThreadKilled <- fromException e = return () >> throwIO e
              | otherwise = print e >> throwIO e

--
-- NodeA 1       NodeA 2
--          ·         .
--      ::'  \ HasA  ·:·
--      ' \   ·       | HasA
--    HasB ·   \ .    ·
--          \  .::    |
--           ·        ·
-- NodeB 1       NodeB 2
--
sampleGraph :: Graph -> Graph
sampleGraph =
    connect (NodeB 2) HasA (NodeA 1) .
    connect (NodeB 2) HasA (NodeA 2) .
    connect (NodeA 1) HasB (NodeB 2) .
    connect (NodeA 1) HasB (NodeB 2) .
    newResource (NodeB 2) .
    newResource (NodeB 1) .
    newResource (NodeA 1) .
    newResource (NodeB 1) .
    newResource (NodeA 2) .
    newResource (NodeA 1)

syncWait :: Graph -> Process Graph
syncWait g = do
    (sp, rp) <- newChan
    sync g (sendChan sp ()) <* receiveChan rp

--------------------------------------------------------------------------------
-- Tests                                                                      --
--------------------------------------------------------------------------------

tests :: Transport -> IO [TestTree]
tests transport = do
    let g = undefined :: MC_RG (MetaInfo, Multimap)
    return
      [ testSuccess "initial-graph" $ rGroupTest transport g $ \mm -> do
          _g <- syncWait =<< getGraph mm
          ns <- getKeyValuePairs mm
          assertBool "getKeyValuePairsWithoutGCInfo is empty" $ ns == []

      , testSuccess "kv-length" $ rGroupTest transport g $ \mm -> do
          _g <- syncWait . sampleGraph =<< getGraph mm
          kvs <- getKeyValuePairs mm
          assertBool "there are 4 keys" $ 4 == length kvs
          assertBool "the values are sane"
            $ [0, 1, 2, 3] == sort (map (length . snd) kvs)

      , testSuccess "edge-nodeA-1" $ rGroupTest transport g $ \mm -> do
          g1 <- syncWait . sampleGraph =<< getGraph mm
          let es0 = edgesFromSrc (NodeA 1) g1
          assert $ length es0 == 1
          assert $ [] == es0 \\ [Edge (NodeA 1) HasB (NodeB 2)]

      , testSuccess "edge-nodeB-2" $ rGroupTest transport g $ \mm -> do
          g1 <- syncWait . sampleGraph =<< getGraph mm
          let es1 = connectedTo (NodeB 2) HasA g1
          assert $ length es1 == 2
          assert $ [] == es1 \\ [NodeA 1, NodeA 2]
          assert $ [] == (connectedTo (NodeB 1) HasA g1 :: [NodeA])

      , testSuccess "edge-nodeB-2-disconnect" $ rGroupTest transport g $ \mm -> do
          g1 <- syncWait . sampleGraph =<< getGraph mm
          _ <- syncWait $ disconnect (NodeB 2) HasA (NodeA 1) g1
          g2 <- getGraph mm
          let es2 = connectedTo (NodeB 2) HasA g2
          assert $ length es2 == 1
          assert $ [] == es2 \\ [NodeA 2]
          let ed2 = connectedFrom HasA (NodeA 1) g2 :: [NodeB]
          assert $ length ed2 == 0

      , testSuccess "async-updates" $ rGroupTest transport g $ \mm -> do
          g1 <- syncWait . sampleGraph =<< getGraph mm
          (sp, rp) <- newChan
          g2 <- sync (connect (NodeB 1) HasA (NodeA 1) g1) $ sendChan sp ()
          g3 <- sync (disconnect (NodeB 1) HasA (NodeA 1) g2) $ sendChan sp ()
          receiveChan rp
          receiveChan rp

          let es1 = connectedTo (NodeB 1) HasA g2
          assert $ length es1 == 1
          assert $ es1 == [NodeA 1]

          assert $ Prelude.null (connectedTo (NodeB 1) HasA g3 :: [NodeA])

          g4 <- getGraph mm
          assert $ Prelude.null (connectedTo (NodeB 1) HasA g4 :: [NodeA])

      , testSuccess "back-edge" $ rGroupTest transport g $ \mm -> do
          g1 <- syncWait . sampleGraph =<< getGraph mm
          let ed0 = edgesToDst (NodeB 2) g1
          assert $ length ed0 == 1
          assert $ [] == ed0 \\  [Edge (NodeA 1) HasB (NodeB 2)]

      , testSuccess "garbage-collection" $ rGroupTest transport g $ \mm -> do
          g1 <- syncWait . sampleGraph =<< getGraph mm
          g2 <- syncWait $ garbageCollect (S.singleton . Res $ NodeB 2) g1
          -- NodeB 1 never connected to root set
          assert $ memberResource (NodeB 1) g2 == False
          g3 <- syncWait $ garbageCollect (S.singleton . Res $ NodeB 2)
                     . disconnect (NodeB 2) HasA (NodeA 1)
                     . disconnect (NodeB 2) HasA (NodeA 2)
                     $ g2
          assert $ memberResource (NodeA 1) g3 == True
          assert $ memberResource (NodeA 2) g3 == False
          -- Create a cycle
          g4 <- syncWait $ connect (NodeA 3) HasB (NodeB 3)
                     . connect (NodeB 3) HasA (NodeA 4)
                     . connect (NodeA 4) HasB (NodeB 4)
                     . connect (NodeB 4) HasA (NodeA 3)
                     . newResource (NodeA 3)
                     . newResource (NodeA 4)
                     . newResource (NodeB 3)
                     . newResource (NodeB 4)
                     $ g3
          let g5 = garbageCollect (S.singleton . Res $ NodeB 2) g4
              g6 = garbageCollect (S.singleton . Res $ NodeA 3) g4
          assert $ memberResource (NodeA 3) g5 == False
          assert $ memberResource (NodeA 3) g6 == True
          assert $ memberResource (NodeB 2) g6 == False
          assert $ memberResource (NodeB 2) g5 == True

      , testSuccess "garbage-collection-auto" $ rGroupTest transport g $ \mm -> do
          g1 <- syncWait . sampleGraph =<< getGraph mm
          assert $ getSinceGC g1 == 0
          assert $ getGCThreshold g1 == 100
          assert $ getRootNodes g1 == []
          let g2 = disconnect (NodeB 2) HasA (NodeA 2) g1
          assert $ getSinceGC g2 == 1
          g3 <- syncWait g2
          assert $ getSinceGC g3 == 1
          g4 <- syncWait $ addRootNode (NodeB 2) g3
          -- Just disconnect same thing 100 times to meet threshold
          -- and ramp up the disconnect amounts.
          let dcs = replicate 100 (disconnect (NodeB 2) HasA (NodeA 1))
              g5 = foldr ($) g4 dcs
          -- Make sure everything is still around and ready
          assert $ memberResource (NodeA 1) g5 == True
          assert $ memberResource (NodeA 2) g5 == True
          assert $ getSinceGC g5 == 101
          g6 <- syncWait g5
          -- Make sure GC happened
          assert $ getSinceGC g6 == 0
          assert $ memberResource (NodeA 1) g6 == True
          assert $ memberResource (NodeA 2) g6 == False
      , testSuccess "garbage-collection-meta-persists" $ rGroupTest transport g $ \mm -> do
          g1 <- syncWait . sampleGraph =<< getGraph mm
          assertBool "Default getSinceGC" $ getSinceGC g1 == 0
          assertBool "Default getGCThreshold" $ getGCThreshold g1 == 100
          assertBool "Default getRootNodes" $ getRootNodes g1 == []
          -- Set custom GC meta
          let root = NodeB 2
              cmeta@(sinceGC, thres, _) = (1, 50, [Res root])
              meta rg = (getSinceGC rg, getGCThreshold rg, getRootNodes rg)
          g2 <- syncWait $ setSinceGC sinceGC
                       >>> setGCThreshold thres
                       >>> addRootNode root
                         $ g1
          assertBool "Synced meta matches" $ cmeta == meta g2
          g2' <- getGraph mm
          -- The meta information from mm should be the same as the
          -- one we synced
          assertBool "Meta not default" $ meta g1 /= meta g2'
          assertBool "Same meta" $ meta g2 == meta g2'
      , testSuccess "gc-info-graph-still-null" $ rGroupTest transport g $ \mm -> do
         g1 <- syncWait =<< getGraph mm
         assertBool "fresh graph is null" $ HA.ResourceGraph.null g1
      , testSuccess "merge-resources" $ rGroupTest transport g $ \mm -> do
          g1 <- syncWait . sampleGraph =<< getGraph mm
          g2 <- syncWait $ mergeResources head [NodeA 1, NodeA 2] g1
          let es1 = connectedTo (NodeA 1) HasB g2 :: [NodeB]
              es2 = connectedFrom HasA (NodeA 1) g2 :: [NodeB]
          assert $ memberResource (NodeA 1) g2 == True
          assert $ memberResource (NodeA 2) g2 == False
          assert $ length es1 == 1
          assert $ length es2 == 2

      ]
