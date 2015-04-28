-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This is the Event Producer API, used by services.

module HA.EventQueue.Producer
  ( promulgateEQ
  , promulgate
  , expiate
  ) where

import HA.CallTimeout
  ( callLocal
  , ncallRemoteAnyTimeout
  , ncallRemoteAnyPreferTimeout
  )
import HA.EventQueue (eventQueueLabel)
import HA.EventQueue.Types
import qualified HA.Services.EQTracker as EQT

import Control.Distributed.Process
  ( Process
  , ProcessId
  , NodeId
  , die
  , expectTimeout
  , nsend
  , getSelfPid
  , say
  , spawnLocal
  )
import Control.Distributed.Process.Serializable (Serializable)
-- Qualify all imports of any distributed-process "internals".
import qualified Control.Distributed.Process.Internal.Types as I
    (createMessage, messageToPayload)

import Data.ByteString (ByteString)
import Data.List ((\\))

softTimeout :: Int
softTimeout = 2000000

-- This timeout needs to be higher than the staggering
-- hard timeout.
promulgateTimeout :: Int
promulgateTimeout = 15000000

-- | Promulgate an event directly to an EQ node without indirection
--   via the NodeAgent. Note that this spawns a local process in order
--   to ensure that the event id is unique.
promulgateEQ :: Serializable a
             => [NodeId] -- ^ EQ nodes.
             -> a -- ^ Event to send.
             -> Process ProcessId -- ^ PID of the spawned process. This can
                                  --   be used to verify receipt.
promulgateEQ eqnids x = spawnLocal $ do
    self <- getSelfPid
    promulgateHAEvent eqnids $ buildHAEvent x (EventId self 1)

-- | Like 'promulgateEQ', but express a preference for certain EQ nodes.
promulgateEQPref :: Serializable a
                 => [NodeId] -- ^ Preferred EQ nodes.
                 -> [NodeId] -- ^ All EQ nodes.
                 -> a -- ^ Event to send.
                 -> Process ProcessId
promulgateEQPref peqnids eqnids x = spawnLocal $ do
    self <- getSelfPid
    promulgateHAEventPref peqnids eqnids $ buildHAEvent x (EventId self 1)

buildHAEvent :: Serializable a
             => a
             -> EventId
             -> HAEvent [ByteString]
buildHAEvent x ident = HAEvent
    { eventId = ident
    , eventPayload = payload :: [ByteString]
    , eventHops = []
    }
  where
    payload = (I.messageToPayload . I.createMessage $ x)

-- | Promulgate an HAEvent directly to EQ nodes. We also try to inform the
--   local EQ tracker about preferred replicas, if available.
promulgateHAEvent :: Serializable a
                  => [NodeId] -- ^ EQ nodes.
                  -> HAEvent a
                  -> Process ()
promulgateHAEvent eqnids evt = do
  say $ "Sending to " ++ (show eqnids)
  result <- callLocal $
    ncallRemoteAnyTimeout
      promulgateTimeout eqnids eventQueueLabel evt
  case result :: Maybe (NodeId, NodeId) of
    Nothing -> promulgateHAEvent eqnids evt
    Just (rnid, pnid) -> nsend EQT.name $ EQT.PreferReplicas rnid pnid

-- | Promulgate an HAEvent directly to EQ nodes, specifying a preference for
--   certain nodes first. We also try to inform the local EQ tracker about
--   preferred replicas, if available.
promulgateHAEventPref :: Serializable a
                      => [NodeId] -- ^ Preferred EQ nodes.
                      -> [NodeId] -- ^ All EQ nodes.
                      -> HAEvent a
                      -> Process ()
promulgateHAEventPref peqnids eqnids evt = do
  say $ "Sending to " ++ (show peqnids) ++ " and then to " ++ show (eqnids \\ peqnids)
  result <- callLocal $
    ncallRemoteAnyPreferTimeout
      softTimeout promulgateTimeout
      peqnids (eqnids \\ peqnids)
      eventQueueLabel evt
  case result :: Maybe (NodeId, NodeId) of
    Nothing -> promulgateHAEventPref peqnids eqnids evt
    Just (rnid, pnid) -> nsend EQT.name $ EQT.PreferReplicas rnid pnid

-- | Add an event to the event queue, and don't die yet. This uses the local
--   event tracker to identify the list of EQ nodes.
-- FIXME: Use a well-defined timeout.
promulgate :: Serializable a => a -> Process ProcessId
promulgate x = do
    self <- getSelfPid
    nsend EQT.name $ EQT.ReplicaRequest self
    rl <- expectTimeout softTimeout
    case rl of
      Just (EQT.ReplicaReply (EQT.ReplicaLocation pref rest)) -> do
        pid <- case pref of
          [] -> promulgateEQ rest x
          _ -> promulgateEQPref pref rest x
        return pid
      Nothing -> promulgate x
{-
The issue that this loop addresses in particular is if the node agent
is contactable, but there are no accessible EQs, either because the
node agent hasn't been initialized by the RC yet, or because the known
EQs are temporarily down. In that case, the right thing to do
is not to throw out the message, but to keep trying until an EQ becomes
available.
-}

-- | Add a new event to the event queue and then die.
expiate :: Serializable a => a -> Process ()
expiate x = promulgate x >> die "Expiate."
