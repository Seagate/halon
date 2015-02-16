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
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE TemplateHaskell    #-}
{-# LANGUAGE TypeOperators      #-}
module HA.EventQueue
  ( eventQueue
  , EventQueue
  , __remoteTable
  , eventQueueLabel
  , RCDied(..)
  , RCLost(..)
  ) where

import Prelude hiding ((.), id)

import GHC.Generics

import HA.EventQueue.Consumer
import HA.EventQueue.Types
import HA.Replicator ( RGroup, updateStateWith, getState)
import Control.SpineSeq (spineSeq)
import FRP.Netwire hiding (Last(..), when)

import Control.Distributed.Process hiding (newChan, send)
import Control.Distributed.Process.Closure ( remotable, mkClosure )
import Control.Distributed.Process.Serializable

import Data.Binary
import Data.ByteString ( ByteString )
import Data.Foldable (for_, traverse_)
import Data.Monoid (Last(..))
import Data.Typeable
import Network.CEP

-- | Since there is at most one Event Queue per tracking station node,
-- the @eventQueueLabel@ is used to register and lookup the Event Queue of a
-- node.
eventQueueLabel :: String
eventQueueLabel = "HA.EventQueue"

-- | Send HAEvent and provide information about current process.
sendHAEvent :: Serializable a => ProcessId -> HAEvent a -> Process ()
sendHAEvent next ev = do pid <- getSelfPid
                         usend next ev{eventHops = pid : eventHops ev}

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
  self <- getSelfPid
  register eventQueueLabel self

  (mRC,_) <- getState rg

  -- The EQ must monitor the RC or it will never realize when the RC stops
  -- responding and won't ever care of checking the replicated state to learn
  -- of new RCs
  traverse_ monitor mRC
  runProcessor eventqueueDefinitions (network rg) (Last mRC)

eventqueueDefinitions :: ProcessId                         .+.
                         ProcessMonitorNotification        .+.
                         EventId                           .+.
                         (ProcessId, HAEvent [ByteString]) .+.
                         Nil
eventqueueDefinitions = Ask

network :: RGroup g
        => g EventQueue
        -> ComplexEvent (Last ProcessId) Input (Last ProcessId)
network rg = rcSpawned rg     <|>
             processDied rg   <|>
             eventHandled rg  <|>
             eventAppeared rg

-- | A local RC has been spawned.
rcSpawned :: RGroup g
          => g EventQueue
          -> ComplexEvent (Last ProcessId) Input (Last ProcessId)
rcSpawned rg = repeatedly go . decoded
  where
    go _ rc = liftProcess $ do
        _ <- monitor rc
        -- Record in the replicated state that there is a new RC.
        updateStateWith rg $ $(mkClosure 'setRC) $ Just rc
        -- Send the pending events to the new RC.
        self <- getSelfPid
        (_, pendingEvents) <- getState rg
        for_ (reverse pendingEvents) $ \ev ->
          usend rc ev{eventHops = self : eventHops ev}
        return $ Last $ Just rc

processDied :: RGroup g
            => g EventQueue
            -> ComplexEvent (Last ProcessId) Input (Last ProcessId)
processDied rg = repeatedly go . decoded
  where
    go mRC (ProcessMonitorNotification _ pid reason) = do
        -- Check the identity of the process in case the
        -- notifications get mixed for old and new RCs.
        if Just pid == (getLast mRC)
          then
            case reason of
              -- The connection to the RC failed.
              -- Call reconnect to say it is ok to connect again.
              DiedDisconnect -> do
                liftProcess $ traverse_ reconnect $ getLast mRC
                publish RCLost
                return mRC
              -- The RC died.
              -- We use compare and swap to make sure we don't overwrite
              -- the pid of a respawned RC
              _ -> do
                let upd = (getLast mRC, Nothing :: Maybe ProcessId)

                liftProcess $
                  updateStateWith rg $ $(mkClosure 'compareAndSwapRC) upd
                publish RCDied
                return $ Last Nothing
           else return mRC

-- | The RC handled the event with the given id.
eventHandled :: RGroup g
             => g EventQueue
             -> ComplexEvent (Last ProcessId) Input (Last ProcessId)
eventHandled rg = repeatedly go . decoded
  where
    go mRC (eid :: EventId) = liftProcess $ do
        updateStateWith rg $ $(mkClosure 'filterEvent) eid
        say "Trim done."
        return mRC

eventAppeared :: RGroup g
              => g EventQueue
              -> ComplexEvent (Last ProcessId) Input (Last ProcessId)
eventAppeared rg = repeatedly go . decoded
  where
    go mRC ((sender, ev) :: (ProcessId, HAEvent [ByteString])) = do
        liftProcess $ updateStateWith rg $ $(mkClosure 'addSerializedEvent) ev
        selfNode <- liftProcess getSelfNode
        case getLast mRC of
          -- I know where the RC is.
          Just rc -> liftProcess $ do
            usend sender (selfNode, processNodeId rc)
            sendHAEvent rc ev
            return mRC
          -- I don't know where the RC is.
          Nothing -> do
            -- See if we can learn it by looking at the replicated state.
            (newMRC, _) <- liftProcess $ getState rg
            liftProcess $ do
              case newMRC of
                Just rc -> do
                  _ <- monitor rc
                  usend sender (selfNode, processNodeId rc)
                  sendHAEvent rc ev
                -- Send my own node when we don't know the RC
                -- location. Note that I was able to read the
                -- replicated state so very likely there is no RC.
                Nothing -> do
                  n <- getSelfNode
                  usend sender (n, n)
              return $ Last newMRC

data RCDied = RCDied deriving (Show, Typeable, Generic)

instance Binary RCDied

data RCLost = RCLost deriving (Show, Typeable, Generic)

instance Binary RCLost
