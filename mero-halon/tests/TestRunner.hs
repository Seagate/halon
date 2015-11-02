-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE CPP #-}
module TestRunner
  ( runTest
  , withLocalNode
  , withLocalNodes
  ) where

import HA.Startup

import Control.Exception as E
import Control.Distributed.Process
import qualified Control.Distributed.Process as DP
import Control.Distributed.Process.Node
import qualified Control.Distributed.Process.Scheduler as Scheduler
import Network.Transport (Transport(..))
import Network.Transport.InMemory (createTransport)


import Data.Foldable
import System.Environment (lookupEnv)
import System.Random (randomIO)
import System.IO (stderr, hPutStrLn)
import System.Timeout (timeout)
import Test.Framework

-- | Implement a wrapper to start a test, checks current environment
-- runs a test and perform a cleanup.
runTest :: Int  -- ^ Number of nodes to start
        -> Int  -- ^ Number of test repetitions (used only for scheduler)
        -> Int  -- ^ Timeout
        -> Transport  -- ^ Transport to start nodes on.
        -> RemoteTable -- ^ Current remote table
        -> ([LocalNode] -> Process ())  -- ^ Test contents.
        -> IO ()
runTest numNodes numReps _t tr rt action
    | Scheduler.schedulerIsEnabled = do
        (s,numReps') <- lookupEnv "DP_SCHEDULER_SEED" >>= \mx -> case mx of
          Nothing -> (,numReps) <$> randomIO
          Just s  -> return (read s,1)
        -- TODO: Fix leaks in n-t-inmemory and use the same transport for all
        -- tests, maybe.
        forM_ [1..numReps'] $ \i ->  withTmpDirectory $
          E.bracket createTransport closeTransport $
          \tr' -> do
            hPutStrLn stderr $ "Testing with seed: " ++ show (s + i, i)
            m <- timeout (7 * 60 * 1000000) $
              Scheduler.withScheduler (s + i) 1000 numNodes tr' rt' $ \nodes ->
                action nodes `DP.finally` stopHalon nodes
            maybe (error "Timeout") return m
          `E.onException`
            liftIO (hPutStrLn stderr $ "Failed with seed: " ++ show (s + i, i))
    | otherwise =
        withTmpDirectory $ withLocalNodes numNodes tr rt' $
          \nodes@(n : ns) -> do
            m <- timeout (7 * 60 * 1000000) $ runProcess n $
              action ns `DP.finally` stopHalon nodes
            maybe (error "Timeout") return m
  where
    rt' = Scheduler.__remoteTable rt
    stopHalon nodes = do
      self <- getSelfPid
      forM_ nodes $ \node -> liftIO $ forkProcess node $ do
        stopHalonNode
        usend self ((), ())
      forM_ nodes $ const (expect :: Process ((), ()))

-- | Bracket-like function for local node, it starts a node, performs
-- computation and closes node at the end.
withLocalNode :: Transport -> RemoteTable -> (LocalNode -> IO a) -> IO a
withLocalNode t rt = E.bracket  (newLocalNode t rt) closeLocalNode

-- | Bracket-like function for starting test on many nodes, it starts
-- nodes, performs computations and stops them at the end.
withLocalNodes :: Int
               -> Transport
               -> RemoteTable
               -> ([LocalNode] -> IO a)
               -> IO a
withLocalNodes 0 _t _rt f = f []
withLocalNodes n t rt f = withLocalNode t rt $ \node ->
    withLocalNodes (n - 1) t rt (f . (node :))
