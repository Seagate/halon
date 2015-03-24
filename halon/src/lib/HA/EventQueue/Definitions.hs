-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.EventQueue.Definitions where

import Control.Distributed.Process

import HA.EventQueue
import HA.EventQueue.CEP
import HA.Replicator

eventQueue :: RGroup g => g EventQueue -> Process ()
eventQueue rg = makeEventQueueFromRules rg $ eqRules rg
