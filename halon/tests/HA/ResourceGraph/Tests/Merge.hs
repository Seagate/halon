-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Tests of 'mergeResources' functionality.

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving #-}

module HA.ResourceGraph.Tests.Merge (tests) where

import HA.Aeson (ToJSON)
import HA.Multimap (StoreUpdate(..))
import HA.ResourceGraph hiding (__remoteTable)
import HA.Resources.TH
import HA.SafeCopy

import Control.Monad (replicateM)

import Data.Hashable (Hashable)
import Data.List (delete, intersect, foldl', nub)
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Test.Framework
import Test.Tasty.QuickCheck

newtype Node = Node Integer
  deriving (Eq, Hashable, Ord, Typeable, Generic, Show)

storageIndex ''Node "c0fff54b-453a-4321-9464-2e196843e1fc"
instance ToJSON Node

data Link = Link
  deriving (Eq, Ord, Typeable, Generic, Show)

storageIndex ''Link "eda392bb-93ec-4c3e-b7bc-7e35cba9c910"
instance Hashable Link
instance ToJSON Link

deriveSafeCopy 0 'base ''Node
deriveSafeCopy 0 'base ''Link

$(mkDicts
  [''Node, ''Link]
  [ (''Node, ''Link, ''Node) ])
$(mkResRel
  [''Node, ''Link]
  [ (''Node, Unbounded, ''Link, Unbounded, ''Node) ]
  []
  )

-- | A fake graph with no backing multimap. Calling `sync` on this Graph
--   will always fail!
fakeEmptyGraph :: Graph
fakeEmptyGraph = emptyGraph (error "fakeEmpyGraph: StoreChan is not initialized")

deriving instance Arbitrary Node

data MergeTest = MergeTest {
    _graph :: Graph
  , _mergeNodes :: [Node]
  , _intoNode :: Node
  , _mergedGraph :: Graph
} deriving (Show)

newtype GraphBuilder = GraphBuilder (Graph -> Graph)

instance Arbitrary GraphBuilder where
  arbitrary = do
    resources <- listOf1 (arbitrary :: Gen Node)
    relCount <- suchThat arbitrary (> 0)
    relations <- replicateM relCount $ do
      from <- elements resources
      to <- elements resources
      return (from, to)
    return . GraphBuilder
      $ foldl' (.) id ((\(f, t) -> connect f Link t) <$> relations)

instance Arbitrary MergeTest where
  arbitrary = do
    graph <- arbitrary >>= \(GraphBuilder gb) -> return $ gb fakeEmptyGraph
    nodes <- suchThat (sublistOf $ getResourcesOfType graph) (not . Prelude.null)
    toNode <- oneof [arbitrary, elements nodes]
    return $ MergeTest graph nodes toNode
              (mergeResources (const toNode) nodes graph)

-- | Verify that there are no merged resources remaining in the graph.
prop_mergedResourcesAreGone :: MergeTest -> Bool
prop_mergedResourcesAreGone (MergeTest _ nodes to rg') = let
    goneX = delete to nodes
  in all (not . flip memberResource rg') goneX

-- | Verify that the new resource exists in the graph.
prop_newResourceExists :: MergeTest -> Bool
prop_newResourceExists (MergeTest _ _ to rg') = memberResource to rg'

-- | Verify that there are no *more* self links in the new graph than
--   there were in the old graph.
prop_noSelfLinks ::  MergeTest -> Bool
prop_noSelfLinks (MergeTest rg nodes to rg') = let
    oldSelfLinks = any (\n -> isConnected n Link n rg) (nub $ to : nodes)
    newSelfLinks = isConnected to Link to rg'
  in if newSelfLinks then oldSelfLinks else True

-- | Verify that forward links to all other resources are established.
prop_forwardLinksMerged :: MergeTest -> Bool
prop_forwardLinksMerged (MergeTest rg nodes to rg') = let
    allNodes = nub $ to : nodes
    oldConnectedTo :: [Node]
    oldConnectedTo = filter (\n -> not $ elem n allNodes) . nub
                   $ allNodes >>= (\n -> connectedTo n Link rg)
  in all (\n -> isConnected to Link n rg') oldConnectedTo

-- | Verify that backwards links to all other resources are established.
prop_backwardLinksMerged :: MergeTest -> Bool
prop_backwardLinksMerged (MergeTest rg nodes to rg') = let
    isConnected' x r y g = memberEdgeBack (Edge x r y) g
    allNodes = nub $ to : nodes
    oldConnectedTo :: [Node]
    oldConnectedTo = filter (\n -> not $ elem n allNodes) . nub
                   $ allNodes >>= (\n -> connectedTo n Link rg)
  in all (\n -> isConnected' to Link n rg') oldConnectedTo

-- | Verify that no current nodes have any outgoing or incoming connections
--   to old nodes.
prop_noConnectionToOldNodes :: MergeTest -> Bool
prop_noConnectionToOldNodes (MergeTest _ nodes to rg') = let
    isConnected' x r y g = memberEdgeBack (Edge x r y) g
    oldNodes = delete to nodes
    currentNodes = (getResourcesOfType rg' :: [Node])
    pairs = [(o,n) | o <- oldNodes, n <- currentNodes]
    checks o n = not
               $ isConnected o Link n rg'
              || isConnected n Link o rg'
              || isConnected' o Link n rg'
              || isConnected' n Link o rg'
  in all (uncurry checks) pairs

-- | Checks the following invariant for the changeLog:
--   * Edges in the insertion multimap are not present in the removal multimap.
prop_clEdgeInsertionRemoval :: MergeTest -> Bool
prop_clEdgeInsertionRemoval (MergeTest _ _ _ rg') = let
    cl = getStoreUpdates rg'
    insertedEdges = [ e
                    | (InsertMany kvs) <- cl
                    , (_, vs) <- kvs
                    , e <- vs
                    ]
    removalEdges =  [ e
                    | (DeleteValues kvs) <- cl
                    , (_, vs) <- kvs
                    , e <- vs
                    ]
  in insertedEdges `intersect` removalEdges == []

-- | Checks the following invariant for the changeLog:
--   * Nodes in the insertion multimap are not present in the removal set.
prop_clNodeInsertionRemoval :: MergeTest -> Bool
prop_clNodeInsertionRemoval (MergeTest _ _ _ rg') = let
    cl = getStoreUpdates rg'
    insertedNodes = [ n
                    | (InsertMany kvs) <- cl
                    , (n, _) <- kvs
                    ]
    removalNodes =  [ n
                    | (DeleteKeys ks) <- cl
                    , n <- ks
                    ]
  in insertedNodes `intersect` removalNodes == []

-- | Checks the following invariant for the changeLog:
--   * Nodes in the removal multimap are not present in removal set.
prop_clNodeRemovalRemoval :: MergeTest -> Bool
prop_clNodeRemovalRemoval (MergeTest _ _ _ rg') = let
    cl = getStoreUpdates rg'
    insertedNodes = [ n
                    | (DeleteValues kvs) <- cl
                    , (n, _) <- kvs
                    ]
    removalNodes =  [ n
                    | (DeleteKeys ks) <- cl
                    , n <- ks
                    ]
  in insertedNodes `intersect` removalNodes == []

tests :: TestTree
tests = localOption (QuickCheckTests 1000) $ testGroup "mergeResources" [
    testProperty "prop_mergedResourcesAreGone" $ prop_mergedResourcesAreGone
  , testProperty "prop_newResourceExists" $ prop_newResourceExists
  , testProperty "prop_noSelfLinks" $ prop_noSelfLinks
  , testProperty "prop_forwardLinksMerged" $ prop_forwardLinksMerged
  , testProperty "prop_backwardLinksMerged" $ prop_backwardLinksMerged
  , testProperty "prop_noConnectionToOldNodes" $ prop_noConnectionToOldNodes
  , testProperty "prop_clEdgeInsertionRemoval" $ prop_clEdgeInsertionRemoval
  , testProperty "prop_clNodeInsertionRemoval" $ prop_clNodeInsertionRemoval
  , testProperty "prop_clNodeRemovalRemoval" $ prop_clNodeRemovalRemoval
  ]
