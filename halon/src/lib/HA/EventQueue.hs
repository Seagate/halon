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
  , EventQueueState
  , startEventQueue
  ) where

import Prelude hiding ((.), id)

import GHC.Generics

import HA.EventQueue.Types
import HA.Replicator ( RGroup, updateStateWith, getState)
import Control.SpineSeq (spineSeq)
import FRP.Netwire hiding (Last(..), when, for)

import Control.Distributed.Process hiding (newChan)
import Control.Distributed.Process.Closure ( remotable, mkClosure )
import Control.Distributed.Process.Timeout ( retry )

import Control.Monad (when)
import Data.Binary (Binary)
import Data.Foldable (for_, traverse_)
import Data.Functor (void)
import Data.Traversable (for)
import Data.Typeable

import Network.CEP
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)


-- | Since there is at most one Event Queue per tracking station node,
-- the @eventQueueLabel@ is used to register and lookup the Event Queue of a
-- node.
eventQueueLabel :: String
eventQueueLabel = "HA.EventQueue"

eqTrace :: String -> Process ()
-- eqTrace _ = return ()
eqTrace msg = do
    let b = unsafePerformIO $
              maybe False (elem "EQ" . words)
                <$> lookupEnv "HALON_TRACING"
    when b $ say $ "[EQ] " ++ msg
-- eqTrace = say . ("[EQ] " ++)
-- eqTrace msg = do
--     self <- getSelfPid
--     liftIO $ hPutStrLn stderr $ show self ++ ": [EQ] " ++ msg

-- | State of the event queue.
--
-- It contains the process id of the RC and the list of pending events.
type EventQueue = (Maybe ProcessId, [PersistMessage])

data EventQueueState =
    EventQueueState
    { _eqsRC  :: !ProcessId
      -- ^ Recovery Coordinator 'ProcessId'
    , _eqsRef :: !MonitorRef
      -- ^ Resulted 'MonitorRef' from monitoring RC 'Process'
    }

addSerializedEvent :: PersistMessage -> EventQueue -> EventQueue
addSerializedEvent = second . (:)

eqSetRC :: Maybe ProcessId -> EventQueue -> EventQueue
eqSetRC = first . const

-- | "compare and swap" for updating the RC
compareAndSwapRC :: (Maybe ProcessId, Maybe ProcessId) -> EventQueue -> EventQueue
compareAndSwapRC (expected, new) = first $ \current ->
    if current == expected then new else current

filterEvent :: UUID -> EventQueue -> EventQueue
filterEvent eid = second $ spineSeq . filter (\(PersistMessage uuid _) -> eid /= uuid)

remotable [ 'addSerializedEvent
          , 'eqSetRC
          , 'compareAndSwapRC
          , 'filterEvent
          ]

-- | Amount of microseconds between retries of requests for the replicated
-- state
requestTimeout :: Int
requestTimeout = 1000 * 1000

-- | @startsEventQueue rg@ starts an event queue.
--
-- @rg@ is the replicator group used to store the events until RC handles them.
-- Returns the process identifier of the event queue.
--
-- When an RC is spawned, its pid should be sent to the colocated EQ which will
-- record the pid in the replicated state so it is available to other EQs.
--
-- When the EQ receives an event, it will replicate the event, acknowledge it
-- back to the reporter, and report it to the RC. If the EQ doesn't know where
-- the RC is, it will try to learn it from the replicated state.
--
startEventQueue :: RGroup g => g EventQueue -> Process ProcessId
startEventQueue rg = do
    eq <- spawnLocal $ do
      (mRC,_) <- retry requestTimeout $ getState rg
      -- The EQ must monitor the RC or it will never realize when the RC stops
      -- responding and won't ever care of checking the replicated state to learn
      -- of new RCs
      st <- for mRC $ \pid -> fmap (EventQueueState pid) $ monitor pid
      execute st $ eqRules rg
    register eventQueueLabel eq
    return eq

eqRules :: RGroup g => g EventQueue -> Definitions (Maybe EventQueueState) ()
eqRules rg = do
    defineSimple "rc-spawned" $ \rc -> do
      recordNewRC rg rc
      setRC rc
      sendEventsToRC rg rc

    defineSimple "monitoring" $ \(ProcessMonitorNotification _ pid reason) -> do
      mRC <- getRC
      -- Check the identity of the process in case the
      -- notifications get mixed for old and new RCs.
      when (Just pid == mRC) $
        case reason of
          -- The connection to the RC failed.
          DiedDisconnect -> do
            publish RCLost
          -- The RC died.
          _              -> do recordRCDied rg
                               publish RCDied
                               clearRC

    defineSimple "trimming" (trim rg)

    defineSimple "ha-event" $ \(sender, ev) -> do
      mRC  <- lookupRC rg
      here <- liftProcess getSelfNode
      case mRC of
        Just rc | here /= processNodeId rc
          -> -- Delegate on the colocated EQ.
             -- The colocated EQ learns immediately of the RC death. This
             -- ensures events are not sent to a defunct RC rather than to a
             -- live one.
             liftProcess $ do
               nsendRemote (processNodeId rc) eventQueueLabel
                           (sender, ev)
        _ -> -- Record the event if there is no known RC or if it is colocated.
             recordEvent rg sender ev

    defineSimple "trim-ack" $ \(TrimAck eid) -> publish (TrimDone eid)

    defineSimple "record-ack" $ \(RecordAck sender ev) -> do
      mRC <- lookupRC rg
      case mRC of
        Just rc -> sendEventToRC rc sender ev
        Nothing -> sendOwnNode sender

