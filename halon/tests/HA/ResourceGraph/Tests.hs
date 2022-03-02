-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module HA.ResourceGraph.Tests ( tests ) where

import qualified HA.ResourceGraph.Tests.Merge as Merge

import Control.Distributed.Process hiding (catch)
import Control.Distributed.Process.Closure (mkStatic)
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable (SerializableDict(..))

import Control.Arrow ((>>>))
import Control.Exception
  ( AsyncException(..)
  , SomeException
  , fromException
  , throwIO
  )
import Control.Monad.Catch (catch)
import Data.Hashable (Hashable)
import qualified Data.HashSet as S
import Data.List (sort, (\\))
import Data.Proxy
import Data.Typeable (Typeable)
import GHC.Generics (Generic)

import Network.Transport (Transport)

import HA.Aeson (ToJSON)
import HA.Multimap (defaultMetaInfo, getKeyValuePairs, MetaInfo, StoreChan)
import HA.Multimap.Implementation (Multimap, fromList)
import HA.Multimap.Process (startMultimap)
import HA.Replicator (RGroup(..))
import HA.ResourceGraph hiding (__remoteTable)
import HA.Resources.TH
import HA.SafeCopy

import RemoteTables (remoteTable)
import Test.Framework
import Test.Helpers (assertBool, assertEqual)

mmSDict :: SerializableDict (MetaInfo, Multimap)
mmSDict = SerializableDict
--------------------------------------------------------------------------------
-- Types                                                                      --
--------------------------------------------------------------------------------

data NodeA = NodeA Int
  deriving (Eq, Ord, Typeable, Generic, Show)

instance Hashable NodeA
storageIndex ''NodeA "4b3d448b-adab-4bd1-be8a-c6df76d9ec9b"
instance ToJSON NodeA

data NodeB = NodeB Int
  deriving (Eq, Typeable, Generic, Show)

instance Hashable NodeB
storageIndex ''NodeB "9a61aeed-8ed2-4c68-9182-ba49bf3882ed"
instance ToJSON NodeB

data NodeC = NodeC Int
  deriving (Eq, Typeable, Generic, Show)

instance Hashable NodeC
storageIndex ''NodeC "895fd217-6857-4764-90cc-2aa06822b3ce"
instance ToJSON NodeC

data HasA = HasA
  deriving (Eq, Typeable, Generic, Show)

instance Hashable HasA
storageIndex ''HasA "673277b8-e9ed-4dda-94c9-d8d4242faf09"
instance ToJSON HasA

data HasB = HasB
  deriving (Eq, Typeable, Generic, Show)

instance Hashable HasB
storageIndex ''HasB "f266d212-7f0c-4bb2-88f8-0dd5afb9f746"
instance ToJSON HasB

data HasC = HasC
  deriving (Eq, Typeable, Generic, Show)

instance Hashable HasC
storageIndex ''HasC "8f6c6d6f-bece-45dc-beee-1a8a2deea408"
instance ToJSON HasC

deriveSafeCopy 0 'base ''NodeA
deriveSafeCopy 0 'base ''NodeB
deriveSafeCopy 0 'base ''NodeC
deriveSafeCopy 0 'base ''HasA
deriveSafeCopy 0 'base ''HasB
deriveSafeCopy 0 'base ''HasC

$(mkDicts
  [''NodeA, ''NodeB, ''NodeC, ''HasA, ''HasB, ''HasC]
  [ (''NodeA, ''HasB, ''NodeB)
  , (''NodeB, ''HasA, ''NodeA)
  , (''NodeA, ''HasC, ''NodeC)
  , (''NodeB, ''HasC, ''NodeC)
  , (''NodeA, ''HasA, ''NodeA)
  ])
