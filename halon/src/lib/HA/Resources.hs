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

module HA.Resources
  ( Cluster(..)
  , Has(..)
  , Runs(..)
  , Node_XXX2(..)
  , EpochId(..)
  , RecoverNode(..)
  , HA.Resources.__remoteTable
  , HA.Resources.__resourcesTable
  ) where

import Control.Distributed.Process
import Data.Binary
import Data.Hashable (Hashable(..))
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import HA.Aeson
import HA.Resources.TH
import HA.SafeCopy

--------------------------------------------------------------------------------
-- Resources                                                                  --
--------------------------------------------------------------------------------

-- | The root of the resource graph.
data Cluster = Cluster
  deriving (Eq, Ord, Show, Typeable, Generic)
instance Hashable Cluster
storageIndex ''Cluster "67850c56-c077-4e43-a985-310bdea0b4a1"
deriveSafeCopy 0 'base ''Cluster
instance ToJSON Cluster

-- | A resource graph representation for nodes.
newtype Node_XXX2 = Node_XXX2 NodeId
  deriving (Eq, Ord, Show, Typeable, Generic, Hashable)
instance ToJSON Node_XXX2
instance FromJSON Node_XXX2
storageIndex ''Node_XXX2 "43ab6bb3-5bfe-4de8-838d-489584b1456c"
deriveSafeCopy 0 'base ''Node_XXX2

-- | An identifier for epochs.
newtype EpochId = EpochId Word64
  deriving (Eq, Ord, Show, Typeable, Generic, Hashable)
storageIndex ''EpochId "8c4d4b29-0c24-4bc8-8ab5-e6b3a1f2cc96"
deriveSafeCopy 0 'base ''EpochId
instance ToJSON EpochId

--------------------------------------------------------------------------------
-- Relations                                                                  --
--------------------------------------------------------------------------------

-- | A relation connecting the cluster to global resources, such as nodes and
-- epochs.
data Has = Has
  deriving (Eq, Ord, Show, Typeable, Generic)

instance Hashable Has
storageIndex ''Has "c912f510-1829-4df0-873d-4a960ff1ff4e"
deriveSafeCopy 0 'base ''Has
instance ToJSON Has

-- | A relation connecting a node to the services it runs.
data Runs = Runs
  deriving (Eq, Show, Typeable, Generic)
storageIndex ''Runs "8a53e367-8746-4814-aa3e-fb29c5432119"
deriveSafeCopy 0 'base ''Runs
instance Hashable Runs
instance ToJSON Runs

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

-- Type alias for purposes of giving a quotable name.
-- type EpochByteString = Epoch ByteString

$(mkDicts
  [''Cluster, ''Node_XXX2, ''EpochId, ''Has, ''Runs]
  [ (''Cluster, ''Has, ''Node_XXX2)
  , (''Cluster, ''Has, ''EpochId)
  ])
$(mkResRel
  [''Cluster, ''Node_XXX2, ''EpochId, ''Has, ''Runs]
  [ (''Cluster, AtMostOne, ''Has, Unbounded, ''Node_XXX2)
  , (''Cluster, AtMostOne, ''Has, AtMostOne, ''EpochId)
  ]
  []
  )

-- | Sent when a node goes down and we need to try to recover it
newtype RecoverNode = RecoverNode Node_XXX2
  deriving (Typeable, Generic, Show, Eq, Ord)
deriveSafeCopy 0 'base ''RecoverNode
