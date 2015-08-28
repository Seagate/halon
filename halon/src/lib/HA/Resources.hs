-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE QuasiQuotes #-}
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
import HA.Resources.TH

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

-- Type alias for purposes of giving a quotable name.
type EpochByteString = Epoch ByteString

$(mkDicts
  [''Cluster, ''Node, ''EpochByteString]
  [ (''Cluster, ''Has, ''Node)
  , (''Cluster, ''Has, ''EpochByteString)
  ])
$(mkResRel
  [''Cluster, ''Node, ''EpochByteString]
  [ (''Cluster, ''Has, ''Node)
  , (''Cluster, ''Has, ''EpochByteString)
  ]
  []
  )

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
