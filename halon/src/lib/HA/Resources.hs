-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module HA.Resources where

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Data.Binary (Binary)
import Data.ByteString (ByteString)
import Data.Function (on)
import Data.Hashable (Hashable(..))
import Data.Typeable (Typeable)
import Data.Word (Word64)
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

-- | An identifier for services, unique across the resource graph.
type ServiceName = String

-- | A resource graph representation for services.
data Service = Service
  { serviceName    :: ServiceName           -- ^ Name of service.
  , serviceProcess :: Closure (Process ())  -- ^ Process implementing service.
  }
  deriving (Typeable, Generic)

instance Eq Service where
  (==) = (==) `on` serviceName

instance Ord Service where
  compare = compare `on` serviceName

instance Binary Service

instance Hashable Service where
  hashWithSalt s = hashWithSalt s . serviceName

-- | A resource graph representation for nodes.
data Node = Node ProcessId
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
  deriving (Typeable, Generic)

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

resourceDictCluster,
  resourceDictNode,
  resourceDictService,
  resourceDictEpoch :: Some ResourceDict
resourceDictCluster = mkResourceDict (undefined :: Cluster)
resourceDictNode    = mkResourceDict (undefined :: Node)
resourceDictService = mkResourceDict (undefined :: Service)
resourceDictEpoch   = mkResourceDict (undefined :: Epoch ByteString)

relationDictHasClusterNode,
  relationDictHasClusterEpoch,
  relationDictRunsNodeService :: Some RelationDict
relationDictHasClusterNode  = mkRelationDict (undefined :: (Has, Cluster, Node))
relationDictHasClusterEpoch = mkRelationDict (undefined :: (Has, Cluster, Epoch ByteString))
relationDictRunsNodeService = mkRelationDict (undefined :: (Runs, Node, Service))

remotable
  [ 'resourceDictCluster
  , 'resourceDictNode
  , 'resourceDictService
  , 'resourceDictEpoch
  , 'relationDictHasClusterNode
  , 'relationDictHasClusterEpoch
  , 'relationDictRunsNodeService
  ]

instance Resource Cluster where
  resourceDict _ = $(mkStatic 'resourceDictCluster)

instance Resource Node where
  resourceDict _ = $(mkStatic 'resourceDictNode)

instance Resource Service where
  resourceDict _ = $(mkStatic 'resourceDictService)

instance Resource (Epoch ByteString) where
  resourceDict _ = $(mkStatic 'resourceDictEpoch)

instance Relation Has Cluster Node where
  relationDict _ = $(mkStatic 'relationDictHasClusterNode)

instance Relation Has Cluster (Epoch ByteString) where
  relationDict _ = $(mkStatic 'relationDictHasClusterEpoch)

instance Relation Runs Node Service where
  relationDict _ = $(mkStatic 'relationDictRunsNodeService)

--------------------------------------------------------------------------------
-- Service messages                                                           --
--------------------------------------------------------------------------------

-- | A notification of a service failure.
data ServiceFailed = ServiceFailed Node Service
  deriving (Typeable, Generic)

instance Binary ServiceFailed

-- | A notification of a failure to start a service.
data ServiceCouldNotStart = ServiceCouldNotStart Node Service
  deriving (Typeable, Generic)

instance Binary ServiceCouldNotStart

-- | A notification of a service failure.
--
--  TODO: explain the difference with respect to 'ServiceFailed'.
data ServiceUncaughtException = ServiceUncaughtException Node Service String
  deriving (Generic, Typeable)

instance Binary ServiceUncaughtException

--------------------------------------------------------------------------------
-- Epoch messages                                                             --
--------------------------------------------------------------------------------

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
