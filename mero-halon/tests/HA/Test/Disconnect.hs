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

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import qualified Control.Distributed.Process.Scheduler as Scheduler
import Control.Distributed.Static ( closureCompose )
import Control.Monad
import Data.List
import Data.Binary
import Data.Hashable (Hashable)

import Network.Transport (Transport, EndPointAddress)

import HA.RecoveryCoordinator.Definitions
import HA.RecoveryCoordinator.Mero
import HA.EventQueue.Producer
import HA.EventQueue.Types (HAEvent(..))
import HA.Resources
import HA.Service hiding (__remoteTable)
import qualified HA.Services.Ping as Ping
import HA.Network.RemoteTables (haRemoteTable)
import Mero.RemoteTables (meroRemoteTable)
import Network.CEP (Definitions, defineSimple, liftProcess)
import qualified Network.Transport.Controlled as Controlled

import HA.NodeUp ( nodeUp )
import HA.Startup
import Test.Framework

import Data.Typeable
import GHC.Generics

import TestRunner

#ifdef USE_MERO
import HA.Castor.Tests (initialDataAddr)
#endif

-- | message used to tell the RC to die, used in 'testRejoinRCDeath'
data KillRC = KillRC
  deriving (Eq, Show, Typeable, Generic)

instance Binary KillRC
instance Hashable KillRC

remotableDecl [ [d|
  rcWithDeath :: IgnitionArguments -> ProcessId -> ProcessId -> Process ()
  rcWithDeath = recoveryCoordinatorEx () rcDeathRules
    where
      rcDeathRules :: [Definitions LoopState ()]
      rcDeathRules = return $ defineSimple "rc-with-death" $ \(HAEvent uuid KillRC _) -> do
        startProcessingMsg uuid
        liftProcess $ say "RC death requested from Disconnect.hs:rcDeathRules"
        finishProcessingMsg uuid
        messageProcessed uuid
        error "RC death requested from Disconnect.hs:rcDeathRules"
  |]]

myRemoteTable :: RemoteTable
myRemoteTable = HA.Test.Disconnect.__remoteTableDecl . haRemoteTable $ meroRemoteTable initRemoteTable

