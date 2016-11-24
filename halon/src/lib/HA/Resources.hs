-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module HA.Resources where

import Control.Distributed.Process
import Data.Binary
import Data.Hashable (Hashable(..))
import Data.Typeable (Typeable)
import GHC.Generics (Generic)

import HA.Resources.TH
import HA.SafeCopy

--------------------------------------------------------------------------------
-- Resources                                                                  --
--------------------------------------------------------------------------------

-- | The root of the resource graph.
data Cluster = Cluster
  deriving (Eq, Ord, Show, Typeable, Generic)
instance Hashable Cluster
deriveSafeCopy 0 'base ''Cluster


-- | A resource graph representation for nodes.
data Node = Node NodeId
  deriving (Eq, Ord, Show, Typeable, Generic)
instance Hashable Node
deriveSafeCopy 0 'base ''Node


-- | An identifier for epochs.
newtype EpochId = EpochId Word64
  deriving (Eq, Ord, Show, Typeable, Generic, Hashable)
deriveSafeCopy 0 'base ''EpochId

--------------------------------------------------------------------------------
-- Relations                                                                  --
--------------------------------------------------------------------------------

-- | A relation connecting the cluster to global resources, such as nodes and
-- epochs.
data Has = Has
  deriving (Eq, Show, Typeable, Generic)

instance Hashable Has
deriveSafeCopy 0 'base ''Has

-- | A relation connecting a node to the services it runs.
data Runs = Runs
  deriving (Eq, Show, Typeable, Generic)

deriveSafeCopy 0 'base ''Runs
instance Hashable Runs

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

-- Type alias for purposes of giving a quotable name.
-- type EpochByteString = Epoch ByteString

$(mkDicts
  [''Cluster, ''Node, ''EpochId]
  [ (''Cluster, ''Has, ''Node)
  , (''Cluster, ''Has, ''EpochId)
  ])
$(mkResRel
  [''Cluster, ''Node, ''EpochId]
  [ (''Cluster, AtMostOne, ''Has, Unbounded, ''Node)
  , (''Cluster, AtMostOne, ''Has, AtMostOne, ''EpochId)
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

-- | Sent when a node goes down and we need to try to recover it
newtype RecoverNode = RecoverNode Node
  deriving (Typeable, Generic, Show, Eq, Ord)
deriveSafeCopy 0 'base ''RecoverNode
