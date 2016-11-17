-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
module HA.Test.Disconnect
  ( testDisconnect
  , testRejoin
  , testRejoinTimeout
  , testRejoinRCDeath
  ) where

import Control.Distributed.Process hiding (bracket_)
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import qualified Control.Distributed.Process.Scheduler as Scheduler
import Control.Monad
import Control.Monad.Catch
import Data.List
import Data.Binary
import Data.Hashable (Hashable)

import Network.Transport (Transport, EndPointAddress)

import HA.Encode
import HA.Multimap
import HA.RecoveryCoordinator.Definitions
import HA.RecoveryCoordinator.Events.Cluster
import HA.RecoveryCoordinator.Events.Service
import HA.RecoveryCoordinator.Helpers
import HA.RecoveryCoordinator.Mero
import HA.RecoveryCoordinator.CEP
import HA.RecoveryCoordinator.RC (subscribeOnTo)
import HA.Resources.HalonVars
import HA.EventQueue.Producer
import HA.EventQueue.Types (HAEvent(..))
import HA.Resources
import qualified HA.Services.Ping as Ping
import HA.Network.RemoteTables (haRemoteTable)
import Mero.RemoteTables (meroRemoteTable)
import Network.CEP (Definitions, defineSimple, liftProcess, subscribe, Published(..))
import qualified Network.Transport.Controlled as Controlled

import HA.NodeUp ( nodeUp )
import HA.Startup
import Test.Framework

import Data.Typeable
import GHC.Generics

import TestRunner

#ifdef USE_MERO
import Helper.InitialData (defaultInitialData)
#endif

-- | message used to tell the RC to die, used in 'testRejoinRCDeath'
data KillRC = KillRC
  deriving (Eq, Show, Typeable, Generic)

instance Binary KillRC
instance Hashable KillRC

remotableDecl [ [d|
  rcWithDeath :: [NodeId] -> ProcessId -> StoreChan -> Process ()
  rcWithDeath = recoveryCoordinatorEx () rcDeathRules
    where
      rcDeathRules :: [Definitions RC ()]
      rcDeathRules = return $ defineSimple "rc-with-death" $ \(HAEvent uuid KillRC _) -> do
        liftProcess $ say "RC death requested from Disconnect.hs:rcDeathRules"
        messageProcessed uuid
        error "RC death requested from Disconnect.hs:rcDeathRules"
  |]]

myRemoteTable :: RemoteTable
myRemoteTable = HA.Test.Disconnect.__remoteTableDecl . haRemoteTable $ meroRemoteTable initRemoteTable

