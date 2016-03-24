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

import HA.EventQueue
import HA.EventQueue.Producer
import HA.EventQueue.Types (newPersistMessage, PersistMessage(..), HAEvent(..))
import HA.EQTracker
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

import Control.Applicative ((<$>))
import Control.Monad
import Data.Function (on)
import Data.List (sortBy)
import Data.Map (elems)
import qualified Data.Set as Set
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Data.Proxy (Proxy(..))
import Network.CEP

import Test.Helpers

eqSDict :: SerializableDict EventQueue
eqSDict = SerializableDict

remoteRC :: ProcessId -> Process ()
remoteRC controller = forever $ do
    evt <- expect
    usend controller (evt :: HAEvent Int)

remotable [ 'eqSDict ]

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
                getSelfPid >>= usend eq >> action eq na rGroup

        setup :: (ProcessId -> ProcessId -> MC_RG EventQueue -> Process ())
              -> IO ()
        setup action = setup' $ \a b c _ -> action a b c

        setup' :: (  ProcessId
                  -> ProcessId
                  -> MC_RG EventQueue
                  -> Closure (Process (MC_RG EventQueue))
                  -> Process ()
                  )
                  -> IO ()
        setup' action = withTmpDirectory $ tryWithTimeout transport rt (30 * secs) $ do
            self <- getSelfPid
            let nodes = [processNodeId self]

            cRGroup <- newRGroup $(mkStatic 'eqSDict) 20 1000000 nodes
                                 emptyEventQueue
            rGroup <- unClosure cRGroup >>= id
            eq <- startEventQueue rGroup
            na <- startEQTracker []
            updateEQNodes nodes
            mapM_ link [eq, na]

            action eq na rGroup cRGroup


        -- The tests below make assumptions on the implementation of
        -- the EQ: that messages are stored in most-recent-first
        -- list. This helper recovers that list and removes some
        -- repetition from the tests while it's at it.
        getMsgsAsList :: MC_RG EventQueue -> Process [PersistMessage]
        getMsgsAsList rGroup = do
          evs <- _eqMap <$> retryRGroup rGroup requestTimeout (getState rGroup)
          return . map fst . reverse . sortBy (compare `on` snd) $ elems evs

    return
        [ testSuccess "eq-init-empty" ==> \_ _ rGroup -> do
              [] <- getMsgsAsList rGroup
              return ()
        , testSuccess "eq-is-registered" ==> \eq _ _ -> do
              eqLoc <- whereis eventQueueLabel
              assertEqual "eq is registered in registry" eqLoc (Just eq)
        , testSuccess "eq-one-event-direct" ==> \eq _ rGroup -> do
              selfNode <- getSelfNode
              self     <- getSelfPid
              usend eq self
              pid <- promulgateEQ [selfNode] (1 :: Int)
              _ <- monitor pid
              (_ :: ProcessMonitorNotification) <- expect
              PersistMessage _ _ : _ <- getMsgsAsList rGroup
              _ <- expect :: Process (HAEvent Int)
              return ()
        , testSuccess "eq-one-event" ==> \_ _ rGroup -> do
              eid <- triggerEvent 1
              PersistMessage eid' _ : _ <- getMsgsAsList rGroup
              assertEqual "one message was sent" eid eid'
        , testSuccess "eq-many-events" ==> \_ _ rGroup -> do
              let msgs = [1..10::Int]
              mapM_ triggerEvent msgs
              assertEqual "the number of messages received equal to number of messages sent"
                          (Set.fromList msgs) . Set.fromList
                          -- 10 . length .snd
                          =<< unPersistHAEvents
                          =<< getMsgsAsList rGroup
        , testSuccess "eq-trim-one" ==> \eq _ rGroup -> do
              let msgs = [1..10::Int]
              subscribe eq (Proxy :: Proxy TrimDone)
              mapM_ triggerEvent msgs
              v@(PersistMessage evtid _) :_ <- getMsgsAsList rGroup
              Just elm <- unPersistHAEvent v :: Process (Maybe Int)
              usend eq evtid
              Published (TrimDone eid) _ <- expect
              assert (evtid == eid)

              assertBool "trimmed event is not in storage"
                . not . Set.member elm . Set.fromList
                =<< unPersistHAEvents
                =<< getMsgsAsList rGroup
        , testSuccess "eq-trim-idempotent" ==> \eq _ rGroup -> do
              subscribe eq (Proxy :: Proxy TrimDone)
              evids <- mapM triggerEvent [1..10]
              PersistMessage evtid _ : _ <- getMsgsAsList rGroup
              assertBool "event id is one of messages that were sent"
                (Set.member evtid (Set.fromList evids))
              before <- map persistEventId <$> getMsgsAsList rGroup
              usend eq evtid
              Published (TrimDone eid) _ <- expect
              assertEqual "correct event was trimmed" evtid eid
              trim1 <- map persistEventId <$> getMsgsAsList rGroup
              usend eq evtid
              Published (TrimDone eid2) _ <- expect
              assertEqual "correct event was trimmed" evtid eid2

              trim2 <- map persistEventId <$> getMsgsAsList rGroup
              assertBool "trim is idempotent"
                         (before /= trim1 && before /= trim2 && trim1 == trim2)
        , testSuccess "eq-trim-none" ==> \eq _ rGroup -> do
              subscribe eq (Proxy :: Proxy TrimDone)
              mapM_ triggerEvent [1..10]
              before <- map persistEventId <$> getMsgsAsList rGroup
              let evtid = UUID.nil
              usend eq evtid
              Published (TrimDone eid) _ <- expect
              assertEqual "correct event was trimmed" evtid eid
              trim <- map persistEventId <$> getMsgsAsList rGroup
              assertEqual "trimming non existing event is nilpotent" before trim
        , testSuccess "eq-with-no-rc-should-replicate" $ setup $ \_ _ rGroup -> do
              eid <- triggerEvent 1
              PersistMessage eid' _ : _ <- getMsgsAsList rGroup
              assertEqual "if no rc exists eq should replicate message" eid eid'
        , testSuccess "eq-should-lookup-for-rc" $ setup $ \eq _ rGroup -> do
              self <- getSelfPid
              eid <- triggerEvent (1::Int)
              PersistMessage eid' _ : _ <- getMsgsAsList rGroup
              assertEqual "correct message was received" eid eid'
              usend eq self
              _ <- expect :: Process (HAEvent Int)
              return ()
        , testSuccess "eq-should-record-that-rc-died" $ setup $ \eq _ _ -> do
              subscribe eq (Proxy :: Proxy RCDied)
              rc <- spawnLocal $ return ()
              usend eq rc
              -- Wait for confirmation of RC death.
              Published RCDied _ <- expect
              return ()

          -- XXX run this test with the rpc transport when networkBreakConnection
          -- is implemented for it.
#ifndef USE_RPC
        , testSuccess "eq-should-reconnect-to-rc" $
              setup' $ \eq _ _ cRGroup ->
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
                        rGroup <- unClosure cRGroup >>= id
                        _ <- startEventQueue rGroup
                        usend self pid
                      expect
                  )
                  (flip exit "test finished")
                  $ \rc -> do
                subscribe eq (Proxy :: Proxy RCLost)
                usend eq rc
                say "Event 1"
                eid <- triggerEvent 1
                -- The RC should forward the event to me.
                say "Expecting event ..."
                (expectTimeout defaultTimeout :: Process (Maybe (HAEvent Int))) >>=
                  \case
                    Just (HAEvent eid' _ _) | eid == eid' -> return ()
                    Nothing -> error "No HA Event received from first RC."
                    _ -> error "Wrong event received from first RC."
                nid <- getSelfNode
                -- Break the connection
                say "Breaking connection"
                liftIO $ breakConnection (nodeAddress nid) (nodeAddress $ localNodeId ln1)
                -- Expect confirmation from the eq that the rc connection has broken.
                expectTimeout defaultTimeout >>= \case
                  Just (Published RCLost _) -> return ()
                  Nothing -> error "No confirmation of broken connection from EQ."
                say "Event 2"
                eid2 <- triggerEvent 2
                -- EQ should reconnect to the RC, and the RC should forward the
                -- event to me.
                receiveTimeout defaultTimeout
                  [ matchIf (\(HAEvent eid' _ _ :: HAEvent Int) -> eid2 == eid')
                            (const $ return ())
                  ] >>= \case
                    Just () -> return ()
                    Nothing -> error "No HA Event received from second RC."
                return ()
#endif
        -- Test that until removed, messages in the EQ are sent at least once
        -- to the RC everytime it spawns.
        , testSuccess "eq-send-events-to-new-rc" ==> \eq _na _rGroup -> do
            let eventsNum = (5::Int)
                testNum   = 10
            rc <- spawnLocal $ return ()
            usend eq rc
            evs <- Set.fromList <$> forM [1..eventsNum] triggerEvent
            subscribe eq (Proxy :: Proxy RCDied)
            replicateM_ testNum $ do
              self <- getSelfPid
              rc' <- spawnLocal $ do
                evs' <- Set.fromList
                     <$> replicateM eventsNum
                           ((\(HAEvent e (_::Int) _) -> e) <$> expect)
                usend self (evs' == evs)
              usend eq rc'
              assertBool "event is correct" =<< expect
              Published RCDied _ <- expect
              return ()
        , testSuccess "send-until-acknowledged" ==> \eq _na _rGroup -> do
            _ <- monitor eq
            unlink eq
            kill eq "for testing"
            ProcessMonitorNotification _ _ _ <- expect
            pid <- promulgate (1::Int)
            _ <- monitor pid
            say $ "Monitoring promulgate pid: " ++ show pid
            self <- getSelfPid
            eq1 <- spawnLocal $ do
                    -- ignore first message, promulgate should retry
                    _ <- expect :: Process (ProcessId, PersistMessage)
                    say "First message ignored."
                    eq2 <- spawnLocal $ do
                      (pidx, PersistMessage{}) <- expect
                      say $ "Second message received: " ++ show pidx
                      n <- getSelfNode
                      usend pidx (n, Right n :: Either NodeId NodeId)
                      getSelfPid >>= usend self
                      expect -- wait until the test finishes
                    reregister eventQueueLabel eq2
                    say "eq2 reregistered."
            register eventQueueLabel eq1
            eq2 <- expect
            ProcessMonitorNotification _ _ _ <- expect
            kill eq2 "test completed"
        ]
