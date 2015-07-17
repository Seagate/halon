-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE CPP                 #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}

module HA.RecoverySupervisor.Tests ( tests ) where

import HA.Process
import HA.RecoverySupervisor
  ( recoverySupervisor
  , RSState(..)
  )
import HA.Replicator ( RGroup(..) )
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock ( MC_RG )
#else
import HA.Replicator.Log ( MC_RG )
#endif
import RemoteTables ( remoteTable )

import Control.Distributed.Process
  ( Process
  , spawnLocal
  , getSelfPid
  , liftIO
  , catch
  , receiveWait
  , ProcessId
#ifndef USE_MOCK_REPLICATOR
  , processNodeId
  , bracket_
#endif
  , getSelfNode
  , exit
  , unClosure
  , NodeId(..)
  )
import Control.Distributed.Process.Closure ( mkStatic, remotable )
import Control.Distributed.Process.Internal.Types
  ( ProcessExitException
  , localNodeId
  , LocalNode
  )
import Control.Distributed.Process.Node ( newLocalNode, runProcess, closeLocalNode )
import Control.Distributed.Process.Serializable ( SerializableDict(..) )
import Control.Distributed.Process.Timeout (retry)
#ifndef USE_MOCK_REPLICATOR
import Network.Transport.Controlled ( Controlled, silenceBetween )
#endif
import Control.Distributed.Process
  ( Static
  , Closure
#ifndef USE_MOCK_REPLICATOR
  , say
#endif
  )

import Control.Concurrent
  ( MVar
  , newEmptyMVar
  , putMVar
  , takeMVar
  , tryTakeMVar
  , threadDelay
  )
import Control.Exception ( SomeException )
import Control.Monad
  ( liftM3
  , void
  , replicateM_
  , replicateM
  , forM_
#ifndef USE_MOCK_REPLICATOR
  , liftM2
  , unless
#endif
  )
#ifndef USE_MOCK_REPLICATOR
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TChan
#endif
import Network.Transport
  (Transport
#ifndef USE_MOCK_REPLICATOR
  , EndPointAddress
#endif
  )
import Test.Framework
import Test.Transport

requestTimeout :: Int
requestTimeout = 1000000

pollingPeriod :: Int
pollingPeriod = 1000000

data TestCounters = TestCounters
    { cStart :: MVar ()        -- ^ RC has been started
    , cStop  :: MVar ()        -- ^ RC has been stopped
    , cRC    :: MVar ProcessId -- ^ RC pid
    }

newCounters :: IO TestCounters
newCounters = liftM3 TestCounters newEmptyMVar newEmptyMVar newEmptyMVar

type RG = MC_RG RSState

rsSDict :: SerializableDict RSState
rsSDict = SerializableDict

