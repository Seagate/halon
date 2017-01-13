{-# LANGUAGE TemplateHaskell #-}
module HA.Autoboot.Tests
  ( tests
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Internal.Types
import Control.Distributed.Process.Node
import Control.Monad.Reader ( ask )
import Data.Foldable (forM_)
import qualified Data.Set as Set

import Network.Transport (Transport(..))

import HA.RecoveryCoordinator.Definitions
import HA.RecoveryCoordinator.Helpers
import HA.RecoveryCoordinator.Mero
import HA.Network.RemoteTables (haRemoteTable)
import Mero.RemoteTables (meroRemoteTable)

import qualified HA.EQTracker as EQT
import HA.EQTracker.Process as EQT
import HA.Multimap
import HA.NodeUp ( nodeUp )
import HA.Startup hiding (__remoteTable)
import Test.Framework
import Test.Tasty.HUnit

import TestRunner

myRemoteTable :: RemoteTable
myRemoteTable = haRemoteTable $ meroRemoteTable initRemoteTable

tests :: Transport -> [TestTree]
tests transport =
    [ testSuccess "eqt-receive-all-tracking-stations"
                  $ eqtReceiveAllStations transport
    , testSuccess "eqt-receive-stations-at-start"
                  $ eqtReceiveStationsAtStart transport
    ]

eqtReceiveAllStations :: Transport -> IO ()
eqtReceiveAllStations transport =
  runTest 6 10 15000000 transport myRemoteTable $ \nids -> do
    node <- fmap processNode ask
    bootupCluster $ node : nids
    say . ("requesting from node " ++). show =<< getSelfNode
    nodeUp $ map localNodeId nids
    meq <- whereis EQT.name
    say (show meq)
    Just eq <- return meq
    EQT.lookupReplicas (processNodeId eq)
    EQT.ReplicaReply (EQT.ReplicaLocation _ xs) <- expect
    liftIO $ assertEqual "list of trackers was updated"
                (Set.fromList xs)
                (Set.fromList $ map localNodeId nids)

eqtReceiveStationsAtStart :: Transport -> IO ()
eqtReceiveStationsAtStart transport = do
  runTest 7 10 15000000 transport myRemoteTable $ \nodes@(_ : nids) -> do
    _ <- spawnLocal $ bootupCluster nodes
    _ <- EQT.startEQTracker [localNodeId $ head nids]
    nodeUp $ map localNodeId nids
    Just eq <- whereis EQT.name
    EQT.lookupReplicas (processNodeId eq)
    EQT.ReplicaReply (EQT.ReplicaLocation _ xs) <- expect
    liftIO $ assertEqual "nodes updated" (Set.fromList $ map localNodeId nids)
                                         (Set.fromList xs)

-- | Startup cluster. This function autoboots required number of nodes.
bootupCluster :: [LocalNode] -> Process ()
bootupCluster = \(node : nids) -> do
    let args = ( False :: Bool
               , map localNodeId nids
               , 1000 :: Int
               , 1000000 :: Int
               , $(mkClosure 'recoveryCoordinator) $ IgnitionArguments (map localNodeId nids)
               , 8*1000000 :: Int
               )
    -- 1. Autoboot cluster
    autobootCluster (node:nids)
    -- 2. Run ignition once
    _ <- ignition args
    sayTest "bootupCluster finished"

-- | Start dummy recovery coordinator
rcClosure :: Closure ([NodeId] -> ProcessId -> StoreChan -> Process ())
rcClosure = $(mkStaticClosure 'recoveryCoordinator)

-- | Autoboot helper cluster
autobootCluster :: [LocalNode] -> Process ()
autobootCluster nids = do
    self <- getSelfPid
    liftIO $ forM_ nids $ \lnid -> forkProcess lnid $ do
      startupHalonNode rcClosure
      usend self ((), ())
    forM_ nids $ \_ -> do
      ((), ()) <- expect
      return ()
