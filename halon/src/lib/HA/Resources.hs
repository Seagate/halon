-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module HA.Resources where

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Data.Binary
import Data.ByteString (ByteString)
import Data.Function (on)
import Data.Hashable (Hashable(..))
import Data.Typeable (Typeable)
import GHC.Generics (Generic)

import HA.ResourceGraph

--------------------------------------------------------------------------------
-- Resources                                                                  --
--------------------------------------------------------------------------------

-- | The root of the resource graph.
data Cluster = Cluster
  deriving (Eq, Ord, Show, Typeable, Generic)

instance Binary Cluster
instance Hashable Cluster

-- | A resource graph representation for nodes.
data Node = Node NodeId
  deriving (Eq, Ord, Show, Typeable, Generic)

instance Binary Node
instance Hashable Node

-- | An identifier for epochs.
type EpochId = Word64

-- | A datatype for epochs which hold a state.
data Epoch a = Epoch
  { epochId    :: EpochId  -- ^ Identifier of epoch.
  , epochState :: a        -- ^ State held by epoch.
  }
  deriving (Show, Typeable, Generic)

instance Eq (Epoch a) where
  (==) = (==) `on` epochId

instance Ord (Epoch a) where
  compare = compare `on` epochId

instance Binary a => Binary (Epoch a)

instance Hashable (Epoch a) where
  hashWithSalt s = hashWithSalt s . epochId

--------------------------------------------------------------------------------
-- Relations                                                                  --
--------------------------------------------------------------------------------

-- | A relation connecting the cluster to global resources, such as nodes and
-- epochs.
data Has = Has
  deriving (Eq, Show, Typeable, Generic)

instance Binary Has
instance Hashable Has

-- | A relation connecting a node to the services it runs.
data Runs = Runs
  deriving (Eq, Show, Typeable, Generic)

instance Binary Runs
instance Hashable Runs

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

resourceDictCluster :: Dict (Resource Cluster)
resourceDictNode :: Dict (Resource Node)
resourceDictEpoch :: Dict (Resource (Epoch ByteString))

resourceDictCluster = Dict
resourceDictNode = Dict
resourceDictEpoch = Dict

relationDictHasClusterNode :: Dict (Relation Has Cluster Node)
relationDictHasClusterEpoch :: Dict (Relation Has Cluster (Epoch ByteString))

relationDictHasClusterNode = Dict
relationDictHasClusterEpoch = Dict

remotable
  [ 'resourceDictCluster
  , 'resourceDictNode
  , 'resourceDictEpoch
  , 'relationDictHasClusterNode
  , 'relationDictHasClusterEpoch
  ]

instance Resource Cluster where
  resourceDict = $(mkStatic 'resourceDictCluster)

instance Resource Node where
  resourceDict = $(mkStatic 'resourceDictNode)

instance Resource (Epoch ByteString) where
  resourceDict = $(mkStatic 'resourceDictEpoch)

instance Relation Has Cluster Node where
  relationDict = $(mkStatic 'relationDictHasClusterNode)

instance Relation Has Cluster (Epoch ByteString) where
  relationDict = $(mkStatic 'relationDictHasClusterEpoch)

--------------------------------------------------------------------------------
-- Epoch messages                                                             --
--------------------------------------------------------------------------------

-- | Sent when a service requests the id of the latest epoch.
newtype EpochRequest = EpochRequest ProcessId
  deriving (Typeable, Binary, Generic)

-- | Sent by the RC to communicate the most recent epoch.
newtype EpochResponse = EpochResponse EpochId
  deriving (Binary, Typeable, Generic)

-- | Sent when a service requests an epoch transition.
data EpochTransitionRequest = EpochTransitionRequest
  { etrSource  :: ProcessId  -- ^ Service instance process sending request.
  , etrCurrent :: EpochId    -- ^ Starting epoch.
  , etrTarget  :: EpochId    -- ^ Destination epoch.
  } deriving (Typeable, Generic)

instance Binary EpochTransitionRequest

-- | Sent when the RC communicates an epoch transition.
data EpochTransition a = EpochTransition
  { etCurrent :: EpochId  -- ^ Starting epoch.
  , etTarget  :: EpochId  -- ^ Destination epoch.
  , etHow     :: a        -- ^ Instructions to reach destination.
  } deriving (Typeable, Generic)

instance Binary a => Binary (EpochTransition a)
