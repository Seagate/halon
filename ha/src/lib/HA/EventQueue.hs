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

{-# LANGUAGE TemplateHaskell #-}
module HA.EventQueue
  ( eventQueue, EventQueue, __remoteTable, eventQueueLabel ) where

import HA.Call ( callResponse )
import HA.EventQueue.Consumer
import HA.EventQueue.Types
import HA.Replicator ( RGroup, updateStateWith, getState)

import Control.Distributed.Process
import Control.Distributed.Process.Closure ( remotable, mkClosure )

import Data.ByteString ( ByteString )

-- | Since there is at most one Event Queue per tracking station node,
-- the @eventQueueLabel@ is used to register and lookup the Event Queue of a
-- node.
eventQueueLabel :: String
eventQueueLabel = "HA.EventQueue"

-- | State of the event queue
type EventQueue = [HAEvent [ByteString]]

-- | @forceSpine xs@ evaluates the spine of @xs@.
forceSpine :: [a] -> [a]
forceSpine [] = []
forceSpine xs@(_:xs') = forceSpine xs' `seq` xs

addSerializedEvent :: HAEvent [ByteString] -> EventQueue -> EventQueue
addSerializedEvent = (:)

filterEvent :: EventId -> EventQueue -> EventQueue
filterEvent eid = forceSpine . filter (\HAEvent{..} -> eid /= eventId)

remotable [ 'addSerializedEvent, 'filterEvent ]

-- | @eventQueue rg rc@ starts an event queue for sending events to the
-- Recovery Coordinator @rc@. @rg@ is the replicator group used to store the
-- events until RC handles them.
--
-- The event queue is a regular process that accepts any incoming message of
-- any type. All such messages (except messages internal to the event queue)
-- are considered HA events, which are replicated and forwarded to the
-- recovery coordinator.
--
eventQueue :: RGroup g
           => g EventQueue
           -> ProcessId -- ^ Recovery coordinator
           -> Process ()
eventQueue rg rc =
    getSelfPid >>= register eventQueueLabel >>
    getState rg >>= mapM_ (send rc) . reverse >> loop
  where
    loop =
        receiveWait
          [ match $ \(eid :: EventId) -> do
                updateStateWith rg $ $(mkClosure 'filterEvent) eid
                say "Trim done."
                return ()
          , callResponse $ \(ev :: HAEvent [ByteString]) -> do
                send rc ev
                updateStateWith rg $ $(mkClosure 'addSerializedEvent) ev
                return ((), ())
          ] >> loop
