-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Tests that tracking station failures allow the cluster to proceed.
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
--

{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
module HA.Test.Disconnect
  ( testDisconnect
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import qualified Control.Distributed.Process.Scheduler as Scheduler
import Control.Distributed.Static ( closureCompose )
import Control.Monad
import Data.List
import Data.Binary

import Network.Transport (Transport, EndPointAddress)

import HA.RecoveryCoordinator.Definitions
import HA.RecoveryCoordinator.Mero
import HA.EventQueue.Producer
import HA.Resources
import HA.Service hiding (__remoteTable)
import qualified HA.Services.Ping as Ping
import HA.Network.RemoteTables (haRemoteTable)
import Mero.RemoteTables (meroRemoteTable)
import qualified Network.Transport.Controlled as Controlled

import HA.NodeUp ( nodeUp )
import HA.Startup
import Test.Framework

import Data.Typeable
import GHC.Generics

import TestRunner

myRemoteTable :: RemoteTable
myRemoteTable = haRemoteTable $ meroRemoteTable initRemoteTable

rcClosure :: Closure ([NodeId] -> ProcessId -> ProcessId -> Process ())
rcClosure = $(mkStaticClosure 'recoveryCoordinator) `closureCompose`
               $(mkStaticClosure 'ignitionArguments)

data Dummy = Dummy String deriving (Typeable,Generic)

instance Binary Dummy

testDisconnect :: Transport
               -> (EndPointAddress -> EndPointAddress -> IO ())
               -> IO ()
testDisconnect baseTransport connectionBreak = withTmpDirectory $ do
  (transport, controlled) <- Controlled.createTransport baseTransport
                                                        connectionBreak
  testSplit transport controlled 4 $ \[m0,m1,m2,m3]
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

testSplit :: Transport
          -> Controlled.Controlled
          -- ^ Transport and controller object.
          -> Int
          -- ^ Number of nodes to create.
          -> (  [LocalNode]
                -- ^ List of replica nodes.
             -> ([[NodeId]] -> Process ())
                -- ^ Callback that splits network between nodes in groups.
             -> ([NodeId] -> Process ())
                -- ^ Restores communication among the nodes.
             -> Process ()
             )
          -> IO ()
testSplit transport t amountOfReplicas action =
    runTest (amountOfReplicas + 1) 10 1000000 transport myRemoteTable $ \ns -> do
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
