-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
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
    -- * D-p functions.
  , updateEQNodes__static
  , updateEQNodes__sdict
    -- * Lookup
  , lookupReplicas
  , ReplicaReply(..)
  , ReplicaLocation(..)
  ) where

import HA.EQTracker.Process
