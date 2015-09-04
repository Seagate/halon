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
import HA.Replicator

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
