-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- All events intended to the RC should be sent to the Event Queue using the
-- "HA.EventQueue.Producer" API. The Event Queue is a replicated
-- mailbox that is resilient to failure of any minority of replicas. Events
-- posted to the Event Queue are forwarded to consumers (typically the RC) and
-- only removed when the consumers have explicitly acknowledged to have handled
-- them.
--
-- Upon receiving an event, the RC must take recovery measures and notify to
-- the Event Queue with a 'Trim' message that the recovery for a given event
-- or sequence of events is done. Upon receiving such notification, the Event
-- Queue component can delete the event from the replicated mailbox.
--
-- If a recovery procedure is interrupted due to a failure in the tracking
-- station or in the RC, the Event Queue will send the unhandled events to
-- another instance of the RC. This is why it is important that all operations
-- of the recovery coordinator be idempotent.
--
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE TypeFamilies              #-}
{-# LANGUAGE UndecidableInstances      #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}
module HA.EventQueue
  ( eventQueue
  , EventQueue
  , __remoteTable
  , eventQueueLabel
  ) where

import HA.EventQueue.Consumer
import HA.EventQueue.Types
import HA.Replicator ( RGroup, updateStateWith, getState)
import Control.SpineSeq (spineSeq)
import FRP.Sodium

import Control.Concurrent
import Control.Distributed.Process hiding (newChan)
import Control.Distributed.Process.Closure ( remotable, mkClosure )
import Control.Distributed.Process.Serializable (Serializable)
import Control.Monad.State.Strict

import Control.Applicative
import Control.Arrow ( first, second )
import Data.ByteString ( ByteString )
import Data.Foldable (for_, traverse_)
import Data.Monoid ((<>))

-- | Since there is at most one Event Queue per tracking station node,
-- the @eventQueueLabel@ is used to register and lookup the Event Queue of a
-- node.
eventQueueLabel :: String
eventQueueLabel = "HA.EventQueue"

-- | Send HAEvent and provide information about current process.
sendHAEvent :: Serializable a => ProcessId -> HAEvent a -> Process ()
sendHAEvent next ev = getSelfPid >>= \pid -> send next ev{eventHops = pid : eventHops ev}

-- | State of the event queue.
--
-- It contains the process id of the RC and the list of pending events.
type EventQueue = (Maybe ProcessId, [HAEvent [ByteString]])

addSerializedEvent :: HAEvent [ByteString] -> EventQueue -> EventQueue
addSerializedEvent = second . (:)

setRC :: Maybe ProcessId -> EventQueue -> EventQueue
setRC = first . const

-- | "compare and swap" for updating the RC
compareAndSwapRC :: (Maybe ProcessId, Maybe ProcessId) -> EventQueue -> EventQueue
compareAndSwapRC (expected, new) = first $ \current ->
    if current == expected then new else current

filterEvent :: EventId -> EventQueue -> EventQueue
filterEvent eid = second $ spineSeq . filter (\HAEvent{..} -> eid /= eventId)

remotable [ 'addSerializedEvent
          , 'setRC
          , 'compareAndSwapRC
          , 'filterEvent
          ]

-- | @eventQueue rg@ starts an event queue. @rg@ is the replicator group used to
-- store the events until RC handles them.
--
-- When an RC is spawned, its pid should be sent to the colocated EQ which will
-- record the pid in the replicated state so it is available to other EQs.
--
-- When the EQ receives an event, it will replicate the event, acknowledge it
-- back to the reporter, and report it to the RC. If the EQ doesn't know where
-- the RC is, it will try to learn it from the replicated state.
--
eventQueue :: RGroup g => g EventQueue -> Process ()
eventQueue rg = do
  jobs <- liftIO newChan
  self  <- getSelfPid
  register eventQueueLabel self

  (mRC,_) <- getState rg

  -- The EQ must monitor the RC or it will never realize when the RC stops
  -- responding and won't ever care of checking the replicated state to learn
  -- of new RCs
  traverse_ monitor mRC

  matches <- liftIO $ build $ network jobs mRC rg
  forever $ do
    receiveWait matches
    liftIO (readChan jobs) >>= id

--------------------------------------------------------------------------------
-- Event network
--------------------------------------------------------------------------------
-- | CEP monad. Registers any subscription and produces
--   @[Match ()]@ when executed. It's built on top of Sodium @Reactive@ monad.
newtype CEP a = CEP (StateT [Match ()] Reactive a)
  deriving (Functor, Applicative, Monad, MonadState [Match ()])

-- | Procduces a list of @Match ()@ based on all subscriptions
build :: CEP a -> IO [Match ()]
build (CEP m) = sync $ execStateT m []

-- | Lifts a Sodium @Reactive@ computation in @CEP@ monad
liftReactive :: Reactive a -> CEP a
liftReactive m = CEP $ lift m

-- | Registers a subscription to a message of type 'a'. Uses `match` internally
subscribe :: Serializable a => CEP (Event a)
subscribe = do
  (evt, push) <- liftReactive newEvent
  let m = match (liftIO . sync . push)

  modify' (m:)
  return evt

-- | Event queue event network. An event queue state is based on whether we
--   know the @ProcessId@ of the current Recovery Coordinater. We update
--   that information each time one of these events occured:
--     - New Recovery Coordinater spawned
--     - New process monitor notification
--     - An event has been handled
--     - New @HAEvent [Bytestring]@ event
network :: RGroup g
        => Chan (Process ())
        -> Maybe ProcessId
        -> g EventQueue
        -> CEP ()
network jobs startRC rg = do
  (ovd_rcE, push_ovd_rcE) <- liftReactive newEvent
  local_rc_spawnedE       <- subscribe
  monitor_notifE          <- subscribe
  handled_evtE            <- subscribe
  ha_eventE               <- subscribe

  let eventQueueE = fmap localRCSpawned local_rc_spawnedE   <>
                    fmap monitorNotification monitor_notifE <>
                    fmap handledEvent handled_evtE          <>
                    fmap processEvent  ha_eventE            <>
                    fmap const ovd_rcE -- override current RC pid

  eventQueueB <- liftReactive $ accum startRC eventQueueE

  let monitorSnapshot = snapshot (,) monitor_notifE eventQueueB
      processEventSnapshot =
        snapshot (\(ssid, evt) nmRC -> (nmRC, ssid, evt)) ha_eventE eventQueueB

  liftReactive $ do
    _ <- listen local_rc_spawnedE (sendTask . observeLocalRCSpawned rg)
    _ <- listen monitorSnapshot
           (\(pid,res) -> sendTask $ observeMonitorNotification rg pid res)
    _ <- listen handled_evtE (sendTask . observeEventHandled rg)
    _ <- listen processEventSnapshot $ \(nmRC, ssid, evt) ->
          sendTask $ observeProcessHAEvent rg push_ovd_rcE nmRC ssid evt
    return ()
  where
    sendTask = writeChan jobs

--------------------------------------------------------------------------------
-- Model:
-- =====
-- Each time a Event is fired, we update event queue state accordingly. We can
-- only use pure functions.
--------------------------------------------------------------------------------
localRCSpawned :: ProcessId -> Maybe ProcessId -> Maybe ProcessId
localRCSpawned rc _ = Just rc

monitorNotification :: ProcessMonitorNotification
                    -> Maybe ProcessId
                    -> Maybe ProcessId
monitorNotification (ProcessMonitorNotification _ pid _) mRC
  | Just pid == mRC = Nothing
  | otherwise       = mRC

handledEvent :: EventId -> Maybe ProcessId -> Maybe ProcessId
handledEvent _ mRC = mRC

processEvent :: (ProcessId, HAEvent [ByteString])
             -> Maybe ProcessId
             -> Maybe ProcessId
processEvent _ mRC = mRC

--------------------------------------------------------------------------------
-- Observer:
-- =========
-- Effecful computation executed each time the Event it's listening is fired
--------------------------------------------------------------------------------
-- | A local RC has been spawned.
observeLocalRCSpawned :: RGroup g
                      => g EventQueue
                      -> ProcessId
                      -> Process ()
observeLocalRCSpawned rg rc = do
  _ <- monitor rc
  -- Record in the replicated state that there is a new RC.
  updateStateWith rg $ $(mkClosure 'setRC) $ Just rc
  -- Send the pending events to the new RC.
  self <- getSelfPid
  (_, pendingEvents) <- getState rg
  for_ (reverse pendingEvents) $ \ev ->
    send rc ev{eventHops = self : eventHops ev}

observeMonitorNotification :: RGroup g
                           => g EventQueue
                           -> ProcessMonitorNotification
                           -> Maybe ProcessId
                           -> Process ()
observeMonitorNotification rg (ProcessMonitorNotification _ pid reason) mRC = go
  where
    -- Check the identity of the process in case the
    -- notifications get mixed for old and new RCs.
    go | Just pid == mRC =
             case reason of
             -- The connection to the RC failed.
             -- Call reconnect to say it is ok to connect again.
               DiedDisconnect -> traverse_ reconnect mRC >> say "RC is lost."
               -- The RC died.
               -- We use compare and swap to make sure we don't overwrite
               -- the pid of a respawned RC
               _ -> do let nothing = Nothing :: Maybe ProcessId
                           upd     = (mRC, nothing)

                       updateStateWith rg $ $(mkClosure 'compareAndSwapRC) upd
                       say "RC died."
       | otherwise = return ()

-- | The RC handled the event with the given id.
observeEventHandled :: RGroup g => g EventQueue -> EventId -> Process ()
observeEventHandled rg eid = do
  updateStateWith rg $ $(mkClosure 'filterEvent) eid
  say "Trim done."

observeProcessHAEvent :: RGroup g
                      => g EventQueue
                      -> (Maybe ProcessId -> Reactive ())
                      -> Maybe ProcessId
                      -> ProcessId
                      -> HAEvent [ByteString]
                      -> Process ()
observeProcessHAEvent rg push_override mRC sender ev = do
  updateStateWith rg $ $(mkClosure 'addSerializedEvent) ev
  selfNode <- getSelfNode
  case mRC of
     -- I know where the RC is.
     Just rc -> do
        send sender (selfNode, processNodeId rc)
        sendHAEvent rc ev
     -- I don't know where the RC is.
     Nothing -> do
       -- See if we can learn it by looking at the replicated state.
       (newMRC, _) <- getState rg
       case newMRC of
         Just rc -> do
           _ <- monitor rc
           send sender (selfNode, processNodeId rc)
           sendHAEvent rc ev
           -- Send my own node when we don't know the RC
           -- location. Note that I was able to read the
           -- replicated state so very likely there is no RC.
         Nothing -> do
           n <- getSelfNode
           send sender (n, n)
       liftIO $ void $ forkIO $ sync $ push_override newMRC
