module Mero.Notification.Filter
  ( notificationChannel
  , notificationWorker
  , sentInterval
  , pendingInterval
  , cancelledInterval
  ) where

import qualified HA.Resources.Mero.Note as M0
import Mero.Notification.HAState
import Control.Distributed.Process
import qualified Data.HashPSQ as PSQ
import System.Clock
import Control.Concurrent.STM.TChan (TChan, readTChan, newTChanIO)
import System.IO.Unsafe (unsafePerformIO)

-- | Channel to send notificaitons to the worker.
notificationChannel :: TChan NVec
notificationChannel = unsafePerformIO $ newTChanIO
{-# NOINLINE notificationChannel #-}

-- |
-- Worker that implements notification filtering, that will effectively filter
-- events that were cancelled too fast and merge duplicated events into one.
--
-- Algorithm is applied only to single events with state one of:
-- ONLINE, FAILED, TRANSIENT. All other events are automatically resent to RC.
--
-- Worker embedds priority queue for the incomming messages. Each new event
-- that should be added to queue is added in @Pending@ state and worker gives
-- mero some time to cancel that event.
--
-- In case if message was cancelled or sent it moves to @Cancelled@/@Sent@
-- state appropriatelly. In those states duplicates are filtered out from the
-- queue.
--
-- Life time of the event:
--
-- @@@
--  Init----- Pending ---> Sent-->-+
--             |                   |->-Fini
--            Cancelled ------>----+
-- @@@
--
--
notificationWorker :: TChan NVec -> (NVec -> Process ()) -> Process ()
notificationWorker chan announce = await_event
  where
    -- Wait for the new event when cache is empty.
    await_event = do
      note <- receiveWait [ readNoteMsg ]
      now <- liftIO $ getTime Monotonic
      case note of
        [] -> return ()
        [n@(Note xid state)]
           | state `elem` filteredStates ->
             next_step (PSQ.singleton xid (pendingTime now) (Pending n)) now
        ns -> do announce ns
                 await_event
    -- Wait for the new event or next action.
    -- Invarant: 'tm' should be non-zero, in order to achieve that
    -- await_execute should not be called directly. Use next_step that maintains
    -- invariant.
    await_execute tm !psq = do
      mnote <- receiveTimeout tm [ readNoteMsg ]
      now <- liftIO $ getTime Monotonic
      case mnote of
        Nothing -> -- timeout happened process first messasge from PSQ
          case PSQ.minView psq of
            Nothing -> await_event
            Just (_, _, value, psq') -> execute value now psq'
        Just [] -> next_step psq now
        Just [note@(Note fid state)]
           | state `elem` filteredStates ->
             case PSQ.lookup fid psq of
               Nothing -> next_step (PSQ.insert fid (pendingTime now) (Pending note) psq) now
               Just (_, cache_state) ->
                 case cache_state of
                   Pending (Note _ old_state)
                     | state `isCancelling` old_state ->
                       next_step (PSQ.insert fid (cancelledTime now) (Cancelled note) psq) now
                     | state `isProgressing` old_state ->
                       next_step (PSQ.insert fid (pendingTime now) (Pending note) psq) now
                     | otherwise -> next_step psq now
                   Sent p
                     | p == note -> next_step (PSQ.insert fid (sentTime now) (Sent p) psq) now
                     | otherwise -> next_step (PSQ.insert fid (pendingTime now) (Pending note) psq) now
                   Cancelled p
                     | p == note -> next_step (PSQ.insert fid (cancelledTime' now) (Cancelled p) psq) now
                     | otherwise -> next_step (PSQ.insert fid (pendingTime now) (Pending note) psq) now
        Just ns -> do
           announce ns
           next_step psq now
    -- Execute current action.
    -- TODO: batch multiple events?
    execute (Pending n@(Note fid _)) !now !psq = do
      announce [n]
      next_step (PSQ.insert fid (sentTime now) (Sent n) psq) now
    execute Sent{} !now !psq = next_step psq now
    execute Cancelled{} !now !psq = next_step psq now
    -- Decide what to do next
    next_step !psq !now =
      case PSQ.minView psq of
        Nothing -> await_event
        Just (_, pri, v, psq') ->
          if now >= pri
          then execute v now psq'
          else await_execute (delay pri now) psq
    readNoteMsg = matchSTM (readTChan chan) return
    pendingTime   !now = now + TimeSpec 0 (fromIntegral $ 1000*pendingInterval)
    cancelledTime !now = now + TimeSpec 0 (fromIntegral $ 1000*cancelledInterval)
    -- increase only half of the period on duplicate.
    sentTime now      = now + TimeSpec 0 (fromIntegral $ 500*sentInterval)
    cancelledTime' !now = now + TimeSpec 0 (fromIntegral $ 500*cancelledInterval)
    delay  p !now      = fromIntegral $ (timeSpecAsNanoSecs $ p `diffTimeSpec` now) `div` 1000

-- | Time to keep sent value in the cache (remove duplicates).
sentInterval :: Int
sentInterval = 2000000 -- 2s

-- | Time to keep message in pending state (wait for cancellation).
pendingInterval :: Int
pendingInterval = 300000 -- 0.3s

-- | Time to keep message in cancelled state (remove duplicates).
cancelledInterval :: Int
cancelledInterval = sentInterval * 2


isCancelling :: M0.ConfObjectState -> M0.ConfObjectState -> Bool
isCancelling M0.M0_NC_ONLINE M0.M0_NC_ONLINE = False
isCancelling M0.M0_NC_ONLINE _ = True
isCancelling _ M0.M0_NC_ONLINE = True
isCancelling _ _ = False

isProgressing :: M0.ConfObjectState -> M0.ConfObjectState -> Bool
isProgressing M0.M0_NC_TRANSIENT M0.M0_NC_FAILED = True
isProgressing _ _ = False

-- | States that are affected by the filtering algorithm.
filteredStates :: [M0.ConfObjectState]
filteredStates = [ M0.M0_NC_ONLINE, M0.M0_NC_TRANSIENT, M0.M0_NC_FAILED]

-- | State inside priority queue
data CacheState = Pending Note
                | Cancelled Note
                | Sent Note
