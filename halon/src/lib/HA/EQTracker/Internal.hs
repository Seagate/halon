-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Internal messages types for the EQTracker.
module HA.EQTracker.Internal
  ( ReplicaLocation(..)
  , ReplicaRequest(..)
  , ReplicaReply(..)
  , UpdateEQNodes(..)
  , UpdateEQNodesAck(..)
  , PreferReplica(..)
  , name
  ) where

import Control.Distributed.Process 
import Data.Binary   (Binary)
import Data.Hashable (Hashable)
import Data.Typeable (Typeable)
import GHC.Generics

-- | Process label: @"HA.EQTracker"@
name :: String
name = "HA.EQTracker"

-- | Reply to the 'ReplicaRequest'.
newtype ReplicaReply = ReplicaReply ReplicaLocation
  deriving (Eq, Show, Typeable, Binary, Hashable)

-- | Message sent by clients to request a replica list.
newtype ReplicaRequest = ReplicaRequest ProcessId
  deriving (Eq, Show, Typeable, Binary, Hashable)

-- | Update the nids of the EQs, for example, in the event of the
-- RC restarting on a different node.
--
-- @'UpdateEQNodes' caller eqnodes@
data UpdateEQNodes = UpdateEQNodes ProcessId [NodeId]
  deriving (Eq, Show, Generic, Typeable)
instance Binary UpdateEQNodes

-- | Reply to 'UpdateEQNodes', sent to the caller when nodes are
-- updated.
data UpdateEQNodesAck = UpdateEQNodesAck
  deriving (Eq, Show, Generic, Typeable)
instance Binary UpdateEQNodesAck

-- | Loop state for the tracker. We store a preferred replica as well as the
-- full list of known replicas. None of these are guaranteed to exist.
data ReplicaLocation = ReplicaLocation
  { eqsPreferredReplica :: Maybe NodeId
  -- ^ Current leader of the event queue group.
  , eqsReplicas :: [NodeId]
  -- ^ List of replicas.
  } deriving (Eq, Generic, Show, Typeable)

instance Binary ReplicaLocation
instance Hashable ReplicaLocation

-- | Message sent by clients to indicate a preference for a certain replica.
data PreferReplica = PreferReplica NodeId
  deriving (Eq, Generic, Show, Typeable)

instance Binary PreferReplica
instance Hashable PreferReplica
