{-# LANGUAGE StrictData      #-}
{-# LANGUAGE TemplateHaskell #-}
-- |
-- Module    : HA.RecoveryCoordinator.RC.Events.Debug
-- Copyright : (C) 2015-2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
module HA.RecoveryCoordinator.RC.Events.Info where

import           Control.Distributed.Process (NodeId, SendPort)
import           Data.Binary (Binary)
import qualified Data.ByteString as B
import qualified Data.Map.Strict as Map
import           Data.Typeable (Typeable)
import           Data.UUID (UUID)
import           GHC.Generics
import           HA.Resources
import qualified HA.Resources.Mero as M0
import           HA.SafeCopy
import           Mero.ConfC (Fid)

-- | Sent when a process wishes to enquire about the status of a node.
data NodeStatusRequest = NodeStatusRequest !Node !(SendPort NodeStatusResponse)
  deriving (Eq, Show, Typeable, Generic)

-- | Response to a query about the status of a node.
data NodeStatusResponse = NodeStatusResponse
  { nsrNode :: !Node
  , nsrIsStation :: !Bool
  , nsrIsSatellite :: !Bool
  } deriving (Eq, Show, Typeable, Generic)
instance Binary NodeStatusResponse

-- | Request debug information from RC.
newtype DebugRequest = DebugRequest (SendPort DebugResponse)
  deriving (Eq, Show, Generic, Typeable)

-- | Debug information about halon. Requested with 'DebugRequest'.
data DebugResponse = DebugResponse {
    dr_eq_nodes :: ![NodeId]
  , dr_refCounts :: !(Map.Map UUID Int)
  , dr_rg_elts :: !Int
  , dr_rg_since_gc :: !Int
  , dr_rg_gc_threshold :: !Int
  }
  deriving (Eq, Show, Generic, Typeable)
instance Binary DebugResponse

data GraphDataCmd
  = MultimapGetKeyValuePairs !(SendPort GraphDataReply)
  -- ^ Retrieve multimap in pairs of k:v
  | ReadResourceGraph !(SendPort GraphDataReply)
  -- ^ Read the data from RG directly
  | JsonGraph !(SendPort GraphDataReply)
  -- ^ Read the data from RG and dump it out to JSON
  deriving (Show, Eq, Ord, Generic, Typeable)

data GraphDataReply
  = GraphDataChunk !B.ByteString
    -- ^ A chunk of data sent to us from RC.
  | GraphDataDone
    -- ^ RC is done sending data.
  deriving (Show, Eq, Ord, Generic, Typeable)
instance Binary GraphDataReply

-- | Support for @halonctl
data ProcessQueryRequest =
  ProcessQueryRequest !Fid !(SendPort (Maybe M0.Process))
  deriving (Eq, Show, Generic, Typeable)

deriveSafeCopy 0 'base ''DebugRequest
deriveSafeCopy 0 'base ''GraphDataCmd
deriveSafeCopy 0 'base ''NodeStatusRequest
deriveSafeCopy 0 'base ''ProcessQueryRequest
