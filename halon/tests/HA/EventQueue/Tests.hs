-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}
module HA.EventQueue.Tests ( tests, remoteRC__tdict ) where

import Prelude hiding ((<$>))
import Test.Framework

import HA.EventQueue hiding (trim)
import HA.EventQueue.Definitions
import HA.EventQueue.Consumer
import HA.EventQueue.Producer
import HA.EventQueue.Types
import HA.NodeAgent.Messages
import HA.Service (serviceProcess)
import HA.Services.Empty
import HA.Services.EQTracker
import HA.Replicator
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock ( MC_RG )
#else
import HA.Replicator.Log ( MC_RG )
#endif
import RemoteTables

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import Control.Distributed.Process.Timeout (retry)

import Control.Applicative ((<$>))
import Control.Arrow (first)
import Control.Monad
import Data.ByteString ( ByteString )
import Network.CEP
import Network.Transport (Transport)

#ifndef USE_RPC
import Control.Concurrent (threadDelay)
import qualified Network.Socket as TCP
import qualified Network.Transport.TCP as TCP
#endif


eqSDict :: SerializableDict EventQueue
eqSDict = SerializableDict

eqSetRC :: Maybe ProcessId -> EventQueue -> EventQueue
eqSetRC = first . const

remoteRC :: ProcessId -> Process ()
remoteRC controller = do
    self <- getSelfPid
    send controller self
    forever $ do
      msg <- expect
      reconnect controller
      send controller (msg :: HAEvent [ByteString])

