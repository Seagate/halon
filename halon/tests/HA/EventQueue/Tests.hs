-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--

{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}
module HA.EventQueue.Tests ( tests ) where

import Prelude hiding ((<$>))
import Test.Framework
import Test.Transport

import HA.EventQueue
import HA.EventQueue.Process
import HA.EventQueue.Producer
import HA.EventQueue.Types
import HA.EQTracker
import HA.EQTracker.Process
import HA.Replicator
import RemoteTables

import Control.Distributed.Process
import Control.Distributed.Process.Closure

import Control.Applicative ((<$>))
import Control.Monad
import Data.PersistMessage
import Data.Function (on)
import Data.List (sortBy)
import Data.Map (elems)
import qualified Data.Set as Set
import Data.Typeable
import qualified Data.UUID as UUID
import Network.CEP

import Test.Helpers

eqSDict :: SerializableDict EventQueue
eqSDict = SerializableDict

remotable [ 'eqSDict ]

-- | Triggers an event and returns the EventId sent
triggerEvent :: Int -> Process UUID
triggerEvent x = do
    msg <- newPersistMessage x
    pid <- promulgateEvent msg
    withMonitor pid wait
    return $ persistMessageId msg
  where
    wait = void (expect :: Process ProcessMonitorNotification)

requestTimeout :: Int
requestTimeout = 1000000

secs :: Int
secs = 1000000

tests :: forall g. (Typeable g, RGroup g)
      => AbstractTransport -> Proxy g -> IO [TestTree]
tests (AbstractTransport transport _breakConnection _) _ = do
    let rt = HA.EventQueue.Tests.__remoteTable remoteTable
        (==>) :: (IO () -> TestTree) -> (ProcessId -> ProcessId -> g EventQueue
                        -> Process ())
              -> TestTree
        t ==> action = t $ setup $ \eq na rGroup ->
                -- use me as the rc.
                getSelfPid >>= usend eq >> action eq na rGroup

        setup :: (ProcessId -> ProcessId -> g EventQueue -> Process ())
              -> IO ()
        setup action = setup' $ \a b c _ -> action a b c

        setup' :: (  ProcessId
                  -> ProcessId
                  -> g EventQueue
                  -> Closure (Process (g EventQueue))
                  -> Process ()
                  )
                  -> IO ()
        setup' action = withTmpDirectory $ tryWithTimeout transport rt (30 * secs) $ do
            self <- getSelfPid
            let nodes = [processNodeId self]

            cRGroup <- newRGroup $(mkStatic 'eqSDict) "eqtest" 20 1000000
                                 4000000 nodes emptyEventQueue
            rGroup :: g EventQueue <- join $ unClosure cRGroup
            eq <- startEventQueue rGroup
            na <- startEQTracker []
            updateEQNodes nodes
            mapM_ link [eq, na]

            action eq na rGroup cRGroup


        -- The tests below make assumptions on the implementation of
        -- the EQ: that messages are stored in most-recent-first
        -- list. This helper recovers that list and removes some
        -- repetition from the tests while it's at it.
        getMsgsAsList :: g EventQueue -> Process [PersistMessage]
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
              PersistMessage _ _ _ : _ <- getMsgsAsList rGroup
              _ <- expect :: Process PersistMessage
              return ()
        , testSuccess "eq-one-event" ==> \_ _ rGroup -> do
              eid <- triggerEvent 1
              PersistMessage eid' _ _ : _ <- getMsgsAsList rGroup
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
              v@(PersistMessage evtid _ _) :_ <- getMsgsAsList rGroup
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
              PersistMessage evtid _ _ : _ <- getMsgsAsList rGroup
              assertBool "event id is one of messages that were sent"
                (Set.member evtid (Set.fromList evids))
              before <- map persistMessageId <$> getMsgsAsList rGroup
              usend eq evtid
              Published (TrimDone eid) _ <- expect
              assertEqual "correct event was trimmed" evtid eid
              trim1 <- map persistMessageId <$> getMsgsAsList rGroup
              usend eq evtid
              Published (TrimDone eid2) _ <- expect
              assertEqual "correct event was trimmed" evtid eid2

              trim2 <- map persistMessageId <$> getMsgsAsList rGroup
              assertBool "trim is idempotent"
                         (before /= trim1 && before /= trim2 && trim1 == trim2)
        , testSuccess "eq-trim-none" ==> \eq _ rGroup -> do
              subscribe eq (Proxy :: Proxy TrimDone)
              mapM_ triggerEvent [1..10]
              before <- map persistMessageId <$> getMsgsAsList rGroup
              let evtid = UUID.nil
              usend eq evtid
              Published (TrimDone eid) _ <- expect
              assertEqual "correct event was trimmed" evtid eid
              trim <- map persistMessageId <$> getMsgsAsList rGroup
              assertEqual "trimming non existing event is nilpotent" before trim
        , testSuccess "eq-with-no-rc-should-replicate" $ setup $ \_ _ rGroup -> do
              eid <- triggerEvent 1
              PersistMessage eid' _ _ : _ <- getMsgsAsList rGroup
              assertEqual "if no rc exists eq should replicate message" eid eid'
        , testSuccess "eq-should-lookup-for-rc" $ setup $ \eq _ rGroup -> do
              self <- getSelfPid
              eid <- triggerEvent (1::Int)
              PersistMessage eid' _ _ : _ <- getMsgsAsList rGroup
              assertEqual "correct message was received" eid eid'
              usend eq self
              _ <- expect :: Process PersistMessage
              return ()

        -- Test that until removed, messages in the EQ are sent at least once
        -- to the RC everytime it spawns.
        , testSuccess "eq-send-events-to-new-rc" ==> \eq _na _rGroup -> do
            let eventsNum = (5::Int)
                testNum   = 10
            rc <- spawnLocal $ return ()
            usend eq rc
            evs <- Set.fromList <$> forM [1..eventsNum] triggerEvent
            replicateM_ testNum $ do
              self <- getSelfPid
              rc' <- spawnLocal $ do
                evs' <- Set.fromList
                     <$> replicateM eventsNum
                           (persistMessageId  <$> expect)
                usend self (evs' == evs)
              usend eq rc'
              assertBool "event is correct" =<< expect
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
                      usend pidx (n, True)
                      getSelfPid >>= usend self
                      expect -- wait until the test finishes
                    reregister eventQueueLabel eq2
                    say "eq2 reregistered."
            register eventQueueLabel eq1
            eq2 <- expect
            ProcessMonitorNotification _ _ _ <- expect
            kill eq2 "test completed"
        ]