rcClosure :: Closure ([NodeId] -> ProcessId -> StoreChan -> Process ())
rcClosure = $(mkStaticClosure 'recoveryCoordinator)

data Dummy = Dummy String deriving (Typeable,Generic)

instance Binary Dummy

-- | Wrap the given action in startup and stop of halon nodes.
withHalonNodes :: ProcessId -> [LocalNode] -> Process a -> Process a
withHalonNodes self ms act = bracket_ startNodes stopNodes act
  where
    startNodes = do
      liftIO $ forM_ ms $ \m -> forkProcess m $ do
        startupHalonNode rcClosure
        usend self ((), ())
      forM_ ms $ \_ -> do
        ((), ()) <- expect
        return ()

    stopNodes = do
      liftIO $ forM_ ms $ \m -> forkProcess m $ do
        stopHalonNode
        usend self ((), ())
      forM_ ms $ \_ -> do
        ((), ()) <- expect
        return ()

-- | Make the tuple of arguments required by 'ignition' with some default values.
mkIgnitionArgs :: [LocalNode]
               -> (IgnitionArguments -> Closure (ProcessId -> StoreChan -> Process ()))
               -> (Bool, [NodeId], Int, Int, Closure (ProcessId -> StoreChan -> Process ()), Int)
mkIgnitionArgs ns rc =
  ( False, map localNodeId ns , 1000, 1000000
  , rc $ IgnitionArguments (map localNodeId ns), 8*1000000 )

disconnectHalonVars :: HalonVars
disconnectHalonVars = defaultHalonVars { _hv_recovery_expiry_seconds = 5
                                       , _hv_recovery_max_retries = 3 }

-- | Tests that tracking station failures allow the cluster to proceed.
--
-- * Start a satellite and three tracking station nodes.
-- * Start the noisy service in the satellite.
-- * Isolate a tracking station node so it cannot communicate with any other node.
-- * Wait for the RC to report events produced by the service.
-- * Re-enable communications of the TS node.
-- * Isolate another TS node.
-- * Wait for the RC to report events produced by the service.
-- * Re-enable communications of the TS node.
-- * Isolate another TS node.
-- * Wait for the RC to report events produced by the service.
testDisconnect :: Transport
               -> (EndPointAddress -> EndPointAddress -> IO ())
               -> IO ()
testDisconnect baseTransport connectionBreak = withTmpDirectory $ do
  (transport, controlled) <- Controlled.createTransport baseTransport
                                                        connectionBreak
  testSplit transport controlled 4 2 $ \[m0,m1,m2,m3]
                                         splitNet restoreNet -> do
    let args = mkIgnitionArgs [m0, m1, m2] $(mkClosure 'recoveryCoordinator)
    self <- getSelfPid

    liftIO $ forM_ [m0, m1, m2] $ \m -> forkProcess m $ do
      registerInterceptor $ \string -> do
        let t = "Recovery Coordinator: received DummyEvent "
        case string of
          str' | t `isInfixOf` str' -> usend self $ Dummy (drop (length t) str')
          _ -> return ()
      usend self ((), ())
    forM_ [m0, m1, m2] $ \_ -> do
      ((), ()) <- expect
      return ()

    withHalonNodes self [m0, m1, m2, m3] $ do
      let nids = map localNodeId [m0, m1, m2]
      -- ignition on 3 nodes
      void $ liftIO $ forkProcess m1 $ do
        Nothing <- ignition args
        usend self ((), ())
      ((), ()) <- expect

      _ <- promulgateEQ (localNodeId <$> [m0, m1, m2]) $ RequestRCPid self
      RequestRCPidAnswer rc <- expect :: Process RequestRCPidAnswer

      subscribe rc (Proxy :: Proxy HalonVarsUpdated)
      subscribe rc (Proxy :: Proxy (HAEvent ServiceStarted))

      _ <- promulgateEQ [localNodeId m1] $ SetHalonVars disconnectHalonVars
      _dhv <- expect :: Process (Published HalonVarsUpdated)

      say "running NodeUp"
      void $ liftIO $ forkProcess m3 $ do
        -- wait until the EQ tracker is registered
        nodeUp (map localNodeId [m0, m1, m2], 1000000)
        void . promulgateEQ nids $
          encodeP $ ServiceStartRequest Start (Node $ localNodeId m3) Ping.ping
                                        Ping.PingConf []

      pingPid <- serviceStarted Ping.ping
      runPing pingPid 0

      forM_ (zip [1 :: Int,3..] nids) $ \(i,m) -> do
        say $ "isolating TS node " ++ (show m)
        splitNet [[m], filter (m /=) nids]
        runPing pingPid i

        say $ "rejoining TS node " ++ (show m)
        restoreNet nids
        runPing pingPid (i + 1)

      say "testDisconnect complete"
  where
    runPing :: ProcessId -> Int -> Process ()
    runPing pingPid i = do
      usend pingPid (show i)
      receiveWait [ matchIf (\(Dummy str) -> show i == str)
                            (const $ return ()) ]

-- | Tests that:
--  * nodes are timed out when disconnected for long enough
--  * nodes can rejoin after they were timed out
--
-- Spawn TS with one node. Bring up a satellite. Disconnect it. Wait
-- until RC enters timeout routine. Check that we can rejoin the node.
testRejoinTimeout :: Transport
                  -> (EndPointAddress -> EndPointAddress -> IO ())
                  -> IO ()
testRejoinTimeout baseTransport connectionBreak = withTmpDirectory $ do
  (transport, controlled) <- Controlled.createTransport baseTransport
                                                        connectionBreak
  testSplit transport controlled 2 5 $ \[m0,m1]
                                        splitNet restoreNet -> do
    let args = mkIgnitionArgs [m1] $(mkClosure 'recoveryCoordinator)
    self <- getSelfPid

    withHalonNodes self [m0, m1] $ do
      void $ liftIO $ forkProcess m1 $ do
        Nothing <- ignition args
        usend self ((), ())
      ((), ()) <- expect

      _ <- promulgateEQ [localNodeId m1] $ RequestRCPid self
      RequestRCPidAnswer rc <- expect :: Process RequestRCPidAnswer
      subscribe rc (Proxy :: Proxy NodeTransient)
      subscribe rc (Proxy :: Proxy RecoveryAttempt)
      subscribe rc (Proxy :: Proxy OldNodeRevival)
      subscribe rc (Proxy :: Proxy NewNodeMsg)
      subscribe rc (Proxy :: Proxy HostDisconnected)
      subscribe rc (Proxy :: Proxy InitialDataLoaded)
      subscribe rc (Proxy :: Proxy HalonVarsUpdated)

      _ <- promulgateEQ [localNodeId m1] $ SetHalonVars disconnectHalonVars
      _ <- expectPublished (Proxy :: Proxy HalonVarsUpdated)

      say "running NodeUp"
      void $ liftIO $ forkProcess m0 $ do
        -- wait until the EQ tracker is registered
        nodeUp ([localNodeId m1], 1000000)
      _ <- expectPublished (Proxy :: Proxy NewNodeMsg)

#ifdef USE_MERO
      _ <- promulgateEQ [localNodeId m1] defaultInitialData
      _ <- expectPublished (Proxy :: Proxy InitialDataLoaded)
#endif

      say $ "isolating TS node " ++ show (localNodeId <$> [m1])
      splitNet [[localNodeId m0], [localNodeId m1]]
      -- ack node down
      _ <- expectPublished (Proxy :: Proxy NodeTransient)
      -- wait until timeout happens
      _ <- expectPublished (Proxy :: Proxy HostDisconnected)
      -- then bring it back up
      restoreNet (map localNodeId [m0, m1])
      -- and make bring it back up
      _ <- emptyMailbox (Proxy :: Proxy (Published NewNodeMsg))
      void $ liftIO $ forkProcess m0 $ nodeUp ([localNodeId m1], 1000000)
      _ <- expectPublished (Proxy :: Proxy NewNodeMsg)

      say "testRejoinTimeout complete"

-- | Tests that:
--  * nodes in which we began recovery, continue recover after RC failure
--
-- Spawn TS with one node. Bring up a satellite. Disconnect it. Kill
-- the RC. Wait until we see recovery process continue and reconnect
-- satellite.
testRejoinRCDeath :: Transport
                  -> (EndPointAddress -> EndPointAddress -> IO ())
                  -> IO ()
testRejoinRCDeath baseTransport connectionBreak = withTmpDirectory $ do
  (transport, controlled) <- Controlled.createTransport baseTransport
                                                        connectionBreak
  testSplit transport controlled 2 3 $ \[m0,m1]
                                        splitNet restoreNet -> do
    let args = mkIgnitionArgs [m1] $(mkClosure 'rcWithDeath)
    self <- getSelfPid

    withHalonNodes self [m0, m1] $ do
      void $ liftIO $ forkProcess m1 $ do
        Nothing <- ignition args
        usend self ((), ())
      ((), ()) <- expect

      subscribeOnTo [localNodeId m1] (Proxy :: Proxy NodeTransient)
      subscribeOnTo [localNodeId m1] (Proxy :: Proxy RecoveryAttempt)
      subscribeOnTo [localNodeId m1] (Proxy :: Proxy OldNodeRevival)
      subscribeOnTo [localNodeId m1] (Proxy :: Proxy NewNodeMsg)
      subscribeOnTo [localNodeId m1] (Proxy :: Proxy HostDisconnected)
      subscribeOnTo [localNodeId m1] (Proxy :: Proxy NewNodeConnected)
      subscribeOnTo [localNodeId m1] (Proxy :: Proxy InitialDataLoaded)
      subscribeOnTo [localNodeId m1] (Proxy :: Proxy HalonVarsUpdated)

      _ <- promulgateEQ [localNodeId m1] $ SetHalonVars disconnectHalonVars
      _ <- expectPublished (Proxy :: Proxy HalonVarsUpdated)

      say "running NodeUp"
      emptyMailbox (Proxy :: Proxy (Published NewNodeConnected))
      void $ liftIO $ forkProcess m0 $ do
        -- wait until the EQ tracker is registered
        nodeUp ([localNodeId m1], 1000000)
      _ <- expectPublished (Proxy :: Proxy NewNodeConnected)

#ifdef USE_MERO
      _ <- promulgateEQ [localNodeId m1] defaultInitialData
      _ <- expectPublished (Proxy :: Proxy InitialDataLoaded)
#endif

      say $ "isolating TS node " ++ show (localNodeId <$> [m1])
      splitNet [[localNodeId m0], [localNodeId m1]]
      -- ack node down
      _ <- expectPublished (Proxy :: Proxy NodeTransient)
      -- Wait until recovery starts
      _ <- expectPublished (Proxy :: Proxy RecoveryAttempt)
      _ <- promulgateEQ [localNodeId m1] KillRC
      -- RC restarts but the node is still down
      -- _ <- expectPublished (Proxy :: Proxy NodeTransient)
      -- recovery restarts
      -- _ <- expectPublished (Proxy :: Proxy RecoveryAttempt)
      -- then bring it back up
      restoreNet (map localNodeId [m0, m1])
      -- and make sure it did come back up
      -- recovery restarts
      _ <- expectPublished (Proxy :: Proxy OldNodeRevival)
      say "testRejoinRCDeath complete"

-- | Tests that:
-- * The RC detects when a node disconnects.
-- * Nodes can rejoin before we time them out and mark as down.
--
-- Spawn TS with one node. Bring up a satellite. Disconnect it. Wait until RC
-- detects the node is disconnected. Reconnect the node. Check that RC marks the
-- node as online again.
testRejoin :: Transport
           -> (EndPointAddress -> EndPointAddress -> IO ())
           -> IO ()
testRejoin baseTransport connectionBreak = withTmpDirectory $ do
  (transport, controlled) <- Controlled.createTransport baseTransport
                                                        connectionBreak
  testSplit transport controlled 2 3 $ \[m0,m1]
                                        splitNet restoreNet -> do
    let args = mkIgnitionArgs [m1] $(mkClosure 'recoveryCoordinator)
    self <- getSelfPid

    withHalonNodes self [m0, m1] $ do
      void $ liftIO $ forkProcess m1 $ do
        Nothing <- ignition args
        usend self ((), ())
      ((), ()) <- expect

      _ <- promulgateEQ [localNodeId m1] $ RequestRCPid self
      RequestRCPidAnswer rc <- expect :: Process RequestRCPidAnswer
      subscribe rc (Proxy :: Proxy NodeTransient)
      subscribe rc (Proxy :: Proxy RecoveryAttempt)
      subscribe rc (Proxy :: Proxy OldNodeRevival)
      subscribe rc (Proxy :: Proxy NewNodeConnected)
      subscribe rc (Proxy :: Proxy InitialDataLoaded)
      subscribe rc (Proxy :: Proxy HalonVarsUpdated)

      _ <- promulgateEQ [localNodeId m1] $ SetHalonVars disconnectHalonVars
      _ <- expectPublished (Proxy :: Proxy HalonVarsUpdated)

      say "running NodeUp"
      void $ liftIO $ forkProcess m0 $ do
        -- wait until the EQ tracker is registered
        nodeUp ([localNodeId m1], 1000000)

      _ <- expectPublished (Proxy :: Proxy NewNodeConnected)
#ifdef USE_MERO
      _ <- promulgateEQ [localNodeId m1] defaultInitialData
      _ <- expectPublished (Proxy :: Proxy InitialDataLoaded)
#endif

      say $ "isolating TS node " ++ show (localNodeId <$> [m1])
      splitNet [[localNodeId m0], [localNodeId m1]]
      -- ack node down
      _ <- expectPublished (Proxy :: Proxy NodeTransient)
      -- Wait until recovery starts
      _ <- expectPublished (Proxy :: Proxy RecoveryAttempt)
      -- Bring one node back up straight away…
      restoreNet (map localNodeId [m0, m1])
      -- …which gives us a revival of it, swallow recovery messages
      -- until the node comes back up
      _ <- expectPublished (Proxy :: Proxy OldNodeRevival)

      say "testRejoin complete"

testSplit :: Transport
          -> Controlled.Controlled
          -- ^ Transport and controller object.
          -> Int
          -- ^ Number of nodes to create.
          -> Int
          -- ^ Number of times to run (for scheduler only)
          -> (  [LocalNode]
                -- ^ List of replica nodes.
             -> ([[NodeId]] -> Process ())
                -- ^ Callback that splits network between nodes in groups.
             -> ([NodeId] -> Process ())
                -- ^ Restores communication among the nodes.
             -> Process ()
             )
          -> IO ()
testSplit transport t amountOfReplicas runs action =
    runTest (amountOfReplicas + 1) runs 1000000 transport myRemoteTable $ \ns -> do
      let doSplit nds =
            (if Scheduler.schedulerIsEnabled
               then Scheduler.addFailures . concat .
                    map (\(a, b) -> [((a, b), 1.0), ((b, a), 1.0)])
               else liftIO . sequence_ .
                    map (\(a, b) -> Controlled.silenceBetween t (nodeAddress a)
                                                                (nodeAddress b)
                        )
            )
            [ (a, b) | a <- concat nds, x <- nds, notElem a x, b <- x ]
          restore nds =
            (if Scheduler.schedulerIsEnabled
               then Scheduler.removeFailures
               else liftIO . sequence_ .
                    map (\(a, b) -> Controlled.unsilence t (nodeAddress a)
                                                           (nodeAddress b)
                        )
            )
            [ (a, b) | a <- nds, b <- nds ]
       in action ns doSplit restore
