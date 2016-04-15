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
  ( EventQueue(_eqRC, _eqMap)
  , __remoteTable
  , eventQueueLabel
  , RCDied(..)
  , RCLost(..)
  , TrimDone(..)
  , TrimUnknown(..)
  , EventQueueState
  , startEventQueue
  , emptyEventQueue
  ) where

import Prelude hiding ((.), id)

import GHC.Generics

import HA.EventQueue.Types
import HA.Logger
import HA.Replicator ( RGroup
                     , updateStateWith
                     , getState
                     , retryRGroup
                     , withRGroupMonitoring
                     )
import FRP.Netwire hiding (Last(..), when, for)

import Control.Distributed.Process hiding (newChan, catch)
import Control.Distributed.Process.Closure ( remotable, mkClosure )
import Control.Distributed.Process.Internal.Types (Message(..))

import Control.Monad (when)
import Control.Monad.Catch
import Data.Binary (Binary, encode)
import Data.Foldable (for_, traverse_)
import Data.Function (on)
import Data.Functor (void)
import Data.List
import qualified Data.Map as M
import Data.Traversable (for)
import Data.Typeable
import GHC.Int (Int64)

import Network.CEP

-- | Since there is at most one Event Queue per tracking station node,
-- the @eventQueueLabel@ is used to register and lookup the Event Queue of a
-- node.
eventQueueLabel :: String
eventQueueLabel = "HA.EventQueue"

eqTrace :: String -> Process ()
eqTrace = mkHalonTracer "EQ"

-- | Type used to order messages coming to EQ. Even though
-- 'M.Map' used to store the messages and therefore the EQ can
-- be at most 'Int' sized, messages are removed from EQ when processed
-- while the sequence number is ever growing, so we want something we
-- know is not going to overflow any time soon.
type SequenceNumber = Int64

-- | State of the event queue.
--
-- It contains the process id of the RC, and the map of pending events
-- along with their sequence number.
data EventQueue = EventQueue
  { _eqRC :: Maybe ProcessId
    -- ^ 'ProcessId' of the RC if the RC is running
  , _eqSN :: SequenceNumber
    -- ^ Tracks the ordering of the messages coming in into the
    -- 'EventQueue'. This is used to generate the otherwise-lost
    -- ordering within '_eqMap'.
  , _eqMap :: M.Map UUID (PersistMessage, SequenceNumber)
    -- ^ A map of the messages in the EQ. We keep track of the
    -- messages' 'SequenceNumber', necessary to send the messages to
    -- the RC in the expected order after RC restart. We use a 'Map'
    -- rather than a list to provide quicker removal of messages and
    -- reduce duplicates.
  } deriving (Eq, Ord, Generic, Typeable)

instance Binary EventQueue

-- | Initial state of the 'EventQueue'. No known RC 'ProcessId and no
-- messages.
emptyEventQueue :: EventQueue
emptyEventQueue = EventQueue Nothing 0 M.empty

data EventQueueState =
    EventQueueState
    { _eqsRC  :: !ProcessId
      -- ^ Recovery Coordinator 'ProcessId'
    , _eqsRef :: !MonitorRef
      -- ^ Resulted 'MonitorRef' from monitoring RC 'Process'
    }

-- | Add the given 'PersistMessage' to the EQ if it doesn't already
-- exist.
--
-- @O(log n)@
addSerializedEvent :: PersistMessage -> EventQueue -> EventQueue
addSerializedEvent msg@PersistMessage{..} eq@EventQueue{..} =
  eq { _eqSN = succ _eqSN
     , _eqMap = M.insert persistEventId (msg, _eqSN) _eqMap }

-- | Set a new RC 'ProcessId' in the 'EventQueue'.
eqSetRC :: Maybe ProcessId -> EventQueue -> EventQueue
eqSetRC mpid eq = eq { _eqRC = mpid }

-- | "compare and swap" for updating the RC
--
-- @O(1)@
compareAndSwapRC :: (Maybe ProcessId, Maybe ProcessId)
                 -> EventQueue -> EventQueue
