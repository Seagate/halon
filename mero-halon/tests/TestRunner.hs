-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
module TestRunner
  ( TestArgs(..)
  , runRCEx
  , runTest
  , tryRunProcessLocal
  , withLocalNode
  , withLocalNodes
  , withTrackingStation
  , eqDict
  , eqDict__static
  , mmDict
  , mmDict__static
  , emptyRules
  , emptyRules__static
  , startMockEventQueue
  , __remoteTableDecl
  ) where

import qualified HA.EQTracker as EQT
import HA.EventQueue
import HA.EventQueue.Types
import HA.Multimap.Implementation
import HA.Multimap.Process
import HA.Multimap
import HA.RecoveryCoordinator.Definitions
import HA.RecoveryCoordinator.Mero
import HA.Replicator
import HA.Startup (stopHalonNode)

import Control.Distributed.Process hiding (bracket, finally, onException)
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import Control.Monad.Catch
import qualified Control.Distributed.Process.Scheduler as Scheduler
import Control.Monad (join, void, forever)

import Data.Foldable
import Data.Proxy
import Data.Typeable

import Network.CEP hiding (timeout)
import Network.Transport (Transport(..))
import Network.Transport.InMemory (createTransport)

import System.Environment (lookupEnv)
import System.Random (randomIO)
import System.IO (stderr, hPutStrLn)
import System.Timeout (timeout)

import Test.Framework

remotableDecl [ [d|

  eqDict :: SerializableDict EventQueue
  eqDict = SerializableDict

  mmDict :: SerializableDict (MetaInfo, Multimap)
  mmDict = SerializableDict

  emptyRules :: [Definitions LoopState ()]
  emptyRules = []

  |]]

data TestArgs = TestArgs {
    ta_eq :: ProcessId
  , ta_mm :: StoreChan
  , ta_rc :: ProcessId
}

runRCEx :: RGroup g
        => (ProcessId, [NodeId])
        -> [Definitions LoopState ()]
        -> g (MetaInfo, Multimap)
        -> Process (StoreChan, ProcessId) -- ^ MM, RC
runRCEx (eq, eqNids) rules rGroup = do
  rec ((mm,cchan), rc) <- (,)
                  <$> (startMultimap rGroup
                                     (\go -> do
                                        () <- expect
                                        link rc
                                        go))
                  <*> (spawnLocal $ do
                        () <- expect
                        recoveryCoordinatorEx () rules eqNids eq cchan)
  usend eq rc
  forM_ [mm::ProcessId, rc] $ \them -> usend them ()
  return (cchan, rc)

-- | Wrapper to start a test with a Halon tracking station running. Returns
--   handles to the recovery co-ordinator, multimap and event queue.
withTrackingStation :: forall g. (Typeable g, RGroup g)
                    => Proxy g
                    -> [Definitions LoopState ()]
                    -> (TestArgs -> Process ())  -- ^ Test contents.
                    -> Process ()
withTrackingStation _ testRules action = do
  nid <- getSelfNode
  bracket
    (do
      void $ EQT.startEQTracker [nid]
      cEQGroup <- newRGroup $(mkStatic 'eqDict) "eqtest" 1000 1000000 4000000
                         [nid] emptyEventQueue
      cMMGroup <- newRGroup $(mkStatic 'mmDict) "mmtest" 1000 1000000 4000000
                         [nid] (defaultMetaInfo, fromList [])
      (,) <$> join (unClosure cEQGroup) <*> join (unClosure cMMGroup)
    )
    (\(g0, g1) -> killReplica g0 nid >> killReplica g1 nid)
    (\(eqGroup, mmGroup :: g (MetaInfo, Multimap)) -> do
      eq <- startEventQueue (eqGroup :: g EventQueue)
      (chan, rc) <- runRCEx (eq, [nid]) testRules mmGroup
      action $ TestArgs eq chan rc
    )

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
          bracket createTransport closeTransport $ \tr' ->
          let s' = s + i - 1 in do
            hPutStrLn stderr $ "Testing with seed: " ++ show (s', i)
            m <- timeout (7 * 60 * 1000000) $
              Scheduler.withScheduler s' 1000 numNodes tr' rt' $ \nodes ->
                action nodes `finally` stopHalon nodes
            maybe (error "Timeout") return m
          `onException`
            liftIO (hPutStrLn stderr $ "Failed with seed: " ++ show (s', i))
    | otherwise =
        withTmpDirectory $ withLocalNodes numNodes tr rt' $
          \nodes@(n : ns) -> do
            m <- timeout (7 * 60 * 1000000) $ runProcess n $
              action ns `finally` stopHalon nodes
            maybe (error "Timeout") return m
  where
    rt' = Scheduler.__remoteTable rt
    stopHalon nodes = do
      self <- getSelfPid
      forM_ nodes $ \node -> liftIO $ forkProcess node $ do
        stopHalonNode
        usend self ((), ())
      forM_ nodes $ const (expect :: Process ((), ()))

-- | Creates mock event queue, this event queue only resends all events
-- to predefined process. This function should only be used when there is
-- no real RC running, because normal EQ will override this one, also Mock
-- EQ do not use persistent layer and doesn't support RC restarts.
startMockEventQueue :: ProcessId -> Process ProcessId
startMockEventQueue listener = do
  pid <- spawnLocal $ forever $
           receiveWait
             [ match $ \(sender, ev) ->
                 usend listener (sender::ProcessId, ev::PersistMessage)
             ]
  mp <- whereis eventQueueLabel
  case mp of
    Nothing -> register  eventQueueLabel pid
    Just{}  -> reregister eventQueueLabel pid
  return pid

tryRunProcessLocal :: Transport -> RemoteTable -> Process () -> IO ()
tryRunProcessLocal transport rt process =
  withTmpDirectory $
    withLocalNode transport rt $ \node -> do
      runProcess node process
