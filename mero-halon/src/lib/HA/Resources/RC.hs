{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
-- |
-- Copyright : (C) 2016 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Contains all resources for RC subsystem of the Recovery coordinator.
module HA.Resources.RC where

import Control.Distributed.Process (ProcessId)
import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import HA.Resources.TH

import Data.Binary (Binary(..))
import Data.ByteString (ByteString)
import Data.Hashable (Hashable(..))
import Data.Typeable (Typeable)
import GHC.Generics (Generic)

-- | Graph node representing current recovery coordinator.
newtype RC = RC { getRCVersion :: Int }
  deriving (Eq, Ord, Hashable, Generic, Typeable, Binary, Show)

-- | Flag that shows that 'RC' instance is active one.
data Active = Active deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable Active
instance Binary   Active

-- | Representation of the processes that are subscriber to RC events.
data Subscriber = Subscriber ProcessId {- Fingerprint -} ByteString
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable Subscriber
instance Binary   Subscriber

-- | Link from 'ProcessId' to 'Subscriber' that can be used as an index.
data IsSubscriber = IsSubscriber
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable IsSubscriber
instance Binary   IsSubscriber

-- | Link from 'Subscriber' to 'RC'
data SubscribedTo = SubscribedTo
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable SubscribedTo
instance Binary   SubscribedTo

-- XXX: is used to avoid orphan instances, possibly we need to fix that
-- by adding an instance in the halon package?

newtype SubProcessId = SubProcessId ProcessId
  deriving (Eq, Ord, Hashable, Generic, Typeable, Binary, Show)

$(mkDicts
  [ ''RC, ''Active, ''Subscriber, ''IsSubscriber, ''SubscribedTo, ''SubProcessId
  ]
  [ -- Relationships connecting conf with other resources
    (''R.Cluster, ''R.Has, ''RC)
  , (''RC, ''R.Is, ''Active)
  , (''Subscriber, ''SubscribedTo, ''RC)
  , (''SubProcessId, ''IsSubscriber, ''Subscriber)
  ])

$(mkResRel
  [ ''RC, ''Active, ''Subscriber, ''IsSubscriber, ''SubscribedTo, ''SubProcessId
  ]
  [ -- Relationships connecting conf with other resources
    (''R.Cluster, ''R.Has, ''RC)
  , (''RC, ''R.Is, ''Active)
  , (''Subscriber, ''SubscribedTo, ''RC)
  , (''SubProcessId, ''IsSubscriber, ''Subscriber)
  ]
  [])
