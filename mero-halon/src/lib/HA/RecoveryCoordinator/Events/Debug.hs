-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

module HA.RecoveryCoordinator.Events.Debug where

import HA.Resources

import Control.Distributed.Process (NodeId, ProcessId)

import Data.Binary   (Binary)
import Data.Hashable (Hashable)
import qualified Data.Map.Strict as Map
import Data.Typeable (Typeable)
import Data.UUID (UUID)

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

data DebugRequest =
    DebugRequest ProcessId
  deriving (Eq, Show, Generic, Typeable)

instance Binary DebugRequest
instance Hashable DebugRequest

data DebugResponse = DebugResponse {
    dr_eq_nodes :: [NodeId]
  , dr_refCounts :: Map.Map UUID Int
  , dr_rg_elts :: Int
  , dr_rg_since_gc :: Int
  , dr_rg_gc_threshold :: Int
  }
  deriving (Eq, Show, Generic, Typeable)

instance Binary DebugResponse
