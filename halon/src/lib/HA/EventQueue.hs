-- |
-- Module    : HA.EventQueue
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- All events intended to be delivered the Recovery Coordinator should be
-- sent via Event Queue. The Event Queue is a replicated mailbox
-- that is resilient to failure of any minority of replicas.
-- Events posted to the Event Queue are forwarded to consumers
-- (typically the Recovery Coordinator) and only removed when the consumer
-- have explicitly acknowledged to have handled them.
--
-- Upon receiving an event, the Recovery Coordinator must take recovery
-- measures and notify the Event Queue with a 'Trim' message that the recovery
-- for a given event or sequence of events is done. Upon receiving such
-- notification, the Event Queue component can delete the event from the
-- replicated mailbox.
--
-- If a recovery procedure is interrupted due to a failure in the tracking
-- station or in the RC, the Event Queue will send all unhandled events to
-- another instance of the RC. This is why it is important that all operations
-- of the recovery coordinator be idempotent.
--
module HA.EventQueue
  ( -- * Messaging
    HAEvent(..)
  , HA.EventQueue.Producer.promulgate
  , HA.EventQueue.Producer.promulgateWait
  , HA.EventQueue.Producer.promulgateEQ
  , HA.EventQueue.Producer.promulgateEQ_
  , eventQueueLabel
    -- * Debug utilities.
    -- ** Queue control
  , DoClearEQ(..)
  , DoneClearEQ(..)
    -- ** Gather statistics
  , EQStatResp(..)
  , PoolStats(..)
  , requestEQStats
  ) where

import Control.Distributed.Process
  ( NodeId
  , Process
  , getSelfPid
  , nsendRemote
  )
import HA.EventQueue.Producer
import HA.EventQueue.Types

-- | Request EventQueue statistics. This method is asynchronous,
-- after it was called 'EQStatResp' will be send to the process's mailbox.
requestEQStats :: NodeId -> Process ()
requestEQStats eq = do
  self <- getSelfPid
  nsendRemote eq eventQueueLabel $ EQStatReq self