rcClosure :: Closure ([NodeId] -> ProcessId -> ProcessId -> Process ())
rcClosure = $(mkStaticClosure 'recoveryCoordinator) `closureCompose`
               $(mkStaticClosure 'ignitionArguments)

data Dummy = Dummy String deriving (Typeable,Generic)

instance Binary Dummy

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
  testSplit transport controlled 4 10 $ \[m0,m1,m2,m3]
                                         splitNet restoreNet -> do
    let args = ( False :: Bool
               , map localNodeId [m0,m1,m2]
               , 1000 :: Int
               , 1000000 :: Int
               , $(mkClosure 'recoveryCoordinator) $
                   IgnitionArguments (map localNodeId [m0,m1,m2])
               , 8*1000000 :: Int
               )
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
    bracket_ (do liftIO $ forM_ [m0, m1, m2, m3] $ \m -> forkProcess m $ do
                   startupHalonNode rcClosure
                   usend self ((), ())
                 forM_ [m0, m1, m2, m3] $ \_ -> do
                   ((), ()) <- expect
                   return ()
             )
             (do liftIO $ forM_ [m0, m1, m2, m3] $ \m -> forkProcess m $ do
                   stopHalonNode
                   usend self ((), ())
                 forM_ [m0, m1, m2, m3] $ \_ -> do
                   ((), ()) <- expect
                   return ()
             ) $ do
      let nids = map localNodeId [m0, m1, m2]
      -- ignition on 3 nodes
      void $ liftIO $ forkProcess m1 $ do
        Nothing <- ignition args
        usend self ((), ())
      ((), ()) <- expect

      say "running NodeUp"
      void $ liftIO $ forkProcess m3 $ do
        -- wait until the EQ tracker is registered
        nodeUp (map localNodeId [m0, m1, m2], 1000000)
        registerInterceptor $ \string -> do
          case string of
            str' | "Starting service ping" `isInfixOf` str' -> usend self ()
            _ -> return ()
        pid <- promulgateEQ nids $
          encodeP $ ServiceStartRequest Start (Node $ localNodeId m3) Ping.ping
                                        Ping.PingConf []
        ref <- monitor pid
        receiveWait
          [ matchIf (\(ProcessMonitorNotification ref' _ _) -> ref == ref')
                    (const $ return ())
          ]
      -- "Starting service ping"
      () <- expect

      whereisRemoteAsync (localNodeId m3)
        $ serviceLabel $ serviceName Ping.ping
      WhereIsReply _ (Just pingPid) <- expect

      usend pingPid "0"
      Dummy "0" <- expect

      forM_ (zip [1 :: Int,3..] nids) $ \(i,m) -> do
        say $ "isolating TS node " ++ (show m)
        splitNet [[m], filter (m /=) nids]

        usend pingPid (show i)
        receiveWait [ matchIf (\(Dummy z) -> show i == z) (const $ return ()) ]

        say $ "rejoining TS node " ++ (show m)
        restoreNet nids
        usend pingPid (show (i+1))
        receiveWait
          [ matchIf (\(Dummy z) -> show (i + 1) == z) (const $ return ()) ]

      say "Test complete"

-- | Tests that:
--  * nodes are timed out when disconnected for long enough
--  * nodes can rejoin after they were timed out
--
-- Spawn TS with one node. Bring up a satellite. Disconnect it. Wait
-- until RC enters timeout routine. Check that we can rejoin the node.
testRejoinTimeout :: String -- ^ Host used for initial data
                  -> Transport
                  -> (EndPointAddress -> EndPointAddress -> IO ())
                  -> IO ()
testRejoinTimeout _host baseTransport connectionBreak = withTmpDirectory $ do
  (transport, controlled) <- Controlled.createTransport baseTransport
                                                        connectionBreak
  testSplit transport controlled 2 5 $ \[m0,m1]
                                        splitNet restoreNet -> do
    let args = ( False :: Bool
               , map localNodeId [m1]
               , 1000 :: Int
               , 1000000 :: Int
               , $(mkClosure 'recoveryCoordinator) $
                   IgnitionArguments [localNodeId m1]
               , 8*1000000 :: Int
               )
    self <- getSelfPid
    void . liftIO . forkProcess m1 $ do
      registerInterceptor $ \string -> do
        let t = "Recovery Coordinator: received DummyEvent "
        case string of
          str' | t `isInfixOf` str' -> usend self $ Dummy (drop (length t) str')
          str' | "Marked node transient: " `isInfixOf` str' -> usend self "NodeTransient"
          str' | "timeout_host Just" `isInfixOf` str' -> usend self "timeout_host"
          str' | "Loaded initial data" `isInfixOf` str' -> usend self "InitialLoad"
          str' | "Reviving old node" `isInfixOf` str' -> usend self "ReviveNode"
          str' | "New node contacted" `isInfixOf` str' -> usend self "NewNode"
          _ -> return ()
      usend self ((), ())
    ((), ()) <- expect

    bracket_ (do liftIO $ forM_ [m0, m1] $ \m -> forkProcess m $ do
                   startupHalonNode rcClosure
                   usend self ((), ())
                 forM_ [m0, m1] $ \_ -> do
                   ((), ()) <- expect
                   return ()
             )
             (do liftIO $ forM_ [m0, m1] $ \m -> forkProcess m $ do
                   stopHalonNode
                   usend self ((), ())
                 forM_ [m0, m1] $ \_ -> do
                   ((), ()) <- expect
                   return ()
             ) $ do

      void $ liftIO $ forkProcess m1 $ do
        Nothing <- ignition args
        usend self ((), ())
      ((), ()) <- expect

      say "running NodeUp"
      void $ liftIO $ forkProcess m0 $ do
        -- wait until the EQ tracker is registered
        nodeUp ([localNodeId m1], 1000000)
      "NewNode" :: String <- expect

#ifdef USE_MERO
      let wait = void (expect :: Process ProcessMonitorNotification)
      promulgateEQ [localNodeId m1] (initialDataAddr _host _host 8) >>= (`withMonitor` wait)
      "InitialLoad" :: String <- expect
#endif

      say $ "isolating TS node " ++ show (localNodeId <$> [m1])
      splitNet [[localNodeId m0], [localNodeId m1]]
      -- ack node down
      receiveWait [ matchIf (== "NodeTransient") (void . return) ]
      -- wait until timeout happens
      receiveWait [ matchIf (== "timeout_host") (void . return) ]
      -- then bring it back up
      restoreNet (map localNodeId [m0, m1])
      -- and make bring it back up
      void $ liftIO $ forkProcess m0 $ nodeUp ([localNodeId m1], 1000000)
      receiveWait [ matchIf (== "NewNode") (void . return) ]
      say "testRejoinTimeout complete"

-- | Tests that:
--  * nodes in which we began recovery, continue recover after RC failure
--
-- Spawn TS with one node. Bring up a satellite. Disconnect it. Kill
-- the RC. Wait until we see recovery process continue and reconnect
-- satellite.
testRejoinRCDeath :: String -- ^ Host used for initial data
                  -> Transport
                  -> (EndPointAddress -> EndPointAddress -> IO ())
                  -> IO ()
testRejoinRCDeath _host baseTransport connectionBreak = withTmpDirectory $ do
  (transport, controlled) <- Controlled.createTransport baseTransport
                                                        connectionBreak
  testSplit transport controlled 2 5 $ \[m0,m1]
                                        splitNet restoreNet -> do
    let args = ( False :: Bool
               , [localNodeId m1]
               , 1000 :: Int
               , 1000000 :: Int
               , $(mkClosure 'rcWithDeath) $
                   IgnitionArguments [localNodeId m1]
               , 8*1000000 :: Int
               )
    self <- getSelfPid
    void . liftIO . forkProcess m1 $ do
      registerInterceptor $ \string -> do
        let t = "Recovery Coordinator: received DummyEvent "
        case string of
          str' | t `isInfixOf` str' -> usend self $ Dummy (drop (length t) str')
          str' | "Marked node transient: " `isInfixOf` str' -> usend self "NodeTransient"
          str' | "Loaded initial data" `isInfixOf` str' -> usend self "InitialLoad"
          str' | "Reviving old node" `isInfixOf` str' -> usend self "ReviveNode"
          str' | "Inside try_recover" `isInfixOf` str' -> usend self "RecoverNode"
          str' | "started monitor service on nid" `isInfixOf` str' -> usend self "MonitorStarted"
          _ -> return ()
      usend self ((), ())
    ((), ()) <- expect

    bracket_ (do liftIO $ forM_ [m0, m1] $ \m -> forkProcess m $ do
                   startupHalonNode rcClosure
                   usend self ((), ())
                 forM_ [m0, m1] $ \_ -> do
                   ((), ()) <- expect
                   return ()
             )
             (do liftIO $ forM_ [m0, m1] $ \m -> forkProcess m $ do
                   stopHalonNode
                   usend self ((), ())
                 forM_ [m0, m1] $ \_ -> do
                   ((), ()) <- expect
                   return ()
             ) $ do

      void $ liftIO $ forkProcess m1 $ do
        Nothing <- ignition args
        usend self ((), ())
      ((), ()) <- expect

      say "running NodeUp"
      void $ liftIO $ forkProcess m0 $ do
        -- wait until the EQ tracker is registered
        nodeUp ([localNodeId m1], 1000000)
      "MonitorStarted" <- expect

#ifdef USE_MERO
      let wait = void (expect :: Process ProcessMonitorNotification)
      promulgateEQ [localNodeId m1] (initialDataAddr _host _host 8) >>= (`withMonitor` wait)
      "InitialLoad" :: String <- expect
#endif

      say $ "isolating TS node " ++ show (localNodeId <$> [m1])
      splitNet [[localNodeId m0], [localNodeId m1]]
      -- ack node down
      "NodeTransient" :: String <- expect
      -- wait until recovery starts
      "RecoverNode" <- expect
      _ <- promulgateEQ [localNodeId m1] KillRC
      -- RC restarts but the node is still down
      "NodeTransient" <- expect
      -- recovery starts
      "RecoverNode" <- expect
      -- then bring it back up
      restoreNet (map localNodeId [m0, m1])
      -- and make sure it did come back up
      receiveWait [ matchIf (\msg -> msg == "NodeTransient" || msg == "ReviveNode")
                   (void . return) ]
      say "testRejoinRCDeath complete"

-- | Tests that:
-- * The RC detects when a node disconnects.
-- * Nodes can rejoin before we time them out and mark as down.
--
-- Spawn TS with one node. Bring up a satellite. Disconnect it. Wait until RC
-- detects the node is disconnected. Reconnect the node. Check that RC marks the
-- node as online again.
testRejoin :: String -- ^ Host used for initial data
           -> Transport
           -> (EndPointAddress -> EndPointAddress -> IO ())
           -> IO ()
testRejoin _host baseTransport connectionBreak = withTmpDirectory $ do
  (transport, controlled) <- Controlled.createTransport baseTransport
                                                        connectionBreak
  testSplit transport controlled 2 10 $ \[m0,m1]
                                        splitNet restoreNet -> do
    let args = ( False :: Bool
               , map localNodeId [m1]
               , 1000 :: Int
               , 1000000 :: Int
               , $(mkClosure 'recoveryCoordinator) $
                   IgnitionArguments [localNodeId m1]
               , 8*1000000 :: Int
               )
    self <- getSelfPid
    void . liftIO . forkProcess m1 $ do
      registerInterceptor $ \string -> do
        let t = "Recovery Coordinator: received DummyEvent "
        case string of
          str' | t `isInfixOf` str' -> usend self $ Dummy (drop (length t) str')
          str' | "Marked node transient: " `isInfixOf` str' -> usend self "NodeTransient"
          str' | "Loaded initial data" `isInfixOf` str' -> usend self "InitialLoad"
          str' | "Reviving old node" `isInfixOf` str' -> usend self "ReviveNode"
          str' | "Inside try_recover" `isInfixOf` str' -> usend self "RecoverNode"
          str' | "New node contacted" `isInfixOf` str' -> usend self "NewNode"
          _ -> return ()
      usend self ((), ())
    ((), ()) <- expect

    bracket_ (do liftIO $ forM_ [m0, m1] $ \m -> forkProcess m $ do
                   startupHalonNode rcClosure
                   usend self ((), ())
                 forM_ [m0, m1] $ \_ -> do
                   ((), ()) <- expect
                   return ()
             )
             (do liftIO $ forM_ [m0, m1] $ \m -> forkProcess m $ do
                   stopHalonNode
                   usend self ((), ())
                 forM_ [m0, m1] $ \_ -> do
                   ((), ()) <- expect
                   return ()
             ) $ do

      void $ liftIO $ forkProcess m1 $ do
        Nothing <- ignition args
        usend self ((), ())
      ((), ()) <- expect

      say "running NodeUp"

      void $ liftIO $ forkProcess m0 $ do
        -- wait until the EQ tracker is registered
        nodeUp ([localNodeId m1], 1000000)

      "NewNode" :: String <- expect

#ifdef USE_MERO
      let wait = void (expect :: Process ProcessMonitorNotification)
      promulgateEQ [localNodeId m1] (initialDataAddr _host _host 8) >>= (`withMonitor` wait)
      "InitialLoad" :: String <- expect
#endif

      say $ "isolating TS node " ++ show (localNodeId <$> [m1])
      splitNet [[localNodeId m0], [localNodeId m1]]
      -- ack node down
      receiveWait [ matchIf (== "NodeTransient") (void . return) ]
      -- Wait until recovery starts
      receiveWait [ matchIf (== "RecoverNode") (void . return) ]
      -- Bring one node back up straight away…
      restoreNet (map localNodeId [m0, m1])
      -- …which gives us a revival of it, swallow recovery messages
      -- until the node comes back up
      receiveWait [ matchIf (== "ReviveNode") (void . return) ]

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
