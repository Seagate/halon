-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

module HA.RecoveryCoordinator.Events.Status where

import HA.Resources

import Control.Distributed.Process (ProcessId)

import Data.Binary   (Binary)
import Data.Hashable (Hashable)
import Data.Typeable (Typeable)

import GHC.Generics

-- ^ Sent when a process wishes to enquire about the status of a node.
data NodeStatusRequest =
    NodeStatusRequest Node [ProcessId]
  deriving (Eq, Show, Typeable, Generic)

instance Hashable NodeStatusRequest
instance Binary NodeStatusRequest

-- ^ Response to a query about the status of a node.
data NodeStatusResponse = NodeStatusResponse
  { nsrNode :: Node
  , nsrIsStation :: Bool
  , nsrIsSatellite :: Bool
  } deriving (Eq, Show, Typeable, Generic)

instance Hashable NodeStatusResponse
instance Binary NodeStatusResponse
