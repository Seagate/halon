{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
-- |
-- Copyright : (C) 2016 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Contains all resources for RC subsystem of the Recovery coordinator.
module HA.Resources.RC where

import Control.Distributed.Process (ProcessId)
import HA.SafeCopy
import HA.Service (ServiceInfoMsg)
import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import HA.Resources.TH

import Data.ByteString (ByteString)
import Data.Hashable (Hashable(..))
import Data.Typeable (Typeable)
import GHC.Generics (Generic)

-- | Graph node representing current recovery coordinator.
newtype RC = RC { getRCVersion :: Int }
  deriving (Eq, Ord, Hashable, Generic, Typeable, Show)
deriveSafeCopy 0 'base ''RC

-- | Flag that shows that 'RC' instance is active one.
data Active = Active deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable Active
deriveSafeCopy 0 'base ''Active

-- | Representation of the processes that are subscriber to RC events.
data Subscriber = Subscriber ProcessId ByteString
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable Subscriber
deriveSafeCopy 0 'base ''Subscriber

-- | Link from 'ProcessId' to 'Subscriber' that can be used as an index.
data IsSubscriber = IsSubscriber
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable IsSubscriber
deriveSafeCopy 0 'base ''IsSubscriber

-- | Link from 'Subscriber' to 'RC'
data SubscribedTo = SubscribedTo
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable SubscribedTo
deriveSafeCopy 0 'base ''SubscribedTo

-- | Mark certain service as beign stopping on the node, to prevent its
-- restarts.
data Stopping = Stopping
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable Stopping
deriveSafeCopy 0 'base ''Stopping

-- XXX: is used to avoid orphan instances, possibly we need to fix that
-- by adding an instance in the halon package?

newtype SubProcessId = SubProcessId ProcessId
  deriving (Eq, Ord, Hashable, Generic, Typeable, Show)
deriveSafeCopy 0 'base ''SubProcessId

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
