-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}
module HA.EventQueue.Tests ( tests ) where

import Prelude hiding ((<$>))
import Test.Framework
import Test.Transport

import HA.EventQueue hiding (trim)
import HA.EventQueue.Definitions
import HA.EventQueue.Consumer
import HA.EventQueue.Producer
import HA.EventQueue.Types (newPersistMessage, PersistMessage(..))
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
import qualified Data.Set as Set
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Network.CEP

eqSDict :: SerializableDict EventQueue
eqSDict = SerializableDict

eqSetRC :: Maybe ProcessId -> EventQueue -> EventQueue
eqSetRC = first . const

remoteRC :: ProcessId -> Process ()
remoteRC controller = forever $ do
    evt <- expect
    reconnect controller
    send controller (evt :: HAEvent Int)

remotable [ 'eqSDict, 'eqSetRC ]

-- | Triggers an event and returns the EventId sent
triggerEvent :: Int -> Process UUID
triggerEvent x = do
    msg <- newPersistMessage x
    pid <- promulgateEvent msg
    withMonitor pid wait
    return $ persistEventId msg
  where
    wait = void (expect :: Process ProcessMonitorNotification)

requestTimeout :: Int
requestTimeout = 1000000

secs :: Int
secs = 1000000

tests :: AbstractTransport -> IO [TestTree]
tests (AbstractTransport transport breakConnection _) = do
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
              (_, [PersistMessage _ _]) <- retry requestTimeout $
                                                    getState rGroup
              return ()
        , testSuccess "eq-one-event" ==> \_ _ rGroup -> do
              eid <- triggerEvent 1
              (_, [PersistMessage eid' _]) <- retry requestTimeout $
                                                    getState rGroup
              assert (eid == eid')
        , testSuccess "eq-many-events" ==> \_ _ rGroup -> do
              mapM_ triggerEvent [1..10]
              assert . (== 10) . length . snd =<< retry requestTimeout
                                                    (getState rGroup)
        , testSuccess "eq-trim-one" ==> \eq _ rGroup -> do
              subscribe eq (Sub :: Sub TrimDone)
              mapM_ triggerEvent [1..10]
              (_, (PersistMessage evtid _ ):_) <- retry requestTimeout $
                                               getState rGroup
              send eq evtid
              Published (TrimDone eid) _ <- expect
              assert (evtid == eid)
              assert . (== 9) . length . snd =<< retry requestTimeout
                                                   (getState rGroup)
        , testSuccess "eq-trim-idempotent" ==> \eq _ rGroup -> do
              subscribe eq (Sub :: Sub TrimDone)
              mapM_ triggerEvent [1..10]
              (_, (PersistMessage evtid _ ):_) <- retry requestTimeout $
                                               getState rGroup
              before <- map persistEventId . snd <$>
                          retry requestTimeout (getState rGroup)
              send eq evtid
              Published (TrimDone eid) _ <- expect
              assert (evtid == eid)
              trim1 <- map persistEventId . snd <$>
                          retry requestTimeout (getState rGroup)
              send eq evtid
              Published (TrimDone eid2) _ <- expect
              assert (evtid == eid2)
              trim2 <- map persistEventId . snd <$>
                          retry requestTimeout (getState rGroup)
              assert (before /= trim1 && before /= trim2 && trim1 == trim2)
        , testSuccess "eq-trim-none" ==> \eq _ rGroup -> do
              subscribe eq (Sub :: Sub TrimDone)
              mapM_ triggerEvent [1..10]
              before <- map persistEventId . snd <$>
                          retry requestTimeout (getState rGroup)
              let evtid = UUID.nil
              send eq evtid
              Published (TrimDone eid) _ <- expect
              assert (evtid == eid)
              trim <- map persistEventId . snd <$>
                          retry requestTimeout (getState rGroup)
              assert (before == trim)
        , testSuccess "eq-with-no-rc-should-replicate" $ setup $ \_ _ rGroup -> do
              eid <- triggerEvent 1
              (_, [PersistMessage eid' _]) <- retry requestTimeout $
                                                     getState rGroup
              assert (eid == eid')
        , testSuccess "eq-should-lookup-for-rc" $ setup $ \_ _ rGroup -> do
              self <- getSelfPid
              retry requestTimeout $
                updateStateWith rGroup $ $(mkClosure 'eqSetRC) $ Just self
              eid <- triggerEvent 1
              (_, [PersistMessage eid' _]) <- retry requestTimeout $
                                                     getState rGroup
              assert (eid == eid')
        , testSuccess "eq-should-record-that-rc-died" $ setup $ \eq _ _ -> do
              subscribe eq (Sub :: Sub RCDied)
              rc <- spawnLocal $ return ()
              send eq rc
              -- Wait for confirmation of RC death.
              Published RCDied _ <- expect
              return ()

          -- XXX run this test with the rpc transport when networkBreakConnection
          -- is implemented for it.
#ifndef USE_RPC
        , testSuccess "eq-should-reconnect-to-rc" $
              setup $ \eq _ rGroup ->
                bracket
                  (liftIO $ newLocalNode transport rt)
                  (liftIO . closeLocalNode)
                  $ \ln1 ->
                -- Spawn a remote RC.
                bracket
                  (do self <- getSelfPid
                      liftIO $ runProcess ln1 $ do
                        pid <- spawnLocal $ remoteRC self
                        -- spawn a colocated EQ
                        _ <- spawnLocal (eventQueue rGroup)
                        send self pid
                      expect
                  )
                  (flip exit "test finished")
                  $ \rc -> do
                subscribe eq (Sub :: Sub RCLost)
                send eq rc
                eid <- triggerEvent 1
                -- The RC should forward the event to me.
                (expectTimeout defaultTimeout :: Process (Maybe (HAEvent Int))) >>=
                  \case
                    Just (HAEvent eid' _ _) | eid == eid' -> return ()
                    Nothing -> error "No HA Event received from first RC."
                    _ -> error "Wrong event received from first RC."
                nid <- getSelfNode
                -- Break the connection
                liftIO $ breakConnection (nodeAddress nid) (nodeAddress $ localNodeId ln1)
                -- Expect confirmation from the eq that the rc connection has broken.
                expectTimeout defaultTimeout >>= \case
                  Just (Published RCLost _) -> return ()
                  Nothing -> error "No confirmation of broken connection from EQ."
                eid2 <- triggerEvent 2
                -- EQ should reconnect to the RC, and the RC should forward the
                -- event to me.
                (expectTimeout defaultTimeout :: Process (Maybe (HAEvent Int))) >>=
                  \case
                    Just (HAEvent eid' _ _) | eid2 == eid' -> return ()
                    Nothing -> error "No HA Event received from second RC."
                    _ -> error "Wrong event received from second RC."
                return ()
#endif
        , testSuccess "eq-save-path" ==> \_ _ rGroup -> do
              eid <- triggerEvent 1
              HAEvent eid' (_ :: Int) _ <- expect
              assert $ eid == eid'
              (_, [PersistMessage _ _]) <- retry requestTimeout $ getState rGroup
              return ()
        -- Test that until removed, messages in the EQ are sent at least once
        -- to the RC everytime it spawns.
        , testSuccess "eq-send-events-to-new-rc" ==> \eq _na _rGroup -> do
            let eventsNum = (5::Int)
                testNum   = 10
            rc <- spawnLocal $ return ()
            send eq rc
            evs <- Set.fromList <$> forM [1..eventsNum] triggerEvent
            subscribe eq (Sub :: Sub RCDied)
            replicateM_ testNum $ do
              self <- getSelfPid
              rc' <- spawnLocal $ do
                evs' <- Set.fromList
                     <$> replicateM eventsNum
                           ((\(HAEvent e (_::Int) _) -> e) <$> expect)
                send self (evs' == evs)
              send eq rc'
              True <- expect
              Published RCDied _ <- expect
              return ()
        , testSuccess "send-until-acknowledged" ==> \eq na rGroup -> do
            _ <- monitor eq
            unlink eq
            kill eq "for testing"
            ProcessMonitorNotification _ _ _ <- expect
            pid <- promulgate (1::Int)
            monitor pid
            self <- getSelfPid
            eq <- spawnLocal $ do
                    -- ignore first message, promulgate should retry
                    _ <- expect :: Process (ProcessId, PersistMessage)
                    (pid, PersistMessage{}) <- expect
                    n <- getSelfNode
                    send pid (n, n)
                    send self ()
            register eventQueueLabel eq
            () <- expect
            ProcessMonitorNotification _ _ _ <- expect
            return ()
        ]
