{-# LANGUAGE OverloadedStrings #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.EventQueue.CEP where

import Prelude hiding (id)
import Control.Category

import Control.Distributed.Process
import Control.Monad.State
import Network.CEP

import HA.EventQueue
import HA.Replicator

eqRules :: RGroup g => g EventQueue -> RuleM (Maybe ProcessId) ()
eqRules rg = do
    define "rc-spawned" id $ \rc ->
      recordNewRC rg rc

    define "monitoring" id $ \(ProcessMonitorNotification _ pid reason) -> do
      mRC <- get
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
          -- We use compare and swap to make sure we don't overwrite
          -- the pid of a respawned RC
          _ -> recordRCDied rg

    define "trimming" id $ \eid ->
      trim rg eid

    define "ha-event" id $ \(sender, ev) ->
      recordEvent rg sender ev

    define "trim-ack" id $ \(TrimAck eid) ->
      publish (TrimDone eid)

    define "record-ack" id $ \(RecordAck sender ev) -> do
      mRC <- get
      case mRC of
        -- I know where the RC is.
        Just rc -> sendEventToRC rc sender ev
        Nothing -> do
          rmRC <- lookupRC rg
          case rmRC of
            Just rc -> do
              monitoring rc
              sendEventToRC rc sender ev
            Nothing -> sendOwnNode sender
          put rmRC

    define "rc-spawned-ack" id $ \(NewRCAck rc) -> do
      monitoring rc
      sendEventsToRC rg rc
      put $ Just rc

    define "rc-died-ack" id $ \RCDiedAck -> do
      publish RCDied
      put Nothing