remotable [ 'rsSDict ]

spawnReplica' :: (RGroup g)
              => (g RSState)
              -> Static (SerializableDict RSState)
              -> NodeId
              -> Process (Closure (Process (g RSState)))
spawnReplica' _ = spawnReplica

-- | Start RS environment, starts dummy RS that will notify about
-- it's events using "Counters".
testRS' :: Bool         -- ^ Run test on single node.
        -> MVar ()      -- ^ MVar that is used to notify that startup procedure has finished.
        -> TestCounters -- ^ Counters that is used in RC, see "Counters"
        -> RG           -- ^ RG
        -> Process ()
testRS' oneNode mdone counters rGroup = do
  flip catch (\e -> liftIO $ print (e :: SomeException)) $ do
    rGroup' <- if oneNode
       then return rGroup
       else do
         n <- getSelfNode
         rg'      <- spawnReplica' rGroup $(mkStatic 'rsSDict) n
         unClosure rg' >>= id
    void $ spawnLocal $ recoverySupervisor rGroup' $ dummyRC counters
    liftIO $ putMVar mdone ()

  where

    dummyRC cnts = do
        self <- getSelfPid
        liftIO $ do
          putMVar (cRC cnts) self
          putMVar (cStart cnts) ()
        receiveWait []
      `catch` (\(_ :: ProcessExitException) -> liftIO $ putMVar (cStop cnts) ())

#ifndef USE_MOCK_REPLICATOR

data Event = Started ProcessId
           | Stopped ProcessId
           deriving (Eq, Show)

-- | Start RS environment, starts dummy RS that will notify about it's
-- events using "TChan" of events
testRS'' :: MVar ()      -- ^ MVar that is used to notify that startup procedure has finished.
         -> TChan Event  -- ^ Channel of events.
         -> RG           -- ^ Recovery group handle.
         -> Process ()
testRS'' mdone chan rGroup = do
    flip catch (\e -> liftIO $ print (e :: SomeException)) $ do
      n <- getSelfNode
      rg'      <- spawnReplica' rGroup $(mkStatic 'rsSDict) n
      rGroup'  <- unClosure rg' >>= id
      void $ spawnLocal $ recoverySupervisor rGroup' $ dummyRC chan
      liftIO $ putMVar mdone ()
    where
      dummyRC ch = do
        self <- getSelfPid
        say "starting dummy RC"
        bracket_ (liftIO $ atomically $ writeTChan ch (Started self))
                 (liftIO $ atomically $ writeTChan ch (Stopped self))
                 (receiveWait [])
#endif

tests :: Bool -> AbstractTransport -> IO [TestTree]
tests oneNode abstractTransport = do
#ifndef USE_MOCK_REPLICATOR
  (transport, controlled) <- mkControlledTransport abstractTransport
#else
  let transport = getTransport abstractTransport
#endif
  putStrLn $ "Testing RecoverySupervisor " ++
              if oneNode then "with one node..."
               else "with multiple nodes..."
  return
    [ testSuccess "rs-restart-if-process-dies" $ rsTest transport oneNode $ \_ counters rGroup -> do
        _leader0 <- do
            liftIO $ do
              takeMVar $ cStart counters
              Nothing <- tryTakeMVar $ cStop counters
              return ()
            RSState (Just leader0) _ _ <- retry requestTimeout $ getState rGroup
            return leader0

        rc <- liftIO $ takeMVar $ cRC counters
        exit rc "killed for testing"

        liftIO $ do
          takeMVar $ cStart counters
          takeMVar $ cStop counters
        RSState (Just _) _ _<- retry requestTimeout $ getState rGroup
        return ()
#ifndef USE_MOCK_REPLICATOR
    , testSuccess "rs-restart-if-node-dies" $ rsTest transport oneNode $ \ns counters rGroup -> do
        leader0 <- do
            liftIO $ do
              takeMVar $ cStart counters
              Nothing <- tryTakeMVar $ cStop counters
              return ()
            RSState (Just leader0) _ _ <- retry requestTimeout $ getState rGroup
            return leader0

        rc <- liftIO $ takeMVar $ cRC counters

        let leaderNode = head $ filter ((processNodeId rc ==) . localNodeId) ns
        _ <- liftIO $ terminateLocalProcesses leaderNode Nothing

        -- Check that previous RC stops
        liftIO $ takeMVar $ cStop counters
        -- Check that new RC spawns
        liftIO $ takeMVar $ cStart counters -- XXX: Timeout ?

        -- Read new leader pid
        RSState (Just leader1) _ _<- retry requestTimeout $ getState rGroup
        -- Verify that we have new leader
        False <- return $ leader0 == leader1
        return ()
    , testSuccess "rs-restart-if-node-silent" $ rsTest transport oneNode $ \ns counters rGroup -> do
        leader0 <- do
            liftIO $ do
              takeMVar $ cStart counters
              Nothing <- tryTakeMVar $ cStop counters
              return ()
            RSState (Just leader0) _ _ <- retry requestTimeout $ getState rGroup
            return leader0

        -- Prepare new handle because silent node will not have quorum to reply
        rg'      <- spawnReplica' rGroup $(mkStatic 'rsSDict) (localNodeId $ ns !! 1)
        rGroup'  <- unClosure rg' >>= id
        rc <- liftIO $ takeMVar $ cRC counters

        -- Isolate leader node
        selfNode <- getSelfNode
        liftIO $ forM_ ns $ \n ->
          unless (nodeAddress (processNodeId leader0) == nodeAddress (localNodeId n)) $ do
            silenceBetween controlled (nodeAddress (processNodeId rc))
                                      (nodeAddress (localNodeId n))
            silenceBetween controlled (nodeAddress (processNodeId rc))
                                      (nodeAddress selfNode)

        -- Check that RC was killed
        liftIO $ takeMVar $ cStop counters
        -- Check that new RC was spawned
        liftIO $ takeMVar $ cStart counters

        -- Get leader using node that have quorum
        RSState (Just leader1) _ _<- retry requestTimeout $ getState rGroup'
        -- Verify that leader is new
        False <- return $ leader0 == leader1
        return ()
    , testSuccess "rs-rc-killed-if-quorum-is-lost" $ rsTest transport oneNode $ \ns counters rGroup -> do
        _ <- do
            liftIO $ do
              takeMVar $ cStart counters
              Nothing <- tryTakeMVar $ cStop counters
              return ()
            RSState (Just leader0) _ _ <- retry requestTimeout $ getState rGroup
            return leader0

        rc <- liftIO $ takeMVar $ cRC counters

        forM_ (filter ((processNodeId rc /=) . localNodeId) ns) $ \n ->
          liftIO $ terminateLocalProcesses n Nothing

        liftIO $ takeMVar $ cStop counters

        return ()
    , testSuccess "rs-split-in-majority" $ testSplit transport controlled 5 $ \pid nodes events splitNet rGroup -> do
        liftIO $ do
          let (as,bs) = splitAt 2 $ filter ((processNodeId pid /=) . localNodeId) nodes
          splitNet (nodeAddress (processNodeId pid)
                   :map (nodeAddress.localNodeId) as)
                   (map (nodeAddress.localNodeId) bs)
          threadDelay (3*pollingPeriod)
          Nothing <- atomically $ tryReadTChan events
          return ()
        RSState (Just _) _ _<- retry requestTimeout $ getState rGroup
        return ()
    , testSuccess "rs-split-in-minority" $ testSplit transport controlled 5 $ \pid nodes events splitNet rGroup -> do
        selfNode <- getSelfNode
        liftIO $ do
          let (as,bs) = splitAt 3 $ filter ((processNodeId pid /=) . localNodeId) nodes
          splitNet (nodeAddress selfNode:map (nodeAddress.localNodeId) as)
                   (nodeAddress (processNodeId pid)
                   :map (nodeAddress . localNodeId) bs)

        liftIO $ do
          -- wait that RS eventually stop
          _ <- waitMsgIO events $ \e ->
            case e of
              Stopped p -> p == pid
              _ -> False
          -- wait that new RS eventually starts
          _ <- waitMsgIO events $ \e ->
            case e of
              Started _ -> True
              _ -> False
          -- wait for two more pollingPeriods as smth interestring
          -- may happen
          threadDelay (2*pollingPeriod)
          -- check that there were no interesting events
          Nothing <- atomically $ tryReadTChan events
          return ()
        RSState (Just _) _ _<- retry requestTimeout $ getState rGroup
        return ()
    , testSuccess "rs-split-in-half"  $ testSplit transport controlled 5 $ \pid nodes events splitNet _ -> liftIO $ do
        let [a1,a2,a3,a4,a5] = map (nodeAddress . localNodeId) nodes
        splitNet [a1,a2] [a3,a4,a5]
        splitNet [a3,a4] [a5]
        -- wait that RS eventually stop
        _ <- waitMsgIO events $ \e ->
          case e of
            Stopped p -> p == pid
            _ -> False
        threadDelay (3*pollingPeriod)
        Nothing <- atomically $ tryReadTChan events
        return ()
#endif
    ]

#ifndef USE_MOCK_REPLICATOR
waitMsgIO :: TChan a -> (a -> Bool) -> IO a
waitMsgIO ch p = atomically $ waitMsg []
  where
    waitMsg x = do
      y <- readTChan ch
      if p y
         then forM_ x (unGetTChan ch) >> return y
         else waitMsg (y:x)


testSplit :: Transport
          -> Controlled
          -- ^ Transport and controller object.
          -> Int
          -- ^ Number of nodes to create.
          -> (ProcessId
               -- ^ Pd of the leader.
               -> [LocalNode]
               -- ^ List of replica nodes.
               -> TChan Event
               -- ^ Channel with RS events.
               -> ([EndPointAddress] -> [EndPointAddress] -> IO ())
               -- ^ Callback that splits network between nodes in groups.
               -> MC_RG RSState
               -- ^ Group handle.
               -> Process ())
          -> IO ()
testSplit transport t amountOfReplicas action = withTmpDirectory $ do
    controlNode <- newLocalNode transport $ __remoteTable remoteTable

    ns <- replicateM amountOfReplicas $ newLocalNode transport
                                      $ __remoteTable remoteTable
    events    <- newTChanIO
    mTestDone <- newEmptyMVar
    tryRunProcess controlNode $ do
      let nids = map localNodeId ns

      cRGroup <- newRGroup $(mkStatic 'rsSDict) 20 pollingPeriod nids
                           (RSState Nothing 0 pollingPeriod)

      rGroup <- unClosure cRGroup >>= id
      mdone <- liftIO $ newEmptyMVar

      liftIO $ forM_ ns $ \n -> runProcess n $ do
        _ <- spawnLocal $ testRS'' mdone events rGroup
        return ()

      let doSplit a b = forM_ (liftM2 (,) a b) $ uncurry (silenceBetween t)
      replicateM_ amountOfReplicas $ liftIO $ takeMVar mdone

      pid0 <- do
          pid <- liftIO $ do
            Started pid <- atomically $ readTChan events
            Nothing <- atomically $ tryReadTChan events
            return pid
          RSState (Just _) _ _ <- retry requestTimeout $ getState rGroup
          return pid
      action pid0 ns events doSplit rGroup
      liftIO $ putMVar mTestDone ()

    takeMVar mTestDone
    -- Exit after transport stops being used.
    -- TODO: implement closing RGroups and call it here.
    threadDelay (2*pollingPeriod)
    mapM_ closeLocalNode (controlNode:ns)
    -- mapM_ (flip terminateLocalProcesses Nothing) ns
#endif

rsTest :: Transport -> Bool -> ([LocalNode] -> TestCounters -> MC_RG RSState -> Process ()) -> IO ()
rsTest transport oneNode action = withTmpDirectory $ do
  let amountOfReplicas = 4
  ns@(n1:_) <-
    replicateM amountOfReplicas
        $ newLocalNode transport
        $ __remoteTable remoteTable
  controlNode <- newLocalNode transport $ __remoteTable remoteTable
  mTestDone <- newEmptyMVar
  tryRunProcess controlNode $ do
      let nids = map localNodeId $ if oneNode
                   then replicate amountOfReplicas n1
                   else ns
      cRGroup <- newRGroup $(mkStatic 'rsSDict) 20 pollingPeriod nids
                           (RSState Nothing 0 pollingPeriod)

      rGroup   <- unClosure cRGroup >>= id
      counters <- liftIO newCounters
      mdone    <- liftIO newEmptyMVar

      liftIO $ forM_ ns $ \n -> runProcess n $ do
        _ <- spawnLocal $ testRS' oneNode mdone counters rGroup
        return ()
      replicateM_ amountOfReplicas $ liftIO $ takeMVar mdone
      action ns counters rGroup
      liftIO $ putMVar mTestDone ()

  takeMVar mTestDone
  -- Exit after transport stops being used.
  -- TODO: fix closeTransport and call it here (see ticket #211).
  -- TODO: implement closing RGroups and call it here.
  threadDelay (2*pollingPeriod)
  -- TODO: Uncomment the following line when terminateLocalProcesses
  -- does not block indefinitely.
  -- mapM_ (flip terminateLocalProcesses (Just pollingPeriod)) ns
  mapM_ closeLocalNode (controlNode:ns)
  -- mapM_ (flip terminateLocalProcesses Nothing) (controlNode:ns)
