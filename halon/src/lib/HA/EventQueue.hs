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
{-# LANGUAGE CPP #-}
module HA.EventQueue
  ( eventQueue, EventQueue, __remoteTable, eventQueueLabel ) where

import HA.EventQueue.Consumer
import HA.EventQueue.Types
import HA.EventQueue.Producer ( sendHAEvent )
import HA.Replicator ( RGroup, updateStateWith, getState)
import Control.SpineSeq (spineSeq)

import Control.Distributed.Process
import Control.Distributed.Process.Closure ( remotable, mkClosure )

import Control.Arrow ( first, second )
import Data.ByteString ( ByteString )
import Data.Traversable

#ifdef USE_CONTROL_FILES
import System.Directory
import Data.Char
#endif


-- | Since there is at most one Event Queue per tracking station node,
-- the @eventQueueLabel@ is used to register and lookup the Event Queue of a
-- node.
eventQueueLabel :: String
eventQueueLabel = "HA.EventQueue"

-- | State of the event queue.
--
-- It contains the process id of the RC and the list of pending events.
type EventQueue = (Maybe ProcessId, [HAEvent [ByteString]])

sayEQ :: String -> Process ()
sayEQ = liftIO . putStrLn . ("Event Queue: " ++)

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

remotable [ 'addSerializedEvent, 'setRC, 'compareAndSwapRC, 'filterEvent ]

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
eventQueue :: RGroup g
           => g EventQueue
           -> Process ()
eventQueue rg = do
    getSelfPid >>= register eventQueueLabel
    (mRC, _) <- getState rg
    -- The EQ must monitor the RC or it will never realize when the RC stops
    -- responding and won't ever care of checking the replicated state to learn
    -- of new RCs.
    _ <- traverse monitor mRC
    prepareControlFile
    loop mRC
  where
    loop mRC =
        receiveWait
          [ -- A local RC has been spawned.
            match $ \(rc :: ProcessId) -> do
              _ <- monitor rc
              -- Record in the replicated state that there is a new RC.
              updateStateWith rg $ $(mkClosure 'setRC) $ Just rc
              -- Send the pending events to the new RC.
              self <- getSelfPid
              (_, pendingEvents) <- getState rg
              mapM_ (send rc . (\ev -> ev{eventHops = self : eventHops ev})) $ reverse pendingEvents
              return $ Just rc
          , match $ \(ProcessMonitorNotification _ pid reason) -> do
              -- Check the identity of the process in case the
              -- notifications get mixed for old and new RCs.
              if Just pid == mRC
              then case reason of
                -- The connection to the RC failed.
                -- Call reconnect to say it is ok to connect again.
                DiedDisconnect -> do _ <- traverse reconnect mRC
                                     sayEQ "RC is lost."
                                     return Nothing
                -- The RC died.
                -- We use compare and swap to make sure we don't overwrite
                -- the pid of a respawned RC.
                _ -> do updateStateWith rg $
                          $(mkClosure 'compareAndSwapRC) (mRC, Nothing :: Maybe ProcessId)
                        sayEQ "RC died."
                        return Nothing
              else return mRC
            -- The RC handled the event with the given id.
          , match $ \(eid :: EventId) -> do
                updateStateWith rg $ $(mkClosure 'filterEvent) eid
                sayEQ "Trim done."
                return mRC
            -- Process an HA event
          , match $ \(sender :: ProcessId, ev :: HAEvent [ByteString]) -> checkAndDo mRC $ do
              updateStateWith rg $ $(mkClosure 'addSerializedEvent) ev
              selfNode <- getSelfNode
              sayEQ "Replicated event."
              case mRC of
                -- I know where the RC is.
                Just rc -> do
                  send sender (selfNode, processNodeId rc)
                  sendHAEvent rc ev
                  return mRC
                -- I don't know where the RC is.
                Nothing -> do
                  -- See if we can learn it by looking at the replicated state.
                  (newMRC, _) <- getState rg
                  case newMRC of
                    Just rc -> do _ <- monitor rc
                                  send sender (selfNode, processNodeId rc)
                                  sendHAEvent rc ev
                               -- Send my own node when we don't know the RC
                               -- location. Note that I was able to read the
                               -- replicated state so very likely there is
                               -- no RC.
                    Nothing -> do
                      n <- getSelfNode
                      send sender (n, n)
                  return newMRC
          ] >>= loop

#ifdef USE_CONTROL_FILES

clearName :: String -> String
clearName = filter isAlphaNum

-- | Prepare control file
prepareControlFile :: Process ()
prepareControlFile = do
    fn <- fmap (clearName . show) getSelfPid
    liftIO $ writeFile ("event-queue." ++ fn) ""
    return ()

-- | Check if failure file exists
checkAndDo :: a -> Process a -> Process a
checkAndDo c action = do
    fn <- fmap (clearName . show) getSelfPid
    d  <- liftIO $ doesFileExist $ "event-queue." ++ fn ++ ".fail"
    if d
    then do liftIO $ putStrLn "EQ: ignored message"
            return c
    else action

#else

prepareControlFile :: Process ()
prepareControlFile = return ()

checkAndDo :: a -> Process a -> Process a
checkAndDo _ action = action

#endif
