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
-- station or in the RC, the Event Queue can send the unhandled events to
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
  ( EventQueue(_eqMap)
  , __remoteTable
  , eventQueueLabel
  , TrimDone(..)
  , TrimUnknown(..)
  , startEventQueue
  , emptyEventQueue
  ) where


import HA.EventQueue.Types
import HA.Logger
import HA.Replicator ( RGroup
                     , getStateWith
                     , updateStateWith
                     , retryRGroup
                     , withRGroupMonitoring
                     )

import Control.Distributed.Process hiding (newChan, catch, finally)
import Control.Distributed.Process.Closure ( remotable, mkClosure )
import Control.Distributed.Process.Internal.Types (Message(..))
import Network.CEP hiding (continue)

import Control.Monad (join, when)
import Control.Monad.Catch
import Data.Binary (Binary, encode)
import Data.Foldable (forM_)
import Data.Function (fix)
import Data.Functor (void)
import Data.Int (Int64)
import Data.IORef (IORef, atomicModifyIORef, newIORef)
import qualified Data.Map as M
import Data.Sequence as Seq
import Data.Typeable
import Data.Word (Word64)
import GHC.Generics
import System.Clock


-- | Since there is at most one Event Queue per tracking station node,
-- the @eventQueueLabel@ is used to register and lookup the Event Queue of a
-- node.
eventQueueLabel :: String
eventQueueLabel = "HA.EventQueue"

-- | Tells how many microseconds to wait between polls of the replicated state
-- for new events.
--
-- Events are sent to the RC when the poller finds them.
--
-- When the replicator group is busy, the polling delay may be larger because
-- the requests may take longer to be served. This is the delay when the group
-- is moslty idle.
--
minimumPollingDelay :: Int
minimumPollingDelay = 1000000

eqTrace :: String -> Process ()
eqTrace = mkHalonTracer "EQ"

-- | Type used to order messages coming to EQ. Even though
-- 'M.Map' used to store the messages and therefore the EQ can
-- be at most 'Int' sized, messages are removed from EQ when processed
-- while the sequence number is ever growing, so we want something we
-- know is not going to overflow any time soon.
type SequenceNumber = Word64

-- | State of the event queue.
--
-- It contains the map of pending events along with their sequence number.
data EventQueue = EventQueue
  { _eqSN :: !SequenceNumber
    -- ^ Tracks the ordering of the messages coming in into the
    -- 'EventQueue'. This is used to generate the otherwise-lost
    -- ordering within '_eqMap'. It also helps identifying new events
    -- that haven't been sent to the RC yet.
  , _eqMap :: M.Map UUID (PersistMessage, SequenceNumber)
    -- ^ A map of the messages in the EQ. We keep track of the
    -- messages' 'SequenceNumber', necessary to remove the messages from
    -- the sequence number map. We use a 'Map' rather than a list to provide
    -- quicker removal of messages and reduce duplicates.
  , _eqSnMap :: M.Map SequenceNumber UUID
    -- ^ A reverse map for efficient polling of new events.
  } deriving (Eq, Ord, Generic, Typeable)

instance Binary EventQueue

-- | Initial state of the 'EventQueue'. No known RC 'ProcessId and no
-- messages.
emptyEventQueue :: EventQueue
emptyEventQueue = EventQueue 0 M.empty M.empty

data EventQueueState = EventQueueState

-- | Add the given 'PersistMessage' to the EQ if it doesn't already
-- exist.
--
-- @O(log n)@
addSerializedEvent :: PersistMessage -> EventQueue -> EventQueue
addSerializedEvent msg@PersistMessage{..} eq@EventQueue{..} =
  eq { _eqSN = succ _eqSN
     , _eqMap = M.insert persistEventId (msg, _eqSN) _eqMap
     , _eqSnMap = M.insert _eqSN persistEventId _eqSnMap
     }