setRC :: ProcessId -> PhaseM (Maybe EventQueueState) l ()
setRC rc = do
    prevM <- get Global
    ref   <- liftProcess $ do
      traverse_ (unmonitor . _eqsRef) prevM
      monitor rc
    put Global $ Just $ EventQueueState rc ref

clearRC :: PhaseM (Maybe EventQueueState) l ()
clearRC = traverse_ go =<< get Global
  where
    go EventQueueState{..} = do
        liftProcess $ unmonitor _eqsRef
        put Global Nothing

-- | Record in the replicated state that there is a new RC.
recordNewRC :: RGroup g
            => g EventQueue
            -> ProcessId
            -> PhaseM (Maybe EventQueueState) l ()
recordNewRC rg rc = void $ liftProcess $ spawnLocal $
    retry requestTimeout $ updateStateWith rg $ $(mkClosure 'eqSetRC) $ Just rc

-- | Send the pending events to the new RC.
sendEventsToRC :: RGroup g => g EventQueue -> ProcessId -> PhaseM s l ()
sendEventsToRC rg rc = liftProcess $ do
    (_, pendingEvents) <- retry requestTimeout $ getState rg
    for_ (reverse pendingEvents) $ \(PersistMessage mid ev) -> do
      eqTrace $ "EQ: Sending to RC: " ++ show mid
      uforward ev rc

recordRCDied :: RGroup g => g EventQueue -> PhaseM (Maybe EventQueueState) l ()
recordRCDied rg = do
    mRC <- getRC
    -- We use compare and swap to make sure we don't overwrite
    -- the pid of a respawned RC
    void $ liftProcess $ spawnLocal $ retry requestTimeout $
      updateStateWith rg $ $(mkClosure 'compareAndSwapRC) (mRC, Nothing :: Maybe ProcessId)

recordEvent :: RGroup g
            => g EventQueue
            -> ProcessId
            -> PersistMessage
            -> PhaseM s l ()
recordEvent rg sender ev = void $ liftProcess $ do
    self <- getSelfPid
    spawnLocal $ do
      eqTrace $ "EQ: Recording event " ++ show (persistEventId ev)
      retry requestTimeout $
        updateStateWith rg $ $(mkClosure 'addSerializedEvent) ev
      eqTrace $ "EQ: Recorded event " ++ show (persistEventId ev)
      usend self (RecordAck sender ev)

trim :: RGroup g => g EventQueue -> UUID -> PhaseM s l ()
trim rg eid =
    liftProcess $ do
      self <- getSelfPid
      _ <- spawnLocal $ do
        retry requestTimeout $
          updateStateWith rg $ $(mkClosure 'filterEvent) eid
        usend self (TrimAck eid)
      return ()

sendEventToRC :: ProcessId -> ProcessId -> PersistMessage -> PhaseM s l ()
sendEventToRC rc sender (PersistMessage mid ev) =
    liftProcess $ do
      self <- getSelfPid
      eqTrace $ "EQ: Sending to RC (" ++ show rc ++"): " ++ show mid
      usend sender (processNodeId self, processNodeId rc)
      uforward ev rc

-- | Find the RC either in the local state or in the replicated state.
lookupRC :: RGroup g
         => g EventQueue
         -> PhaseM (Maybe EventQueueState) l (Maybe ProcessId)
lookupRC rg = do
    mRC <- getRC
    case mRC of
      Just _ -> return mRC
      Nothing -> do
        (newMRC, _) <- liftProcess $ retry requestTimeout $ getState rg
        for_ newMRC setRC
        return newMRC

getRC :: PhaseM (Maybe EventQueueState) l (Maybe ProcessId)
getRC = fmap (fmap _eqsRC) $ get Global

-- | Send my own node when we don't know the RC location. Note that I was able
--   to read the replicated state so very likely there is no RC.
sendOwnNode :: ProcessId -> PhaseM s l ()
sendOwnNode sender = liftProcess $ do
    n <- getSelfNode
    usend sender (n, n)

data RCDied = RCDied deriving (Show, Typeable, Generic)

instance Binary RCDied

data RCLost = RCLost deriving (Show, Typeable, Generic)

instance Binary RCLost

data TrimDone = TrimDone UUID deriving (Typeable, Generic)

instance Binary TrimDone

data TrimAck = TrimAck UUID deriving (Typeable, Generic)

instance Binary TrimAck

data RecordAck = RecordAck ProcessId PersistMessage
                 deriving (Typeable, Generic)

instance Binary RecordAck
