-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- * Node agent interface types
--
-- Recovery coordinator imports this module to pattern-match on incomming
-- event messages. Events reported by monitors are of the 'ServiceFailed' type
-- or similar. As of the current design, 'ServiceId's are required in the
-- messages to identify the service.

{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module HA.Resources where

import Control.Distributed.Process

import HA.ResourceGraph
    ( Resource(..), Relation(..)
    , Some, ResourceDict, mkResourceDict, RelationDict, mkRelationDict )

import Control.Distributed.Process.Closure
import Control.Distributed.Process.Internal.Types
import Network.Transport (EndPointAddress(..))

import Data.ByteString ( ByteString )
import Data.Hashable (Hashable(..))
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Data.Binary (Binary)
import Data.Function (on)
import Data.Word (Word64)

--------------------------------------------------------------------------------
-- Resources                                                                  --
--------------------------------------------------------------------------------

-- | The root of the resource graph, useful to hang various global resources to.
data Cluster = Cluster
             deriving (Eq, Ord, Show, Typeable, Generic)

instance Binary Cluster
instance Hashable Cluster

data Service = Service
    { serviceName :: String
    , serviceProcess :: Closure (Process ()) }
    deriving (Typeable, Generic)

instance Eq Service where
    (==) = (==) `on` serviceName

instance Ord Service where
    compare = compare `on` serviceName

instance Binary Service

instance Hashable Service where
    hashWithSalt s = hashWithSalt s . serviceName

-- | A Resource Graph representation for compute nodes.
data Node = Node ProcessId
          deriving (Eq, Ord, Show, Typeable, Generic)

deriving instance Generic NodeId
deriving instance Generic ProcessId
deriving instance Generic EndPointAddress
deriving instance Generic LocalProcessId

instance Hashable NodeId
instance Hashable ProcessId
instance Hashable EndPointAddress
instance Hashable LocalProcessId

instance Hashable Node
instance Binary Node

-- | An identifier for epochs.
type EpochId = Word64

-- | A datatype for epochs which hold a state.
data Epoch a = Epoch { epochId :: EpochId
                     , epochState :: a }
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

-- | A relation connecting nodes to the services they run.
data Runs = Runs
         deriving (Show, Eq, Typeable, Generic)

instance Binary Runs
instance Hashable Runs

-- | Useful relation to attach global variables to the cluster.
data Has = Has
        deriving (Eq, Show, Typeable, Generic)

instance Binary Has
instance Hashable Has

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

resourceDictCluster,
    resourceDictNode,
    resourceDictService,
    resourceDictEpoch :: Some ResourceDict
resourceDictCluster = mkResourceDict (undefined :: Cluster)
resourceDictNode = mkResourceDict (undefined :: Node)
resourceDictService = mkResourceDict (undefined :: Service)
resourceDictEpoch = mkResourceDict (undefined :: Epoch ByteString)

relationDictRunsNodeService,
    relationDictHasClusterNode,
    relationDictHasClusterEpoch :: Some RelationDict
relationDictRunsNodeService = mkRelationDict (undefined :: (Runs,Node,Service))
relationDictHasClusterNode = mkRelationDict (undefined :: (Has, Cluster, Node))
relationDictHasClusterEpoch = mkRelationDict (undefined :: (Has, Cluster, Epoch ByteString))

remotable [ 'resourceDictCluster
          , 'resourceDictNode
          , 'resourceDictService
          , 'resourceDictEpoch
          , 'relationDictRunsNodeService
          , 'relationDictHasClusterNode
          , 'relationDictHasClusterEpoch ]

instance Resource Cluster where
  resourceDict _ = $(mkStatic 'resourceDictCluster)

instance Resource Node where
  resourceDict _ = $(mkStatic 'resourceDictNode)

instance Resource Service where
  resourceDict _ = $(mkStatic 'resourceDictService)

instance Resource (Epoch ByteString) where
  resourceDict _ = $(mkStatic 'resourceDictEpoch)

instance Relation Runs Node Service where
  relationDict _ = $(mkStatic 'relationDictRunsNodeService)

instance Relation Has Cluster Node where
  relationDict _ = $(mkStatic 'relationDictHasClusterNode)

instance Relation Has Cluster (Epoch ByteString) where
  relationDict _ = $(mkStatic 'relationDictHasClusterEpoch)

--------------------------------------------------------------------------------
-- Service messages                                                           --
--------------------------------------------------------------------------------

-- XXX Find better place for these NA -> EQ messages.

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
    { etr_source  :: ProcessId -- ^ pid of requesting service
    , etr_current :: EpochId
    , etr_target  :: EpochId
    } deriving (Typeable, Generic)

instance Binary EpochTransitionRequest

-- | Sent when the RC communicates an epoch transition.
data EpochTransition a = EpochTransition
    { et_current :: EpochId             -- ^ Starting epoch
    , et_target  :: EpochId             -- ^ Destination epoch
    , et_how     :: a                   -- ^ Instructions to reach target.
    } deriving (Typeable, Generic)

instance Binary a => Binary (EpochTransition a)
