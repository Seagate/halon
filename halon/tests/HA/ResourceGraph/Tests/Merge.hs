-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
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

import HA.ResourceGraph hiding (__remoteTable)
import HA.Resources.TH
import HA.SafeCopy

import Control.Monad (replicateM)

import Data.Hashable (Hashable)
import Data.List (delete, foldl', nub)
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Test.Framework
import Test.QuickCheck

newtype Node = Node Integer
  deriving (Eq, Hashable, Ord, Typeable, Generic, Show)

data Link = Link
  deriving (Eq, Ord, Typeable, Generic, Show)

instance Hashable Link

deriveSafeCopy 0 'base ''Node
deriveSafeCopy 0 'base ''Link

$(mkDicts
  [''Node]
  [ (''Node, ''Link, ''Node) ])
$(mkResRel
  [''Node]
  [ (''Node, Unbounded, ''Link, Unbounded, ''Node) ]
  []
  )

-- | A fake graph with no backing multimap. Calling `sync` on this Graph
--   will always fail!
fakeEmptyGraph :: Graph
fakeEmptyGraph = emptyGraph undefined

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
    relCount <- arbitrary
    relations <- replicateM relCount $ do
      from <- elements resources
      to <- elements resources
      return (from, to)
    return . GraphBuilder
      $ (foldl' (.) id (newResource <$> resources))
      . (foldl' (.) id ((\(f, t) -> connect f Link t) <$> relations))

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

tests :: [TestTree]
tests = [
    testSuccess "prop_mergedResourcesAreGone" $ quickCheck prop_mergedResourcesAreGone
  , testSuccess "prop_newResourceExists" $ quickCheck prop_newResourceExists
  , testSuccess "prop_noSelfLinks" $ quickCheck prop_noSelfLinks
  , testSuccess "prop_forwardLinksMerged" $ quickCheck prop_forwardLinksMerged
  , testSuccess "prop_backwardLinksMerged" $ quickCheck prop_backwardLinksMerged
  ]