remotable [ 'eqSDict, 'eqSetRC, 'remoteRC ]

triggerEvent :: Int -> Process ()
triggerEvent x = promulgate x >>= \pid -> withMonitor pid wait
  where
    wait = void (expect :: Process ProcessMonitorNotification)

requestTimeout :: Int
requestTimeout = 1000000

secs :: Int
secs = 1000000

#ifdef USE_RPC
tests :: Transport -> IO [TestTree]
tests transport = do
#else
tests :: Transport -> TCP.TransportInternals -> IO [TestTree]
tests transport internals = do
#endif
    let rt = HA.EventQueue.Tests.__remoteTable remoteTable
        (==>) :: (IO () -> TestTree) -> (ProcessId -> ProcessId -> MC_RG EventQueue -> Process ()) -> TestTree
        t ==> action = t $ setup $ \eq na rGroup ->
                -- use me as the rc.
                getSelfPid >>= send eq >> action eq na rGroup

        setup :: (ProcessId -> ProcessId -> MC_RG EventQueue -> Process ()) -> IO ()
        setup action = withTmpDirectory $ tryWithTimeout transport rt (30 * secs) $ do
            self <- getSelfPid
            let nodes = [processNodeId self]

            cRGroup <- newRGroup $(mkStatic 'eqSDict) 20 1000000 nodes
                                 (Nothing,[])
            rGroup <- unClosure cRGroup >>= id
            eq <- spawnLocal (eventQueue rGroup)
            na <- spawnLocal . ($ EmptyConf) =<< unClosure (serviceProcess eqTracker)
            True <- updateEQNodes na nodes
            mapM_ link [eq, na]

            action eq na rGroup

    return
        [ testSuccess "eq-init-empty" ==> \_ _ rGroup -> do
              (_, []) <- retry requestTimeout $ getState rGroup
              return ()
        , testSuccess "eq-is-registered" ==> \eq _ _ -> do
              eqLoc <- whereis eventQueueLabel
              assert $ eqLoc == (Just eq)
        , testSuccess "eq-one-event-direct" ==> \_ _ rGroup -> do
              self <- getSelfNode
              pid <- promulgateEQ [self] (1 :: Int)
              _ <- monitor pid
              (_ :: ProcessMonitorNotification) <- expect
              (_, [HAEvent (EventId _ 1) _ _]) <- retry requestTimeout $
                                                    getState rGroup
              return ()
        , testSuccess "eq-one-event" ==> \_ _ rGroup -> do
              triggerEvent 1
              (_, [HAEvent (EventId _ 1) _ _]) <- retry requestTimeout $
                                                    getState rGroup
              return ()
        , testSuccess "eq-many-events" ==> \_ _ rGroup -> do
              mapM_ triggerEvent [1..10]
              assert . (== 10) . length . snd =<< retry requestTimeout
                                                    (getState rGroup)
        , testSuccess "eq-trim-one" ==> \eq _ rGroup -> do
              simpleSubscribe eq (Sub :: Sub TrimDone)
              mapM_ triggerEvent [1..10]
              (_, (HAEvent evtid _ _ ):_) <- retry requestTimeout $
                                               getState rGroup
              send eq evtid
              Published (TrimDone eid) _ <- expect
              assert (evtid == eid)
              assert . (== 9) . length . snd =<< retry requestTimeout
                                                   (getState rGroup)
        , testSuccess "eq-trim-idempotent" ==> \eq _ rGroup -> do
              simpleSubscribe eq (Sub :: Sub TrimDone)
              mapM_ triggerEvent [1..10]
              (_, (HAEvent evtid _ _ ):_) <- retry requestTimeout $
                                               getState rGroup
              before <- map (eventCounter . eventId) . snd <$>
                          retry requestTimeout (getState rGroup)
              send eq evtid
              Published (TrimDone eid) _ <- expect
              assert (evtid == eid)
              trim1 <- map (eventCounter . eventId) . snd <$>
                          retry requestTimeout (getState rGroup)
              send eq evtid
              Published (TrimDone eid2) _ <- expect
              assert (evtid == eid2)
              trim2 <- map (eventCounter . eventId) . snd <$>
                          retry requestTimeout (getState rGroup)
              assert (before /= trim1 && before /= trim2 && trim1 == trim2)
        , testSuccess "eq-trim-none" ==> \eq na rGroup -> do
              simpleSubscribe eq (Sub :: Sub TrimDone)
              mapM_ triggerEvent [1..10]
              before <- map (eventCounter . eventId) . snd <$>
                          retry requestTimeout (getState rGroup)
              let evtid = EventId na 11
              send eq evtid
              Published (TrimDone eid) _ <- expect
              assert (evtid == eid)
              trim <- map (eventCounter . eventId) . snd <$>
                          retry requestTimeout (getState rGroup)
              assert (before == trim)
        , testSuccess "eq-with-no-rc-should-replicate" $ setup $ \_ _ rGroup -> do
              triggerEvent 1
              (_, [ HAEvent (EventId _ 1) _ _]) <- retry requestTimeout $
                                                     getState rGroup
              return ()
        , testSuccess "eq-should-lookup-for-rc" $ setup $ \_ _ rGroup -> do
              self <- getSelfPid
              retry requestTimeout $
                updateStateWith rGroup $ $(mkClosure 'eqSetRC) $ Just self
              triggerEvent 1
              (_, [ HAEvent (EventId _ 1) _ _]) <- retry requestTimeout $
                                                     getState rGroup
              return ()
        , testSuccess "eq-should-record-that-rc-died" $ setup $ \eq _ _ -> do
              simpleSubscribe eq (Sub :: Sub RCDied)
              rc <- spawnLocal $ return ()
              send eq rc
              -- Wait for confirmation of RC death.
              Published RCDied _ <- expect
              return ()

          -- XXX run this test with the rpc transport when networkBreakConnection
          -- is implemented for it.
#ifndef USE_RPC
        , testSuccess "eq-should-reconnect-to-rc" $
              setup $ \eq _ _ ->
                bracket
                  (liftIO $ newLocalNode transport rt)
                  (liftIO . closeLocalNode)
                  $ \ln1 ->
                -- Spawn a remote RC.
                bracket
                  (getSelfPid >>= spawn (localNodeId ln1) . $(mkClosure 'remoteRC))
                  (flip exit "test finished")
                  $ \rc -> do
                simpleSubscribe eq (Sub :: Sub RCLost)
                self <- getSelfPid
                -- Set me as controller of the RC.
                send rc self
                send eq rc
                triggerEvent 1
                -- The RC should forward the event to me.
                (expectTimeout defaultTimeout :: Process (Maybe (HAEvent [ByteString]))) >>=
                  \case
                    Just (HAEvent (EventId _ 1) _ _) -> return ()
                    Nothing -> error "No HA Event received from first RC."
                    _ -> error "Wrong event received from first RC."
                nid <- getSelfNode
                -- Break the connection
                liftIO $ do
                  sock <- TCP.socketBetween internals (nodeAddress nid) (nodeAddress $ localNodeId ln1)
                  TCP.sClose sock
                  threadDelay 10000
                -- Expect confirmation from the eq that the rc connection has broken.
                expectTimeout defaultTimeout >>= \case
                  Just (Published RCLost _) -> return ()
                  Nothing -> error "No confirmation of broken connection from EQ."
                triggerEvent 2
                -- EQ should reconnect to the RC, and the RC should forward the
                -- event to me.
                (expectTimeout defaultTimeout :: Process (Maybe (HAEvent [ByteString]))) >>=
                  \case
                    Just (HAEvent (EventId _ 1) _ _) -> return ()
                    Nothing -> error "No HA Event received from second RC."
                    _ -> error "Wrong event received from second RC."
                return ()
#endif
        , testSuccess "eq-save-path" ==> \eq _ rGroup -> do
              triggerEvent 1
              (HAEvent _ _ s1) <- expect :: Process (HAEvent [ByteString])
              (_, [HAEvent _ _ _]) <- retry requestTimeout $ getState rGroup
              assert (head s1 == eq)
        ]
