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
import Data.Binary (Binary)
import Data.Hashable (Hashable)
import Data.List (sort, (\\))
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

import RemoteTables (remoteTable)
import Test.Framework

--------------------------------------------------------------------------------
-- Types                                                                      --
--------------------------------------------------------------------------------

data NodeA = NodeA Int
  deriving (Eq, Typeable, Generic)

instance Hashable NodeA
instance Binary NodeA

data NodeB = NodeB Int
  deriving (Eq, Typeable, Generic)

instance Hashable NodeB
instance Binary NodeB

data HasA = HasA
  deriving (Eq, Typeable, Generic)

instance Hashable HasA
instance Binary HasA

data HasB = HasB
  deriving (Eq, Typeable, Generic)

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

mmSDict :: SerializableDict Multimap
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
        rGroup <- newRGroup $(mkStatic 'mmSDict) [nid] (fromList []) >>=
                  unClosure >>= (`asTypeOf` return g)
        mmpid <- spawnLocal $ catch (multimap rGroup) $
          (\e -> liftIO $ print (e :: SomeException))
        p mmpid

sampleGraph :: Graph -> Graph
sampleGraph =
    connect (NodeB 2) HasA (NodeA 1) .
    connect (NodeB 2) HasA (NodeA 2) .
    connect (NodeA 1) HasB (NodeB 2) .
    newResource (NodeB 2) .
    newResource (NodeB 1) .
    newResource (NodeA 2) .
    newResource (NodeA 1)

--------------------------------------------------------------------------------
-- Tests                                                                      --
--------------------------------------------------------------------------------

tests :: Transport -> IO [TestTree]
tests transport = do
    let g = undefined :: MC_RG Multimap
    return
      [ testSuccess "initial-graph" $ rGroupTest transport g $ \pid -> do
          _g <- sync =<< getGraph pid
          Just ns <- getKeyValuePairs pid
          assert $ ns == []

      , testSuccess "kv-length" $ rGroupTest transport g $ \pid -> do
          _g <- sync . sampleGraph =<< getGraph pid
          Just kvs <- getKeyValuePairs pid
          assert $ 4 == length kvs
          assert $ [0, 0, 1, 2] == sort (map (length . snd) kvs)

      , testSuccess "edge-nodeA-1" $ rGroupTest transport g $ \pid -> do
          g1 <- sync . sampleGraph =<< getGraph pid
          let es0 = edgesFromSrc (NodeA 1) g1
          assert $ length es0 == 1
          assert $ [] == es0 \\ [Edge (NodeA 1) HasB (NodeB 2)]

      , testSuccess "edge-nodeB-2" $ rGroupTest transport g $ \pid -> do
          g1 <- sync . sampleGraph =<< getGraph pid
          let es1 = connectedTo (NodeB 2) HasA g1
          assert $ length es1 == 2
          assert $ [] == es1 \\ [NodeA 1, NodeA 2]
          assert $ [] == (connectedTo (NodeB 1) HasA g1 :: [NodeA])

      , testSuccess "edge-nodeB-2-disconnect" $ rGroupTest transport g $ \pid -> do
          g1 <- sync . sampleGraph =<< getGraph pid
          _ <- sync $ disconnect (NodeB 2) HasA (NodeA 1) g1
          g2 <- getGraph pid
          let es2 = connectedTo (NodeB 2) HasA g2
          assert $ length es2 == 1
          assert $ [] == es2 \\ [NodeA 2]
      ]
