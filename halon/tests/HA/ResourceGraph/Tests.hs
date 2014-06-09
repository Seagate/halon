-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Tests for the resource graph
--

{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module HA.ResourceGraph.Tests ( tests ) where

import HA.Network.Address ( Network, getNetworkTransport )
import HA.Multimap.Process ( multimap )
import HA.Multimap ( getKeyValuePairs )
import HA.Multimap.Implementation ( fromList, Multimap )
import HA.Process
import HA.ResourceGraph
import HA.Replicator ( RGroup(..) )
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock ( MC_RG )
#else
import HA.Replicator.Log ( MC_RG )
#endif
import RemoteTables ( remoteTable )

import Control.Distributed.Process
    ( Process, spawnLocal, liftIO, catch, ProcessId, getSelfNode, unClosure )
import Control.Distributed.Process.Closure ( remotable, mkStatic )
import Control.Distributed.Process.Serializable ( SerializableDict(..) )
import Control.Distributed.Process.Node ( newLocalNode, closeLocalNode )

import Control.Concurrent ( MVar, newEmptyMVar, putMVar, takeMVar, threadDelay )
import Control.Exception ( SomeException )
import Data.Binary ( Binary )
import Data.Hashable ( Hashable )
import Data.List ( sort, (\\) )
import Data.Typeable ( Typeable(..), Typeable1 )
import GHC.Generics ( Generic )
import System.Exit ( exitFailure )
import System.IO.Unsafe ( unsafePerformIO )
import Test.Framework

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

resourceDictNodeA, resourceDictNodeB :: Some ResourceDict
resourceDictNodeA = mkResourceDict (undefined :: NodeA)
resourceDictNodeB = mkResourceDict (undefined :: NodeB)

relationDictHasBNodeANodeB, relationDictHasANodeBNodeA :: Some RelationDict
relationDictHasBNodeANodeB = mkRelationDict (undefined :: (HasB,NodeA,NodeB))
relationDictHasANodeBNodeA = mkRelationDict (undefined :: (HasA,NodeB,NodeA))

runTestWithRGroup :: MC_RG Multimap -> Process ()
runTestWithRGroup rGroup = do
    mmpid <- spawnLocal $ catch (multimap rGroup) (\e -> liftIO $ print (e :: SomeException))
    testGraph mmpid

  where
    testGraph :: ProcessId -> Process ()
    testGraph mmpid = do
      g0 <- getGraph mmpid >>= sync
      Just [] <- getKeyValuePairs mmpid

      _ <- sync
	$ connect (NodeB 2) HasA (NodeA 1)
	$ connect (NodeB 2) HasA (NodeA 2)
	$ connect (NodeA 1) HasB (NodeB 2)
	$ newResource (NodeB 2)
	$ newResource (NodeB 1)
	$ newResource (NodeA 2)
	$ newResource (NodeA 1)
	g0
      g1 <- getGraph mmpid

      Just kvs <- getKeyValuePairs mmpid
      True <- return $ 4 == length kvs
      True <- return $ [0,0,1,2] == sort (map (length . snd) kvs)

      let es0 = edgesFromSrc (NodeA 1) g1
      True <- return $ length es0 == 1
      True <- return $ [] == es0 \\ [ Edge (NodeA 1) HasB (NodeB 2) ]

      let es1 = connectedTo (NodeB 2) HasA g1
      True <- return $ length es1 == 2
      True <- return $ [] == es1 \\ [ NodeA 1, NodeA 2 ]

      True <- return $ [] == (connectedTo (NodeB 1) HasA g1 :: [NodeA])

      _ <- sync $ disconnect (NodeB 2) HasA (NodeA 1) g1
      g2 <- getGraph mmpid
      let es2 = connectedTo (NodeB 2) HasA g2
      True <- return $ length es2 == 1
      True <- return $ [] == es2 \\ [ NodeA 2 ]

      printTest "ResourceGraph" True
      liftIO $ putMVar mdone ()

    printTest s b = liftIO $
      do putStr (s ++ ": ")
	 if b then putStrLn "Ok"
	  else putStrLn "Failed" >> exitFailure

{-# NOINLINE mdone #-}
mdone :: MVar ()
mdone = unsafePerformIO $ newEmptyMVar

mmSDict :: SerializableDict Multimap
mmSDict = SerializableDict

remotable [ 'resourceDictNodeA, 'resourceDictNodeB, 'mmSDict
	  , 'relationDictHasBNodeANodeB, 'relationDictHasANodeBNodeA
	  ]

instance Resource NodeA where
  resourceDict _ = $(mkStatic 'resourceDictNodeA)
instance Resource NodeB where
  resourceDict _ = $(mkStatic 'resourceDictNodeB)

instance Relation HasB NodeA NodeB where
  relationDict _ = $(mkStatic 'relationDictHasBNodeANodeB)
instance Relation HasA NodeB NodeA where
  relationDict _ = $(mkStatic 'relationDictHasANodeBNodeA)

rGroupTest ::
    (RGroup g, Typeable1 g)
    => Network -> g Multimap -> (ProcessId -> Process ()) -> IO ()
rGroupTest network g p = withTmpDirectory $ do
    lnode <- newLocalNode (getNetworkTransport network) $
	    __remoteTable remoteTable
    tryRunProcess lnode $
      flip catch (\e -> liftIO $ print (e :: SomeException)) $ do
	nid <- getSelfNode
	rGroup <- newRGroup $(mkStatic 'mmSDict) [nid] (fromList []) >>=
		  unClosure >>= (`asTypeOf` return g)
	mmpid <- spawnLocal $ catch (multimap rGroup) $
	   (\e -> liftIO $ print (e :: SomeException))
	p mmpid
	liftIO $ putMVar mdone ()
    -- Exit after transport stops being used.
    -- TODO: fix closeTransport and call it here (see ticket #211).
    -- TODO: implement closing RGroups and call it here.
    takeMVar mdone
    threadDelay 2000000
    closeLocalNode lnode

sampleGraph :: Graph -> Graph
sampleGraph =
    connect (NodeB 2) HasA (NodeA 1) .
    connect (NodeB 2) HasA (NodeA 2) .
    connect (NodeA 1) HasB (NodeB 2) .
    newResource (NodeB 2) .
    newResource (NodeB 1) .
    newResource (NodeA 2) .
    newResource (NodeA 1)

tests :: Network -> IO [TestTree]
tests network = do
    let g = undefined :: MC_RG Multimap
    return
	[ testSuccess "initial-graph" $ rGroupTest network g $ \pid -> do
	       _g <- sync =<< getGraph pid
	       Just ns <- getKeyValuePairs pid
	       assert $ ns == []

	, testSuccess "kv-length" $ rGroupTest network g $ \pid -> do
	       _g <- sync . sampleGraph =<< getGraph pid
	       Just kvs <- getKeyValuePairs pid
	       assert $ 4 == length kvs
	       assert $ [0,0,1,2] == sort (map (length . snd) kvs)

	, testSuccess "edge-nodeA-1" $ rGroupTest network g $ \pid -> do
	       g1 <- sync . sampleGraph =<< getGraph pid
	       let es0 = edgesFromSrc (NodeA 1) g1
	       assert $ length es0 == 1
	       assert $ [] == es0 \\ [ Edge (NodeA 1) HasB (NodeB 2) ]

	, testSuccess "edge-nodeB-2" $ rGroupTest network g $ \pid -> do
	       g1 <- sync . sampleGraph =<< getGraph pid
	       let es1 = connectedTo (NodeB 2) HasA g1
	       assert $ length es1 == 2
	       assert $ [] == es1 \\ [ NodeA 1, NodeA 2 ]
	       assert $ [] == (connectedTo (NodeB 1) HasA g1 :: [NodeA])

	, testSuccess "edge-nodeB-2-disconnect" $ rGroupTest network g $ \pid -> do
	       g1 <- sync . sampleGraph =<< getGraph pid
	       _ <- sync $ disconnect (NodeB 2) HasA (NodeA 1) g1
	       g2 <- getGraph pid
	       let es2 = connectedTo (NodeB 2) HasA g2
	       assert $ length es2 == 1
	       assert $ [] == es2 \\ [ NodeA 2 ]
	]
