-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This is the Event Producer API, used by services.

module HA.EventQueue.Producer where

import Control.Distributed.Process (Process, ProcessId, getSelfPid, send, die, whereis)
import Control.Distributed.Process.Serializable (Serializable)
-- Qualify all imports of any distributed-process "internals".
import qualified Control.Distributed.Process.Internal.Types as I
    (createMessage, messageToPayload)
import HA.CallTimeout (callTimeout)
import HA.EventQueue.Types
import HA.NodeAgent.Lookup (nodeAgentLabel)

-- | Add an event to the event queue, and don't die yet.
-- FIXME: Use a well-defined timeout.
promulgate :: Serializable a => a -> Process ()
promulgate x = do
    mthem <- whereis nodeAgentLabel
    case mthem of
        Nothing -> error "NodeAgent is not registered."
        Just na -> do
          ret <- callTimeout 5000000 na msg
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

-- | Send HAEvent and provide information about current process.
sendHAEvent :: Serializable a => ProcessId -> HAEvent a -> Process ()
sendHAEvent next ev = getSelfPid >>= \pid -> send next ev{eventHops = pid : eventHops ev}