compareAndSwapRC (expected, new) eq@(EventQueue { _eqRC = current }) =
    if current == expected then eq { _eqRC = new } else eq

-- | Remove the message with given 'UUID' from the 'EventQueue'.
--
-- @O(log n)@
filterEvent :: UUID -> EventQueue -> EventQueue
filterEvent eid eq = eq { _eqMap = M.delete eid $ _eqMap eq }

-- | Filter all occurences of the given message inside event queue.
--
-- @O(n)@
filterMessage :: Message -> EventQueue -> EventQueue
filterMessage msg eq =
  eq { _eqMap = M.mapMaybe checkEquality $ _eqMap eq }
  where
    (bfgp,benc) = case msg of
       EncodedMessage f e -> (f,e)
       UnencodedMessage f p -> (f, encode p)
    checkEquality (m@(PersistMessage uuid msg'), i) =
      case msg' of
        EncodedMessage f e
           | f == bfgp && e == benc -> Nothing
           | otherwise -> Just (m, i)
        UnencodedMessage f p ->
           let enc = encode p
           in if f == bfgp && enc == benc
                then Nothing
                else Just ((PersistMessage uuid (EncodedMessage f enc)), i)

remotable [ 'addSerializedEvent
          , 'eqSetRC
          , 'compareAndSwapRC
          , 'filterEvent
          , 'filterMessage
          ]

-- | Amount of microseconds between retries of requests for the replicated
-- state
requestTimeout :: Int
requestTimeout = 5 * 1000 * 1000

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
      EventQueue { _eqRC = mRC } <- retryRGroup rg requestTimeout $ getState rg
      -- The EQ must monitor the RC or it will never realize when the RC stops
      -- responding and won't ever care of checking the replicated state to learn
      -- of new RCs
      st <- for mRC $ \pid -> fmap (EventQueueState pid) $ monitor pid
      eqTrace "Started"
      execute st $ eqRules rg
      eqTrace "Terminated"
     `catch` \e -> do
      eqTrace $ "Dying with " ++ show e
      throwM (e :: SomeException)
    register eventQueueLabel eq
    return eq

eqRules :: RGroup g => g EventQueue -> Definitions (Maybe EventQueueState) ()
eqRules rg = do
    defineSimple "rc-spawned" $ \rc -> do
      -- Record the new RC pid in the replicated state.
      liftProcess $ spawnLocal $
        retryRGroup rg requestTimeout $ fmap bToM $
          updateStateWith rg $ $(mkClosure 'eqSetRC) $ Just rc
      setRC rc
      -- Send pending events to the new RC.
      liftProcess $ do
        eqTrace "sendEventsToRC"
        EventQueue { _eqMap = evs } <- retryRGroup rg requestTimeout $ getState rg
        let pendingEvents = map fst . sortBy (compare `on` snd) $ M.elems evs
        eqTrace $ "sendEventsToRC: " ++ show (length pendingEvents)
        for_ pendingEvents $ \(PersistMessage mid ev) -> do
          eqTrace $ "EQ: Sending to RC: " ++ show mid
          uforward ev rc

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
    defineSimple "trimming-unknown" $ \(DoTrimUnknown msg) -> trimMsg rg msg

    defineSimple "ha-event" $ \(sender, ev@(PersistMessage mid _)) -> do
      mRC  <- lookupRC rg
      liftProcess $ do
        here <- getSelfNode
        case mRC of
          Just (Just rc) | here /= processNodeId rc -> do
            -- Delegate on the colocated EQ.
            -- The colocated EQ learns immediately of the RC death. This
            -- ensures events are not sent to a defunct RC rather than to a
            -- live one.
            eqTrace $ "EQ: Forwarding event " ++
                      show (mid, processNodeId rc, sender)
            nsendRemote (processNodeId rc) eventQueueLabel
                        (sender, ev)
            sendReply sender $ Left $ processNodeId rc
          Just _ -> do
            -- Record the event if there is no known RC or if it is colocated.
            self <- getSelfPid
            void $ spawnLocal $ do
              eqTrace $ "EQ: Recording event " ++ show mid
              res <- withRGroupMonitoring rg $
                updateStateWith rg $ $(mkClosure 'addSerializedEvent) ev
              case res of
                Just True -> do
                  eqTrace $ "EQ: Recorded event " ++ show mid
                  usend self (RecordAck sender ev)
                _ -> do
                  eqTrace $ "EQ: Recording event failed " ++ show (mid, sender)
                  sendReply sender $ Left here
          _ -> do
            -- No quorum
            eqTrace $ "EQ: No quorum " ++ show (mid, sender)
            sendReply sender $ Left here


    defineSimple "trim-ack" $ \(TrimAck eid) -> publish (TrimDone eid)
    defineSimple "trim-ack-unknown" $ \(TrimUnknown _) -> return ()
    defineSimple "record-ack" $ \(RecordAck sender (PersistMessage mid ev)) ->
      do mRC <- lookupRC rg
         liftProcess $ case mRC of
           Just (Just rc) -> do
             eqTrace $ "EQ: Sending to RC (" ++ show rc ++"): " ++ show (mid, sender)
             sendReply sender $ Right $ processNodeId rc
             uforward ev rc
           _ -> do
             -- Send my own node when we don't know the RC location.
             getSelfNode >>= sendReply sender . Right

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

bToM :: Bool -> Maybe ()
bToM True  = Just ()
bToM False = Nothing

recordRCDied :: RGroup g => g EventQueue -> PhaseM (Maybe EventQueueState) l ()
recordRCDied rg = do
    mRC <- getRC
    -- We use compare and swap to make sure we don't overwrite
    -- the pid of a respawned RC
    void $ liftProcess $ spawnLocal $ retryRGroup rg requestTimeout $
      fmap bToM $ updateStateWith rg $ $(mkClosure 'compareAndSwapRC)
                                   (mRC, Nothing :: Maybe ProcessId)

sendReply :: ProcessId -> Either NodeId NodeId -> Process ()
sendReply sender reply = do here <- getSelfNode
                            usend sender (here, reply)

trim :: RGroup g => g EventQueue -> UUID -> PhaseM s l ()
trim rg eid =
    liftProcess $ do
      self <- getSelfPid
      _ <- spawnLocal $ do
        retryRGroup rg requestTimeout $ fmap bToM $
          updateStateWith rg $ $(mkClosure 'filterEvent) eid
        usend self (TrimAck eid)
      return ()

-- | Remove message of unknown type. It's important that all
-- messages with similar layout (fingerprint and encoding) will
-- be removed.
trimMsg :: RGroup g => g EventQueue -> Message -> PhaseM s l ()
trimMsg rg msg =
    liftProcess $ do
      self <- getSelfPid
      _ <- spawnLocal $ do
        retryRGroup rg requestTimeout $ fmap bToM $
          updateStateWith rg $ $(mkClosure 'filterMessage) msg
        usend self (TrimUnknown msg)
      return ()

-- | Find the RC either in the local state or in the replicated state.
--
-- Returns @Nothing@ if we cannot read the replicated state.
--
lookupRC :: RGroup g
         => g EventQueue
         -> PhaseM (Maybe EventQueueState) l (Maybe (Maybe ProcessId))
lookupRC rg = do
    mRC <- getRC
    case mRC of
      Just _ -> return $ Just mRC
      Nothing -> do
        liftProcess $ eqTrace "lookupRC"
        mr <- liftProcess $ withRGroupMonitoring rg $ getState rg
        liftProcess $ eqTrace $ "lookupRC: " ++ show (fmap (fmap _eqRC) mr)
        case mr of
          Just (Just (EventQueue { _eqRC = newMRC })) -> do
            for_ newMRC setRC
            return $ Just newMRC
          _ -> return Nothing

getRC :: PhaseM (Maybe EventQueueState) l (Maybe ProcessId)
getRC = fmap (fmap _eqsRC) $ get Global

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

-- | Request EQ to remove message of type that is unknown.
data TrimUnknown = TrimUnknown Message deriving (Typeable, Generic)

instance Binary TrimUnknown