$(mkResRel
  [''NodeA, ''NodeB, ''NodeC, ''HasA, ''HasB, ''HasC]
  [ (''NodeA, Unbounded, ''HasB, Unbounded, ''NodeB)
  , (''NodeB, Unbounded, ''HasA, Unbounded, ''NodeA)
  , (''NodeA, Unbounded, ''HasC, AtMostOne, ''NodeC)
  , (''NodeB, AtMostOne, ''HasC, AtMostOne, ''NodeC)
  , (''NodeA, Unbounded, ''HasA, Unbounded, ''NodeA)
  ]
  ['mmSDict]
  )

--------------------------------------------------------------------------------
-- Test helpers                                                               --
--------------------------------------------------------------------------------

tryRunProcessLocal :: Transport -> Process () -> IO ()
tryRunProcessLocal transport process =
    withTmpDirectory $
      withLocalNode transport (__resourcesTable $ __remoteTable remoteTable) $ \node ->
        runProcess node process

rGroupTest :: (RGroup g, Typeable g)
           => Transport -> g (MetaInfo, Multimap)
           -> (StoreChan -> Process ()) -> IO ()
rGroupTest transport g p =
    tryRunProcessLocal transport $ do
      nid <- getSelfNode
      rGroup <- newRGroup $(mkStatic 'mmSDict) "mmtest" 20 1000000 4000000 [nid]
                          (defaultMetaInfo, fromList [])
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
--               NodeB 2
--
-- NodeB 3 <-- HasA --- NodeA 3
sampleGraph :: Graph -> Graph
sampleGraph =
    connect (NodeB 2) HasA (NodeA 1) .
    connect (NodeB 2) HasA (NodeA 2) .
    connect (NodeA 1) HasB (NodeB 2) .
    connect (NodeA 1) HasB (NodeB 2) .
    connect (NodeB 99) HasA (NodeA 99)

syncWait :: Graph -> Process Graph
syncWait g = do
    (sp, rp) <- newChan
    sync g (sendChan sp ()) <* receiveChan rp

--------------------------------------------------------------------------------
-- Tests                                                                      --
--------------------------------------------------------------------------------

tests :: forall g. (Typeable g, RGroup g)
      => Transport -> Proxy g -> IO [TestTree]
tests transport _ = do
    let g = undefined :: g (MetaInfo, Multimap)
    return $
      [ testSuccess "initial-graph" $ rGroupTest transport g $ \mm -> do
          _g <- syncWait =<< getGraph mm
          ns <- getKeyValuePairs mm
          assertBool "getKeyValuePairs is empty" $ ns == []
      , testSuccess "gc-info-graph-still-null" $ rGroupTest transport g $ \mm -> do
         g1 <- syncWait =<< getGraph mm
         assertBool "fresh graph is null" $ HA.ResourceGraph.null g1
      , testSuccess "kv-length" $ rGroupTest transport g $ \mm -> do
          _g <- syncWait . sampleGraph =<< getGraph mm
          kvs <- getKeyValuePairs mm
          assertEqual "there are 5 keys" 5 (length kvs)
          assertEqual "the relations are sane"
            [1, 1, 1, 2, 3] (sort (map (length . snd) kvs))
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

          assert $ Prelude.null
            (connectedTo (NodeB 1) HasA g3 :: [NodeA])

          g4 <- getGraph mm
          assert $ Prelude.null
            (connectedTo (NodeB 1) HasA g4 :: [NodeA])

      , testSuccess "back-edge" $ rGroupTest transport g $ \mm -> do
          g1 <- syncWait . sampleGraph =<< getGraph mm
          let ed0 = edgesToDst (NodeB 2) g1
          assert $ length ed0 == 1
          assert $ [] == ed0 \\  [Edge (NodeA 1) HasB (NodeB 2)]

      , testSuccess "garbage-collection" $ rGroupTest transport g $ \mm -> do
          g1 <- syncWait . sampleGraph =<< getGraph mm
          -- NodeB 99, NodeA 99 are in RG
          assertBool "NodeB 99 in RG" $ memberResource (NodeB 99) g1
          assertBool "NodeA 99 in RG" $ memberResource (NodeA 99) g1
          g2 <- syncWait $ garbageCollect (S.singleton . Res $ NodeB 2) g1
          -- NodeB 99, NodeA 99 aren't connected to NodeB 2 so got GC'd
          assertBool "NodeB 99 not in RG" $ memberResource (NodeB 99) g2 == False
          assertBool "NodeA 99 not in RG" $ memberResource (NodeA 99) g2 == False
          g3 <- syncWait $ garbageCollect (S.singleton . Res $ NodeB 2)
                     . disconnect (NodeB 2) HasA (NodeA 1)
                     . disconnect (NodeB 2) HasA (NodeA 2)
                     $ g2
          -- NodeA 1 still connected through HasB to NodeB 2
          assertBool "NodeA 1 in RG" $ memberResource (NodeA 1) g3
          -- but NodeA 2 had its only link disconnected
          assertBool "NodeA 2 not in RG" $ memberResource (NodeA 2) g3 == False
          -- Create a cycle
          g4 <- syncWait $ connect (NodeA 3) HasB (NodeB 3)
                     . connect (NodeB 3) HasA (NodeA 4)
                     . connect (NodeA 4) HasB (NodeB 4)
                     . connect (NodeB 4) HasA (NodeA 3)
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
      , testSuccess "merge-resources" $ rGroupTest transport g $ \mm -> do
          g1 <- syncWait . connect (NodeA 1) HasA (NodeA 2) . sampleGraph =<< getGraph mm
          g2 <- syncWait $ mergeResources head [NodeA 1, NodeA 2] g1
          let es1 = connectedTo (NodeA 1) HasB g2 :: [NodeB]
              es2 = connectedFrom HasA (NodeA 1) g2 :: [NodeB]
              es3 = connectedTo (NodeB 2) HasA g2 :: [NodeA]
          assertBool "NodeA 1 is graph member" $ memberResource (NodeA 1) g2
          assertBool "NodeA 2 is not graph member" $ not $ memberResource (NodeA 2) g2
          assertEqual "length {NodeA 1}.HasB" 1 $ length es1
          assertEqual "length {NodeA 1}.HasA" 1 $ length es2
          assertBool "exists {NodeB 2}.HasA.{NodeA 1}" $ elem (NodeA 1) es3
          assertBool "not exists {NodeB 2}.HasA.{NodeA 2}" $ not $ elem (NodeA 2) es3
      , testSuccess "removeResource" $ rGroupTest transport g $ \mm -> do
          g1 <- syncWait . sampleGraph =<< getGraph mm
          g2 <- syncWait $ removeResource (NodeB 2) g1
          -- NodeB 2 connects everything - graph should now be totally disconnected
          let es1 = connectedTo (NodeA 1) HasB g2 :: [NodeB]
              es2 = connectedFrom HasA (NodeA 1) g2 :: [NodeB]
              es3 = connectedTo (NodeB 2) HasA g2 :: [NodeA]
          assertEqual "es1 is empty" [] es1
          assertEqual "es2 is empty" [] es2
          assertEqual "es3 is empty" [] es3
      , testSuccess "cardinalities" $ rGroupTest transport g $ \mm -> do
          g1 <- syncWait . sampleGraph =<< getGraph mm
          g2 <- syncWait . connect (NodeA 1) HasC (NodeC 1)
                         . connect (NodeA 2) HasC (NodeC 1)
                         . connect (NodeB 1) HasC (NodeC 1)
                         $ g1
          do
            -- Should get both NodeA nodes back
            let res = asUnbounded $ connectedFrom HasC (NodeC 1) g2 :: [NodeA]
            assertEqual "res is [NodeA 1, NodeA 2]"
              [NodeA 1, NodeA 2] (sort res)
          do
            -- Should get NodeC 1 back as a Maybe
            let es1 = connectedTo (NodeA 1) HasC g2 :: Maybe NodeC
            assertEqual "es1 is Just (NodeC 1)" (Just (NodeC 1)) es1
          g3 <- syncWait $ connect (NodeA 1) HasC (NodeC 2) g2
          do
            -- Should have replaced the NodeC due to cardinality
            let res = asUnbounded $ connectedTo (NodeA 1) HasC g3 :: [NodeC]
            assertEqual "res is [NodeC 2]" [NodeC 2] res
       , Merge.tests
       ]
