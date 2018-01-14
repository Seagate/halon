{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StrictData            #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
-- |
-- Module    : HA.Resources.RC
-- Copyright : (C) 2016 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Contains all resources for RC subsystem of the Recovery coordinator.
module HA.Resources.RC where

import Control.Distributed.Process (ProcessId)
import Data.Hashable (Hashable(..))
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import HA.Aeson
import HA.Resources (Cluster(..), Has(..), Node_XXX2(..))
import HA.Resources.Castor (Is(..))
import HA.Resources.TH
  ( Cardinality(AtMostOne,Unbounded)
  , mkDicts
  , mkResRel
  , storageIndex
  )
import HA.SafeCopy
import HA.Service (ServiceInfoMsg)

-- | Graph node representing current recovery coordinator.
newtype RC = RC { getRCVersion :: Int }
  deriving (Eq, Generic, Hashable, Ord, Show, Typeable, ToJSON)

storageIndex ''RC "08cb2d5c-d2a7-4fe7-ac15-c4ab54ee8390"
deriveSafeCopy 0 'base ''RC

-- | Flag that shows that 'RC' instance is active one.
data Active = Active
  deriving (Eq, Generic, Ord, Show, Typeable)

instance Hashable Active
instance ToJSON Active

storageIndex ''Active "9abef7bb-6f44-4a8a-86cd-105573c7bc19"
deriveSafeCopy 0 'base ''Active

-- | Representation of the processes that are subscriber to RC events.
data Subscriber = Subscriber ProcessId ByteString64
  deriving (Eq, Generic, Ord, Show, Typeable)

instance Hashable Subscriber
instance ToJSON Subscriber

storageIndex ''Subscriber "c4cd4c12-7508-4332-a020-f59eb3946a87"
deriveSafeCopy 0 'base ''Subscriber

-- | Link from 'ProcessId' to 'Subscriber' that can be used as an index.
data IsSubscriber = IsSubscriber
  deriving (Eq, Generic, Ord, Show, Typeable)

instance Hashable IsSubscriber
instance ToJSON IsSubscriber

storageIndex ''IsSubscriber "8115b0fe-a62b-4e6b-8790-8aa53215ce62"
deriveSafeCopy 0 'base ''IsSubscriber

-- | Link from 'Subscriber' to 'RC'
data SubscribedTo = SubscribedTo
  deriving (Eq, Generic, Ord, Show, Typeable)

instance Hashable SubscribedTo
instance ToJSON SubscribedTo

storageIndex ''SubscribedTo "876c13cd-2c68-45d6-8bd6-fc0943d3772f"
deriveSafeCopy 0 'base ''SubscribedTo

-- | Mark certain service as beign stopping on the node, to prevent its
-- restarts.
data Stopping = Stopping
  deriving (Eq, Generic, Ord, Show, Typeable)

instance Hashable Stopping
instance ToJSON Stopping

storageIndex ''Stopping "eec463f4-299d-41d1-8af3-186a31b3fdb4"
deriveSafeCopy 0 'base ''Stopping

-- | Newtype wrapper for 'ProcessId' with 'SafeCopy' instance.
newtype SubProcessId = SubProcessId ProcessId
  deriving (Eq, Generic, Hashable, Ord, Show, Typeable, ToJSON)

storageIndex ''SubProcessId "8aa4c536-992e-4862-b489-6654cb38271a"
deriveSafeCopy 0 'base ''SubProcessId

$(mkDicts
  [ ''RC, ''Active, ''Subscriber, ''IsSubscriber, ''SubscribedTo
  , ''SubProcessId, ''Stopping
  ]
  [ -- Relationships connecting conf with other resources
    (''Cluster, ''Has, ''RC)
  , (''RC, ''Is, ''Active)
  , (''Subscriber, ''SubscribedTo, ''RC)
  , (''SubProcessId, ''IsSubscriber, ''Subscriber)
  , (''Node_XXX2, ''Stopping, ''ServiceInfoMsg)
  ])

$(mkResRel
  [ ''RC, ''Active, ''Subscriber, ''IsSubscriber, ''SubscribedTo
  , ''SubProcessId, ''Stopping
  ]
  [ -- Relationships connecting conf with other resources
    (''Cluster, AtMostOne, ''Has, AtMostOne, ''RC)
  , (''RC, AtMostOne, ''Is, AtMostOne, ''Active)
  , (''Subscriber, Unbounded, ''SubscribedTo, AtMostOne, ''RC)
  , (''SubProcessId, Unbounded, ''IsSubscriber, AtMostOne, ''Subscriber)
  , (''Node_XXX2, Unbounded, ''Stopping, Unbounded, ''ServiceInfoMsg)
  ]
  [])
