{-# LANGUAGE OverloadedStrings #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.EventQueue.CEP where

import Prelude hiding (id)

import Control.Distributed.Process
import Control.Monad.State
import Network.CEP

import HA.EventQueue
import HA.EventQueue.Types
import HA.Replicator

eqRules :: RGroup g => g EventQueue -> Definitions (Maybe EventQueueState) ()
eqRules rg = do
    define "rc-spawned" $ \rc -> do
      ph1 <- phase "state-1" $ do
        recordNewRC rg rc
        setRC rc
        sendEventsToRC rg rc

      start ph1

    define "monitoring" $ \(ProcessMonitorNotification _ pid reason) -> do
      ph1 <- phase "state-1" $ do
        mRC <- getRC
        -- Check the identity of the process in case the
        -- notifications get mixed for old and new RCs.
        when (Just pid == mRC) $
          case reason of
            -- The connection to the RC failed.
            -- Call reconnect to say it is ok to connect again.
            DiedDisconnect -> do
              reconnectToRC
              publish RCLost
            -- The RC died.
            _              -> do recordRCDied rg
                                 publish RCDied
                                 clearRC
      start ph1

    define "trimming" $ \eid -> do
      ph1 <- phase "state-1" $ trim rg eid
      start ph1

    define "ha-event" $ \(sender, ev) -> do
      ph1 <- phase "state-1" $ do
        mRC  <- lookupRC rg
        here <- liftProcess getSelfNode
        case mRC of
          Just rc | here /= processNodeId rc
            -> -- Delegate on the colocated EQ.
               -- The colocated EQ learns immediately of the RC death. This
               -- ensures events are not sent to a defunct RC rather than to a
               -- live one.
               liftProcess $ do
                 self <- getSelfPid
                 nsendRemote (processNodeId rc) eventQueueLabel
                             (sender, ev{eventHops = self : eventHops ev})
          _ -> -- Record the event if there is no known RC or if it is colocated.
               recordEvent rg sender ev
      start ph1

    define "trim-ack" $ \(TrimAck eid) -> do
      ph1 <- phase "state-1" $ publish (TrimDone eid)
      start ph1

    define "record-ack" $ \(RecordAck sender ev) -> do
      ph1 <- phase "state-1" $ do
        mRC <- lookupRC rg
        case mRC of
          Just rc -> sendEventToRC rc sender ev
          Nothing -> sendOwnNode sender

      start ph1