-- | Remove the message with given 'UUID' from the 'EventQueue'.
--
-- @O(log n)@
filterEvent :: UUID -> EventQueue -> EventQueue
filterEvent eid eq =
    let (me, uuidMap') = M.updateLookupWithKey (\_ _ -> Nothing) eid (_eqMap eq)
     in eq { _eqMap = uuidMap'
           , _eqSnMap = maybe id (M.delete . snd) me $ _eqSnMap eq
           }

-- | Filter all occurences of the given message inside event queue.
--
-- @O(n)@
filterMessage :: Message -> EventQueue -> EventQueue
filterMessage msg eq =
    eq { _eqMap   = keep
       , _eqSnMap = M.foldr (\(_, sn) b -> M.delete sn b) (_eqSnMap eq) remove
       }
  where
    (keep, remove) = M.mapEither equalEncoding $ _eqMap eq

    (bfgp,benc) = case msg of
       EncodedMessage f e -> (f,e)
       UnencodedMessage f p -> (f, encode p)
    equalEncoding p@(PersistMessage uuid msg', i) =
      case msg' of
        EncodedMessage f e
           | f == bfgp && e == benc -> Right p
           | otherwise -> Left p
        UnencodedMessage f v ->
           let enc = encode v
           in if f == bfgp && enc == benc
                then Right p
                else Left ((PersistMessage uuid (EncodedMessage f enc)), i)

-- | @eqReadEvents (eq, sn)@ sends the current sequence number and all events
-- from @sn@ onwards to @eq@.
eqReadEvents :: (ProcessId, Word64) -> EventQueue -> Process ()
eqReadEvents (eq, sn) (EventQueue sn' uuidMap snMap) = do
    let (_, muuid, evs) = M.splitLookup sn snMap
    eqTrace $ "Polling state " ++ show (sn, sn', muuid)
    usend eq (sn', [ m | uuid <- maybe id (:) muuid $ M.elems evs
                       , Just (m, _) <- [M.lookup uuid uuidMap]
                   ]
             )

remotable [ 'addSerializedEvent
          , 'filterEvent
          , 'filterMessage
          , 'eqReadEvents
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
      pool <- newProcessPool 50
      self <- getSelfPid
      -- Spawn the initial monitor proxy. See Note [RGroup monitor].
      rgMonitor <- spawnLocal $ link self >> rGroupMonitor rg
      eqTrace $ "Started " ++ show rgMonitor
      void $ monitor rgMonitor
      execute (EventQueueState (Just rgMonitor) Set.empty) $ eqRules rg pool
      eqTrace "Terminated"
     `catch` \e -> do
      eqTrace $ "Dying with " ++ show e
      throwM (e :: SomeException)
    register eventQueueLabel eq
    return eq

eqRules :: RGroup g
        => g EventQueue -> ProcessPool -> Definitions EventQueueState ()
eqRules rg pool = do
    defineSimple "rc-spawned" $ \rc -> liftProcess $ do
      -- Poll the replicated state for the RC.
      pid <- spawnLocal $ handle
        (\e -> eqTrace $ "Poller died: " ++ show (e :: SomeException)) $ do
        link rc
        self <- getSelfPid
        flip fix (0 :: Word64) $ \loop sn -> do
          t0 <- liftIO $ getTime Monotonic
          (sn', ms) <- retryRGroup rg requestTimeout $ do
            b <- getStateWith rg $ $(mkClosure 'eqReadEvents) (self, sn)
            if b then fmap Just expect else return Nothing
          forM_ (ms :: [PersistMessage]) $ \(PersistMessage mid ev) -> do
            eqTrace $ "Sending to RC: " ++ show mid
            uforward ev rc
          tf <- liftIO $ getTime Monotonic
          -- Wait if any time remains to reach the minimum polling delay.
          let timeSpecToMicro :: TimeSpec -> Int64
              timeSpecToMicro (TimeSpec s ns) = s * 1000000 + ns `div` 1000
              elapsed   = timeSpecToMicro (tf -t0)
              remaining = fromIntegral minimumPollingDelay - elapsed
          when (remaining > 0) $
            void $ receiveTimeout (fromIntegral remaining) []
          loop sn'
      eqTrace $ "Spawned poller " ++ show (rc, pid)

    defineSimple "trimming" $ \eid -> liftProcess $ do
      self <- getSelfPid
      (mapM_ (void . spawnLocal) =<<) $ submitTask pool $ do
        retryRGroup rg requestTimeout $ fmap bToM $
          updateStateWith rg $ $(mkClosure 'filterEvent) eid
        usend self (TrimAck eid)

    defineSimple "trimming-unknown" $ \(DoTrimUnknown msg) -> trimMsg rg msg

    defineSimple "ha-event" $ \(sender, ev@(PersistMessage mid _)) ->
      liftProcess $ (mapM_ (void . spawnLocal) =<<) $ submitTask pool $ do
        eqTrace $ "Recording event " ++ show mid
        res <- withRGroupMonitoring rg $
          updateStateWith rg $ $(mkClosure 'addSerializedEvent) ev
        case res of
          Just True -> do
            eqTrace $ "Recorded event " ++ show mid
            sendReply sender True
          _ -> do
            eqTrace $ "Recording event failed " ++ show (mid, sender)
            sendReply sender False

    defineSimple "trim-ack" $ \(TrimAck eid) -> publish (TrimDone eid)
    defineSimple "trim-ack-unknown" $ \(TrimUnknown _) -> return ()

bToM :: Bool -> Maybe ()
bToM True  = Just ()
bToM False = Nothing

sendReply :: ProcessId -> Bool -> Process ()
sendReply sender reply = do here <- getSelfNode
                            usend sender (here, reply)

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

data TrimDone = TrimDone UUID deriving (Typeable, Generic)

instance Binary TrimDone

data TrimAck = TrimAck UUID deriving (Typeable, Generic)

instance Binary TrimAck

-- | Request EQ to remove message of type that is unknown.
data TrimUnknown = TrimUnknown Message deriving (Typeable, Generic)

instance Binary TrimUnknown

--------------------------------------------
-- A pool of processes to handle requests
--------------------------------------------

-- | A pool of worker processes that execute tasks.
--
-- It is restricted to produce only a limited amount of workers.
--
newtype ProcessPool = ProcessPool (IORef PoolState)

data PoolState = PoolState
    { psLimit :: Int  -- ^ Maximum amount of workers that will be created.
    , psCount :: Int  -- ^ Amount of running workers.
    , psQueue :: Seq (Process ()) -- ^ The queue of tasks.
    }

-- | Creates a new pool with the given limit for the amount of workers.
newProcessPool :: Int -> Process ProcessPool
newProcessPool limit =
  fmap ProcessPool $ liftIO $ newIORef $ PoolState limit 0 Seq.empty

-- | @submitTask pool task@ submits a task to the pool.
--
-- If there are more workers than the limit, then @submitTask@ yields @Nothing@
-- and the task is queued until the first worker becomes available.
--
-- If there are less workers than the limit, then @submitTask@ yields
-- @Just worker@ where @worker@ is the worker that will execute the task and
-- possibly other tasks submitted later. Callers will likely want to run
-- @worker@ in a newly spawned thread.
--
submitTask :: ProcessPool -> Process () -> Process (Maybe (Process ()))
submitTask (ProcessPool ref) t =
    liftIO $ atomicModifyIORef ref $ \ps@(PoolState {..}) ->
      if psCount < psLimit then
        ( PoolState psLimit (succ psCount) psQueue
        , Just ((t >> continue) `finally` terminate)
        )
      else
        (ps { psQueue = psQueue |> t}, Nothing)
  where
    continue :: Process ()
    continue = join $ liftIO $ atomicModifyIORef ref $ \ps@(PoolState {..}) ->
      case viewl psQueue of
        EmptyL -> (ps, return ())
        next :< s -> (ps { psQueue = s}, next >> continue)

    terminate :: Process ()
    terminate = liftIO $ atomicModifyIORef ref $ \ps ->
      (ps { psCount = pred (psCount ps) }, ())
