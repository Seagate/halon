-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
module TestRunner
  ( TestArgs(..)
  , TestReplicatedState
  , runRCEx
  , runTest
  , withLocalNode
  , withLocalNodes
  , withTrackingStation
  , eqView
  , eqView__static
  , multimapView
  , multimapView__static
  , testDict
  , testDict__static
  , emptyRules
  , emptyRules__static
  , startMockEventQueue
  , __remoteTableDecl
  ) where

import qualified HA.EQTracker as EQT
import HA.EventQueue
import HA.EventQueue.Types (PersistMessage)
import HA.Multimap.Implementation
import HA.Multimap.Process
import HA.RecoveryCoordinator.Definitions
import HA.RecoveryCoordinator.Mero
import HA.Replicator
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock ( MC_RG )
#else
import HA.Replicator.Log ( MC_RG )
#endif
import HA.Startup (stopHalonNode)

import Control.Arrow (first, second)
import Control.Exception as E
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import qualified Control.Distributed.Process as DP
import Control.Distributed.Process.Node
import qualified Control.Distributed.Process.Scheduler as Scheduler
import Control.Monad (join, void, forever)

import Data.Foldable

import Network.CEP hiding (timeout)
import Network.Transport (Transport(..))
import Network.Transport.InMemory (createTransport)

import System.Environment (lookupEnv)
import System.Random (randomIO)
import System.IO (stderr, hPutStrLn)
import System.Timeout (timeout)

import Test.Framework

type TestReplicatedState = (EventQueue, Multimap)

remotableDecl [ [d|
  eqView :: RStateView TestReplicatedState EventQueue
  eqView = RStateView fst first

  multimapView :: RStateView TestReplicatedState Multimap
  multimapView = RStateView snd second

  testDict :: SerializableDict TestReplicatedState
  testDict = SerializableDict

  emptyRules :: [Definitions LoopState ()]
  emptyRules = []

  |]]

data TestArgs = TestArgs {
    ta_eq :: ProcessId
  , ta_mm :: ProcessId
  , ta_rc :: ProcessId
} deriving (Eq, Show)

runRCEx :: (ProcessId, IgnitionArguments)
        -> [Definitions LoopState ()]
        -> MC_RG TestReplicatedState
        -> Process ((ProcessId, ProcessId)) -- ^ MM, RC
runRCEx (eq, args) rules rGroup = do
  rec (mm, rc) <- (,)
                  <$> (spawnLocal $ do
                        () <- expect
                        link rc
                        multimap (viewRState $(mkStatic 'multimapView) rGroup))
                  <*> (spawnLocal $ do
                        () <- expect
                        recoveryCoordinatorEx () rules args eq mm)
  usend eq rc
  forM_ [mm, rc] $ \them -> usend them ()
  return (mm, rc)

-- | Wrapper to start a test with a Halon tracking station running. Returns
--   handles to the recovery co-ordinator, multimap and event queue.
withTrackingStation :: [Definitions LoopState ()]
                    -> (TestArgs -> Process ())  -- ^ Test contents.
                    -> Process ()
withTrackingStation testRules action = do
  nid <- getSelfNode
  DP.bracket
    (do
      void $ EQT.startEQTracker [nid]
      cRGroup <- newRGroup $(mkStatic 'testDict) 1000 1000000
                         [nid] ((Nothing,[]), fromList [])
      join $ unClosure cRGroup
    )
    (flip killReplica nid)
    (\rGroup -> do
      eq <- startEventQueue (viewRState $(mkStatic 'eqView) rGroup)
      (mm, rc) <- runRCEx (eq, IgnitionArguments [nid]) testRules rGroup
      action $ TestArgs eq mm rc
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
