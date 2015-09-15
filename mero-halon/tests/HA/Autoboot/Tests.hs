{-# LANGUAGE TemplateHaskell #-}
module HA.Autoboot.Tests
  ( tests
  ) where

import Control.Concurrent
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import Control.Distributed.Static ( closureCompose )
import Control.Monad ( replicateM )
import Data.Foldable (forM_)
import qualified Data.Set as Set

import Network.Transport (Transport)

import HA.RecoveryCoordinator.Definitions
import HA.RecoveryCoordinator.Mero
import HA.Network.RemoteTables (haRemoteTable)
import Mero.RemoteTables (meroRemoteTable)

import qualified HA.EQTracker as EQT
import HA.NodeUp ( nodeUp )
import HA.Startup hiding (__remoteTable)
import Test.Framework
import Test.Tasty.HUnit

myRemoteTable :: RemoteTable
myRemoteTable = haRemoteTable $ meroRemoteTable initRemoteTable

tests :: Transport -> [TestTree]
tests transport = map (localOption (mkTimeout $ 60*1000000))
  [ testSuccess "eqt-receive-all-tracking-stations"
                $ eqtReceiveAllStations transport
  , testSuccess "eqt-receive-stations-at-start"
                $ eqtReceiveStationsAtStart transport
  ]

eqtReceiveAllStations :: Transport -> IO ()
eqtReceiveAllStations transport = withTmpDirectory $ do
  (node, nids) <- bootupCluster transport (Right 5)
  runProcess node $ do
    say . ("requesting from node " ++). show =<< getSelfNode
    nodeUp (map localNodeId nids, 1000000)
    meq <- whereis EQT.name
    say (show meq)
    Just eq <- return meq
    self <- getSelfPid
    usend eq (EQT.ReplicaRequest self)
    EQT.ReplicaReply (EQT.ReplicaLocation _ xs) <- expect
    liftIO $ assertEqual "list of trackers was updated"
                (Set.fromList xs)
                (Set.fromList $ map localNodeId nids)

eqtReceiveStationsAtStart :: Transport -> IO ()
eqtReceiveStationsAtStart transport = withTmpDirectory $ do
  nids <- replicateM 5 $ newLocalNode transport $ myRemoteTable
  node <- newLocalNode transport $ myRemoteTable
  lock <- newEmptyMVar
  _    <- forkProcess node $ do
    _ <- spawnLocal $ EQT.eqTrackerProcess [localNodeId $ head nids]
    nodeUp (map localNodeId nids, 1000000)
    Just eq <- whereis EQT.name
    self <- getSelfPid
    usend eq (EQT.ReplicaRequest self)
    EQT.ReplicaReply (EQT.ReplicaLocation _ xs) <- expect
    liftIO $ putMVar lock (Set.fromList xs)
  _ <- bootupCluster transport (Left nids)
  assertEqual "nodes updated" (Set.fromList $ map localNodeId nids)
                              =<< takeMVar lock
  return ()

-- | Startup cluster. This function autoboots required number of nodes
-- and return a head node (that is not part of the cluster), and list
-- of tracking stations.
bootupCluster :: Transport
              -> (Either [LocalNode] Int) -- ^ list of nodes to bootstrap or number
                                          --   of nodes to bootstrap
              -> IO (LocalNode, [LocalNode])
bootupCluster transport en = do
    nids <- case en of
              Left ns -> return ns
              Right n -> replicateM n $ newLocalNode transport $ myRemoteTable
    let args = ( False :: Bool
               , map localNodeId nids
               , 1000 :: Int
               , 1000000 :: Int
               , $(mkClosure 'recoveryCoordinator) $ IgnitionArguments (map localNodeId nids)
               , 8*1000000 :: Int
               )
    node <- newLocalNode transport $ myRemoteTable
    -- 1. Autoboot cluster
    liftIO $ autobootCluster (node:nids)
    runProcess node $ do
      -- 2. Run ignition once
      (sp, rp) <- Control.Distributed.Process.newChan
      _ <- liftIO $ forkProcess (head nids) $ ignition args >>= sendChan sp
      result <- receiveChan rp
      case result of
        Just (added, _, members, newNodes) -> liftIO $ do
          if added then do
            putStrLn "The following nodes joined successfully:"
            mapM_ print newNodes
          else
            putStrLn "No new node could join the group."
          putStrLn ""
          putStrLn "The following nodes were already in the group:"
          mapM_ print members
        Nothing -> return ()
    return (node,nids)

-- | Start dummy recovery coordinator
rcClosure :: Closure ([NodeId] -> ProcessId -> ProcessId -> Process ())
rcClosure = $(mkStaticClosure 'recoveryCoordinator) `closureCompose`
               $(mkStaticClosure 'ignitionArguments)

-- | Autoboot helper cluster
autobootCluster :: [LocalNode] -> IO ()
autobootCluster nids =
  forM_ nids $ \lnid ->
    forkProcess lnid $ startupHalonNode rcClosure
