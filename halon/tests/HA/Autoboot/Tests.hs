-- |
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--

{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}

module HA.Autoboot.Tests (tests) where

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Internal.Types
import Control.Distributed.Process.Node
import qualified Control.Distributed.Process.Scheduler as Scheduler
import Data.List

import Network.Transport (Transport(..))
import Network.Transport.InMemory (createTransport)
import qualified Data.Set as Set

import qualified Control.Exception as E
import qualified Control.Monad.Catch as C
import Control.Monad.Reader
import HA.Multimap (StoreChan)
import HA.Network.RemoteTables (haRemoteTable)
import HA.Startup hiding (__remoteTable)
import Test.Transport
import Test.Framework
import Test.Tasty.HUnit
import System.IO
import System.Random
import System.Timeout


dummyRC :: SendPort () -> ProcessId -> StoreChan -> Process ()
dummyRC sp _eq _mm = do
  sendChan sp ()
  receiveWait []

rcClosure :: SendPort () -> [NodeId] -> ProcessId -> StoreChan -> Process ()
rcClosure sp _ = dummyRC sp

type IgnitionResult = Maybe (Bool,[NodeId],[NodeId],[NodeId])

remotable [ 'dummyRC, 'rcClosure ]

tests :: AbstractTransport -> IO [TestTree]
tests transport =
  return [ testSuccess "autoboot-simple" $ mkAutobootTest (getTransport transport)
         , testCase  "ignition" $ testIgnition (getTransport transport)
         ]

-- | Test that cluster could be automatically booted after a failure
-- without any manual interaction.
mkAutobootTest :: Transport -- ^ Nodes on which to start the tracking stations
               -> IO ()
mkAutobootTest transport =
    -- 0. Run autoboot on 5 nodes
    runTest 6 20 transport (__remoteTable $ haRemoteTable $ initRemoteTable) $
      \nids -> do
      (sp, rp) <- newChan
      let args = ( False :: Bool
                 , map localNodeId nids
                 , 1000 :: Int
                 , 1000000 :: Int
                 , $(mkClosure 'dummyRC) sp
                 , 3*1000000 :: Int
                 )

      say "Autoboot cluster"
      autobootCluster sp nids

      say "Run ignition once"
      self <- getSelfPid
      _ <- liftIO $ forkProcess (head nids) $ ignition args >>= usend self
      result <- expect
      case result :: IgnitionResult of
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

      say "Wait RC to spawn."
      receiveChan rp

      say "Kill all processes."
      -- Instead of stopping the node we kill all processes. This is a way of
      -- simulating a node dying and coming back again without actually ending
      -- the unix process. Creating a new node on the same unix process would
      --  assign a different NodeId to it, and this in turn changes the location
      -- where the persisted state is expected to be.
      liftIO $ forM_ nids $ \lnid -> forkProcess lnid $ do
        stopHalonNode
        usend self ((), ())
      forM_ nids $ const $ do
        ((), ()) <- expect
        return ()

      say "Run autoboot once again."
      autobootCluster sp nids

      say "Wait for RC to spawn."
      receiveChan rp

autobootCluster :: SendPort () -> [LocalNode] -> Process ()
autobootCluster sp nids = do
    self <- getSelfPid
    liftIO $ forM_ nids $ \lnid -> forkProcess lnid $ do
      startupHalonNode $ $(mkClosure 'rcClosure) sp
      usend self ((), ())
    forM_ nids $ \_ -> do
      ((), ()) <- expect
      return ()


-- | Test that ignition call will retrn supposed result.
testIgnition :: Transport
             -> IO ()
testIgnition transport =
    runTest 6 20 transport (__remoteTable $ haRemoteTable $ initRemoteTable) $
      \nids -> do
      say $ "Starting test: " ++ show (map localNodeId nids)
      (sp :: SendPort (), rp) <- newChan
      let (nids1, nids2) = splitAt 3 nids
          mkArgs b ns  = ( b :: Bool
                       , map localNodeId ns
                       , 1000 :: Int
                       , 1000000 :: Int
                       , $(mkClosure 'dummyRC) sp
                       , 3*1000000 :: Int
                       )
          args = mkArgs False nids1
      lproc <- ask
      say "Autobooting ..."
      autobootCluster sp (processNode lproc: nids)

      say "Calling ignition ..."
      self <- getSelfPid
      _ <- liftIO $ forkProcess (head nids1) $ ignition args >>= usend self
      Nothing <- expect :: Process IgnitionResult
      receiveChan rp

      say "Calling ignition for update ..."
      _ <- liftIO $ forkProcess (head nids1) $
             ignition (mkArgs True (head nids1: nids2)) >>= usend self
      Just (added, trackers, members, newNodes) <-
        expect :: Process IgnitionResult

      say "Stopping cluster ..."
      liftIO $ do
        forM_ (tail nids1) $ \nid -> do
          forkProcess nid $ do
            stopHalonNode
            usend self ((), ())
      forM_ (tail nids1) $ \_ -> do
        ((), ()) <- expect
        return ()

      say "Assertions ..."
      liftIO $ do
        assertBool  "set of node changed" added
        assertEqual "nodes from new set added"
                    (Set.fromList $ map localNodeId nids2)
                    (Set.fromList newNodes)
        assertEqual "only one node was in members"
                    (Set.singleton (localNodeId $ head nids1))
                    (Set.fromList members)
        assertEqual "trackers should be equal to the new set of trackers"
                    (Set.fromList (map localNodeId $ head nids1:nids2))
                    (Set.fromList trackers)
      _ <- liftIO $ forkProcess (head nids1) $ do
        (sp', rp') <- newChan
        getTrackingStationMembership sp'
        receiveChan rp' >>= usend self
      actual <- expect
      liftIO $ unless (fmap sort actual == Just (sort trackers)) $
        assertFailure $ "replicas should contain all of the " ++ show trackers ++
                        ", but got " ++ show actual

runTest :: Int -> Int -> Transport -> RemoteTable
        -> ([LocalNode] -> Process ()) -> IO ()
runTest numNodes numReps tr rt action
    | Scheduler.schedulerIsEnabled = do
        s <- randomIO
        hPutStrLn stderr $ "Starting test with seed: " ++ show s
        -- TODO: Fix leaks in n-t-inmemory and use the same transport for all
        -- tests, maybe.
        forM_ [1..numReps] $ \i ->  withTmpDirectory $
          E.bracket createTransport closeTransport $ \tr' ->
          let s' = s + i - 1 in do
            m <- timeout (7 * 60 * 1000000) $
              Scheduler.withScheduler s' 500 numNodes tr' rt' $ \nodes ->
                action nodes `C.finally` stopHalon nodes
            maybe (error "Timeout") return m
          `E.onException`
            liftIO (hPutStrLn stderr $ "Failed with seed: " ++ show (s', i))
    | otherwise =
        withTmpDirectory $ withLocalNodes numNodes tr rt' $
          \nodes@(n : ns) -> do
            m <- timeout (7 * 60 * 1000000) $ runProcess n $
              action ns `C.finally` stopHalon nodes
            maybe (error "Timeout") return m
  where
    rt' = Scheduler.__remoteTable rt
    stopHalon nodes = do
        self <- getSelfPid
        forM_ nodes $ \node -> liftIO $ forkProcess node $ do
          stopHalonNode
          usend self ((), ())
        forM_ nodes $ const (expect :: Process ((), ()))
