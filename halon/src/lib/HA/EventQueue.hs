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
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE TemplateHaskell    #-}
{-# LANGUAGE TypeOperators      #-}
module HA.EventQueue
  ( EventQueue
  , __remoteTable
  , eventQueueLabel
  , RCDied(..)
  , RCLost(..)
  , TrimDone(..)
  , TrimAck(..)
  , RecordAck(..)
  , NewRCAck(..)
  , RCDiedAck(..)
  , monitoring
  , recordNewRC
  , recordRCDied
  , recordEvent
  , sendEventsToRC
  , sendEventToRC
  , reconnectToRC
  , trim
  , lookupRC
  , sendOwnNode
  , makeEventQueueFromRules
  ) where

import Prelude hiding ((.), id)

import GHC.Generics

import HA.EventQueue.Consumer
import HA.EventQueue.Types
import HA.Replicator ( RGroup, updateStateWith, getState)
import Control.SpineSeq (spineSeq)
import FRP.Netwire hiding (Last(..), when)

import Control.Distributed.Process hiding (newChan, send)
import Control.Distributed.Process.Async (async, task)
import Control.Distributed.Process.Closure ( remotable, mkClosure )
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Timeout ( retry )
import Control.Monad.State

import Data.Binary (Binary)
import Data.ByteString ( ByteString )
import Data.Foldable (for_, traverse_)
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

-- | Amount of microseconds between retries of requests for the replicated
-- state
requestTimeout :: Int
requestTimeout = 1000 * 1000

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
makeEventQueueFromRules :: RGroup g
                        => g EventQueue
                        -> RuleM (Maybe ProcessId) ()
                        -> Process ()
makeEventQueueFromRules rg rm = do
    self <- getSelfPid
    register eventQueueLabel self
    (mRC,_) <- retry requestTimeout $ getState rg
    -- The EQ must monitor the RC or it will never realize when the RC stops
    -- responding and won't ever care of checking the replicated state to learn
    -- of new RCs
    traverse_ monitor mRC
    runProcessor mRC rm

monitoring :: ProcessId -> CEP s ()
monitoring rc = do
    _ <- liftProcess $ monitor rc
    return ()

-- | Record in the replicated state that there is a new RC.
recordNewRC :: RGroup g => g EventQueue -> ProcessId -> CEP (Maybe ProcessId) ()
recordNewRC rg rc = liftProcess $ do
    self <- getSelfPid
    _    <- async $ task $ do
      retry requestTimeout $ updateStateWith rg $ $(mkClosure 'setRC) $ Just rc
      usend self (NewRCAck rc)
    return ()

-- | Send the pending events to the new RC.
sendEventsToRC :: RGroup g => g EventQueue -> ProcessId -> CEP s ()
sendEventsToRC rg rc = liftProcess $ do
    self               <- getSelfPid
    (_, pendingEvents) <- retry requestTimeout $ getState rg
    for_ (reverse pendingEvents) $ \ev ->
      usend rc ev{eventHops = self : eventHops ev}

reconnectToRC :: CEP (Maybe ProcessId) ()
reconnectToRC = liftProcess . traverse_ reconnect =<< get

recordRCDied :: RGroup g => g EventQueue -> CEP (Maybe ProcessId) ()
recordRCDied rg = do
    mRC <- get
    let upd = (mRC, Nothing :: Maybe ProcessId)

    _ <- liftProcess $ do
      self <- getSelfPid
      _    <- async $ task $ retry requestTimeout $
                updateStateWith rg $ $(mkClosure 'compareAndSwapRC) upd
      usend self RCDiedAck
    return ()

recordEvent :: RGroup g
            => g EventQueue
            -> ProcessId
            -> HAEvent [ByteString]
            -> CEP s ()
recordEvent rg sender ev = do
    _ <- liftProcess $ do
      self <- getSelfPid
      _    <- async $ task $ do
        retry requestTimeout $
          updateStateWith rg $ $(mkClosure 'addSerializedEvent) ev
      usend self (RecordAck sender ev)
    return ()

trim :: RGroup g => g EventQueue -> EventId -> CEP s ()
trim rg eid =
    liftProcess $ do
      self <- getSelfPid
      _ <- async $ task $ do
        retry requestTimeout $
          updateStateWith rg $ $(mkClosure 'filterEvent) eid
        usend self (TrimAck eid)
      return ()

sendEventToRC :: ProcessId -> ProcessId -> HAEvent [ByteString] -> CEP s ()
sendEventToRC rc sender ev =
    liftProcess $ do
      selfNode <- getSelfNode
      usend sender (selfNode, processNodeId rc)
      sendHAEvent rc ev

-- | See if we can learn it by looking at the replicated state.
lookupRC :: RGroup g => g EventQueue -> CEP s (Maybe ProcessId)
lookupRC rg = do
    (newMRC, _) <- liftProcess $ retry requestTimeout $ getState rg
    return newMRC

-- | Send my own node when we don't know the RC location. Note that I was able
--   to read the replicated state so very likely there is no RC.
sendOwnNode :: ProcessId -> CEP s ()
sendOwnNode sender = liftProcess $ do
    n <- getSelfNode
    usend sender (n, n)

data RCDied = RCDied deriving (Show, Typeable, Generic)

instance Binary RCDied

data RCLost = RCLost deriving (Show, Typeable, Generic)

instance Binary RCLost

data TrimDone = TrimDone EventId deriving (Typeable, Generic)

instance Binary TrimDone

data TrimAck = TrimAck EventId deriving (Typeable, Generic)

instance Binary TrimAck

data RecordAck = RecordAck ProcessId (HAEvent [ByteString])
                 deriving (Typeable, Generic)

instance Binary RecordAck

data NewRCAck = NewRCAck ProcessId deriving (Typeable, Generic)

instance Binary NewRCAck

data RCDiedAck = RCDiedAck deriving (Typeable, Generic)

instance Binary RCDiedAck
