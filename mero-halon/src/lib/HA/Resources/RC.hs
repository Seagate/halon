{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StrictData            #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
-- |
-- Module    : HA.Resources.RC
-- Copyright : (C) 2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Contains all resources for RC subsystem of the Recovery coordinator.
module HA.Resources.RC where

import           Control.Distributed.Process (ProcessId)
import           Data.Hashable (Hashable(..))
import           Data.Typeable (Typeable)
import           GHC.Generics (Generic)
import           HA.Aeson
import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import           HA.Resources.TH
import           HA.SafeCopy
import           HA.Service (ServiceInfoMsg)

-- | Graph node representing current recovery coordinator.
newtype RC = RC { getRCVersion :: Int }
  deriving (Eq, Ord, Hashable, Generic, Typeable, Show)
storageIndex ''RC "08cb2d5c-d2a7-4fe7-ac15-c4ab54ee8390"
deriveSafeCopy 0 'base ''RC
instance ToJSON RC

-- | Flag that shows that 'RC' instance is active one.
data Active = Active deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable Active
storageIndex ''Active "9abef7bb-6f44-4a8a-86cd-105573c7bc19"
deriveSafeCopy 0 'base ''Active
instance ToJSON Active

-- | Representation of the processes that are subscriber to RC events.
data Subscriber = Subscriber ProcessId ByteString64
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable Subscriber
storageIndex ''Subscriber "c4cd4c12-7508-4332-a020-f59eb3946a87"
deriveSafeCopy 0 'base ''Subscriber
instance ToJSON Subscriber

-- | Link from 'ProcessId' to 'Subscriber' that can be used as an index.
data IsSubscriber = IsSubscriber
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable IsSubscriber
storageIndex ''IsSubscriber "8115b0fe-a62b-4e6b-8790-8aa53215ce62"
deriveSafeCopy 0 'base ''IsSubscriber
instance ToJSON IsSubscriber

-- | Link from 'Subscriber' to 'RC'
data SubscribedTo = SubscribedTo
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable SubscribedTo
storageIndex ''SubscribedTo "876c13cd-2c68-45d6-8bd6-fc0943d3772f"
deriveSafeCopy 0 'base ''SubscribedTo
instance ToJSON SubscribedTo

-- | Mark certain service as beign stopping on the node, to prevent its
-- restarts.
data Stopping = Stopping
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable Stopping
storageIndex ''Stopping "eec463f4-299d-41d1-8af3-186a31b3fdb4"
deriveSafeCopy 0 'base ''Stopping
instance ToJSON Stopping

-- | Newtype wrapper for 'ProcessId' with 'SafeCopy' instance.
newtype SubProcessId = SubProcessId ProcessId
  deriving (Eq, Ord, Hashable, Generic, Typeable, Show)
storageIndex ''SubProcessId "8aa4c536-992e-4862-b489-6654cb38271a"
deriveSafeCopy 0 'base ''SubProcessId
instance ToJSON SubProcessId

$(mkDicts
  [ ''RC, ''Active, ''Subscriber, ''IsSubscriber, ''SubscribedTo, ''SubProcessId
  , ''Stopping
  ]
  [ -- Relationships connecting conf with other resources
    (''R.Cluster, ''R.Has, ''RC)
  , (''RC, ''R.Is, ''Active)
  , (''Subscriber, ''SubscribedTo, ''RC)
  , (''SubProcessId, ''IsSubscriber, ''Subscriber)
  , (''R.Node, ''Stopping, ''ServiceInfoMsg)
  ])

$(mkResRel
  [ ''RC, ''Active, ''Subscriber, ''IsSubscriber, ''SubscribedTo, ''SubProcessId
  , ''Stopping
  ]
  [ -- Relationships connecting conf with other resources
    (''R.Cluster, AtMostOne, ''R.Has, AtMostOne, ''RC)
  , (''RC, AtMostOne, ''R.Is, AtMostOne, ''Active)
  , (''Subscriber, Unbounded, ''SubscribedTo, AtMostOne, ''RC)
  , (''SubProcessId, Unbounded, ''IsSubscriber, AtMostOne, ''Subscriber)
  , (''R.Node, Unbounded, ''Stopping, Unbounded, ''ServiceInfoMsg)
  ]
  [])
