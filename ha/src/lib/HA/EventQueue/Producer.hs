-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This is the Event Producer API, used by services.

module HA.EventQueue.Producer where

import Control.Distributed.Process (Process, die, whereis, liftIO)
import Control.Distributed.Process.Serializable (Serializable)
-- Qualify all imports of any distributed-process "internals".
import qualified Control.Distributed.Process.Internal.Types as I
    (createMessage, messageToPayload)
import HA.NodeAgent.Lookup (nodeAgentLabel)
import Control.Distributed.Process.Platform.Call (callAt)
import Control.Concurrent (threadDelay)

-- | Add an event to the event queue, and don't die yet.
promulgate :: Serializable a => a -> Process ()
promulgate x = do
    mthem <- whereis nodeAgentLabel
    case mthem of
        Nothing -> error "NodeAgent is not registered."
        Just na -> do
          ret <- callAt na msg 0
          case ret of
            Just True -> return ()
            _ -> do liftIO $ threadDelay 5000000
                    promulgate x
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
