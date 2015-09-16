{-# LANGUAGE TemplateHaskell #-}
module HA.Autoboot.Tests
  ( tests
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Internal.Types
import Control.Distributed.Process.Node
import qualified Control.Distributed.Process.Scheduler as Scheduler
import Control.Distributed.Static ( closureCompose )
import qualified Control.Exception as E
import Control.Monad.Reader ( ask )
import Data.Foldable (forM_)
import qualified Data.Set as Set

import Network.Transport (Transport(..))
import Network.Transport.InMemory (createTransport)

import HA.RecoveryCoordinator.Definitions
import HA.RecoveryCoordinator.Mero
import HA.Network.RemoteTables (haRemoteTable)
import Mero.RemoteTables (meroRemoteTable)

import qualified HA.EQTracker as EQT
import HA.NodeUp ( nodeUp )
import HA.Startup hiding (__remoteTable)
import Test.Framework
import Test.Tasty.HUnit
import System.IO
import System.Random
import System.Timeout


myRemoteTable :: RemoteTable
myRemoteTable = haRemoteTable $ meroRemoteTable initRemoteTable

tests :: Transport -> [TestTree]
tests transport = map (localOption (mkTimeout $ 60*1000000))
    -- TODO: Investigate random failures occurring in this test
    -- (even with the same seed).
    --
    -- TODO: Fix when running with seed -4491321425843199644.
  [ testSuccess "eqt-receive-all-tracking-stations [disabled]"
                $ const (return ()) $ eqtReceiveAllStations transport
    -- TODO: Enable this test after fixing it.
    -- It is failing with seed 7310084895444705829
  , testSuccess "eqt-receive-stations-at-start [disabled]"
                $ const (return ()) $ eqtReceiveStationsAtStart transport
  ]

eqtReceiveAllStations :: Transport -> IO ()
eqtReceiveAllStations transport =
  runTest 6 20 15000000 transport myRemoteTable $ \nids -> do
    node <- fmap processNode ask
    bootupCluster $ node : nids
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
  runTest 7 20 15000000 transport myRemoteTable $ \nodes@(_ : nids) -> do
    _ <- spawnLocal $ bootupCluster nodes
    _ <- spawnLocal $ EQT.eqTrackerProcess [localNodeId $ head nids]
    nodeUp (map localNodeId nids, 1000000)
    Just eq <- whereis EQT.name
    self <- getSelfPid
    usend eq (EQT.ReplicaRequest self)
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
    liftIO $ autobootCluster (node:nids)
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

-- | Start dummy recovery coordinator
rcClosure :: Closure ([NodeId] -> ProcessId -> ProcessId -> Process ())
rcClosure = $(mkStaticClosure 'recoveryCoordinator) `closureCompose`
               $(mkStaticClosure 'ignitionArguments)

-- | Autoboot helper cluster
autobootCluster :: [LocalNode] -> IO ()
autobootCluster nids =
  forM_ nids $ \lnid ->
    forkProcess lnid $ startupHalonNode rcClosure

withLocalNode :: Transport -> RemoteTable -> (LocalNode -> IO a) -> IO a
withLocalNode t rt = E.bracket  (newLocalNode t rt) closeLocalNode

withLocalNodes :: Int
               -> Transport
               -> RemoteTable
               -> ([LocalNode] -> IO a)
               -> IO a
withLocalNodes 0 _t _rt f = f []
withLocalNodes n t rt f = withLocalNode t rt $ \node ->
    withLocalNodes (n - 1) t rt (f . (node :))

runTest :: Int -> Int -> Int -> Transport -> RemoteTable
        -> ([LocalNode] -> Process ()) -> IO ()
runTest numNodes numReps _t tr rt action
    | Scheduler.schedulerIsEnabled = do
        s <- randomIO
        -- TODO: Fix leaks in n-t-inmemory and use the same transport for all
        -- tests, maybe.
        forM_ [1..numReps] $ \i ->  withTmpDirectory $
          E.bracket createTransport closeTransport $
          \tr' -> do
            m <- timeout (7 * 60 * 1000000) $
              Scheduler.withScheduler (s + i) 1000 numNodes tr' rt' action
            maybe (error "Timeout") return m
          `E.onException`
            liftIO (hPutStrLn stderr $ "Failed with seed: " ++ show (s + i, i))
    | otherwise =
        withTmpDirectory $ withLocalNodes numNodes tr rt' $
          \(n : ns) -> do
            m <- timeout (7 * 60 * 1000000) $ runProcess n (action ns)
            maybe (error "Timeout") return m
  where
    rt' = Scheduler.__remoteTable rt
