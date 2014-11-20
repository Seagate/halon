-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This is the Event Producer API, used by services.

module HA.EventQueue.Producer
  ( nodeAgentLabel
  , promulgateEQ
  , promulgate
  , expiate
  ) where

import Control.Distributed.Process
  ( Process
  , ProcessId
  , NodeId
  , die
  , getSelfPid
  , spawnLocal
  , whereis
  )
import Control.Distributed.Process.Serializable (Serializable)
-- Qualify all imports of any distributed-process "internals".
import qualified Control.Distributed.Process.Internal.Types as I
    (createMessage, messageToPayload)

import Data.ByteString (ByteString)

import HA.CallTimeout (callLocal, callTimeout, ncallRemoteAnyTimeout)
import HA.EventQueue (eventQueueLabel)
import HA.EventQueue.Types

-- XXX has to go here because HA.NodeAgent depends on this module.
nodeAgentLabel :: String
nodeAgentLabel = "HA.NodeAgent"

-- This timeout needs to be higher than the staggering
-- hard timeout.
promulgateTimeout :: Int
promulgateTimeout = 15000000

-- | Promulgate an event directly to an EQ node without indirection
--   via the NodeAgent. Note that this spawns a local process in order
--   to ensure that the event id is unique.
promulgateEQ :: Serializable a
             => [NodeId] -- ^ EQ nodes
             -> a -- ^ Event to send
             -> Process ProcessId
promulgateEQ eqnids x = spawnLocal $ do
    self <- getSelfPid
    promulgateHAEvent eqnids $ evt self
  where
    evt pid = HAEvent {
        eventId = EventId pid 1
      , eventPayload = payload :: [ByteString]
      , eventHops = []
    }
    payload = (I.messageToPayload . I.createMessage $ x)

-- | Promulgate an HAEvent directly to EQ nodes.
promulgateHAEvent :: Serializable a => [NodeId] -> HAEvent a -> Process ()
promulgateHAEvent eqnids evt = do
  result <- callLocal $
    ncallRemoteAnyTimeout promulgateTimeout eqnids eventQueueLabel evt
  case result :: Maybe (NodeId, NodeId) of
    Nothing -> promulgateHAEvent eqnids evt
    _ -> return ()

-- | Add an event to the event queue, and don't die yet.
-- FIXME: Use a well-defined timeout.
promulgate :: Serializable a => a -> Process ()
promulgate x = do
    mthem <- whereis nodeAgentLabel
    case mthem of
        Nothing -> error "NodeAgent is not registered."
        Just na -> do
          ret <- callLocal $
            callTimeout promulgateTimeout na msg
          case ret of
            Just True -> return ()
            _ -> promulgate x
{-
The issue that this loop addresses in particular is if the node agent
is contactable, but there are no accessible EQs, either because the
node agent hasn't been initialized by the RC yet, or because the known
EQs are temporarily down. In that case, the right thing to do
is not to throw out the message, but to keep trying until an EQ becomes
available.
-}
  where
    msg = (I.messageToPayload . I.createMessage $ x)

-- | Add a new event to the event queue and then die.
expiate :: Serializable a => a -> Process ()
expiate x = promulgate x >> die "Expiate."
