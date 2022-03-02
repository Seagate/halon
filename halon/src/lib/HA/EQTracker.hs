-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- EventQueueTracker intended to to track the location of (a subset of) nodes
-- that runs event queue. EQ tracker simplifies sending messages to the Recovery Coordinator,
-- since each individual service need not track the location of the event queue nodes
-- and their leader..
--
-- Note that the EQTracker does not act as a proxy for the EventQueue, it just
-- serves as a registry.
module HA.EQTracker
  ( -- * Update
    updateEQNodes
    -- * Lookup
  , lookupReplicas
  , ReplicaReply(..)
  , ReplicaLocation(..)
    -- * D-p functions.
  , updateEQNodes__static
  , updateEQNodes__sdict
  ) where

import HA.EQTracker.Process
