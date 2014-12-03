-- |
-- Copyright: (C) 2014 Tweag I/O Limited
--
-- Types, lenses, and smart constructors used throughout the CEP framework.
--

{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DefaultSignatures          #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE PolyKinds                  #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}

{-# OPTIONS_GHC -fno-warn-orphans #-} -- Typeable Serializable, Eq/Ord Static

module Network.CEP.Types
  ( Some (..)
  , Some'
  , some
  , Instance (..)
  , Boring
  , (:&:) (..)
  , Broker
  , EventType ()
  , unEventType
  , eventTypeOf
  , Emittable (..)
  , Statically (..)
  , NetworkMessage (..)
  , payload
  , source
  , ack
  , SubscribeRequest (..)
  , PublishRequest (..)
  , eventType
  , NodeRemoval (..)
  , removedNode
  , BrokerReconf (..)
  , newBrokers
  , Ack (..)
  , ackMessage
  , ackSource ) where

import Network.CEP.Instances

import Control.Distributed.Process (Process, ProcessId, Static, unStatic)
import Control.Distributed.Process.Closure (remotable, mkStatic)
import Control.Distributed.Process.Serializable (Serializable)
import Control.Distributed.Static (staticApply)
import Control.Lens
import Data.Binary (Binary, encode)

import Data.Function (on)
import Data.Typeable (Typeable, Proxy)
import GHC.Generics (Generic)

type Broker = ProcessId

deriving instance Typeable Serializable

instance Typeable a => Eq  (Static a) where (==)    = on (==)    encode
instance Typeable a => Ord (Static a) where compare = on compare encode

someETInstance :: forall a. Instance (Statically Emittable) a -> Some' (Instance (Statically Emittable))
someETInstance Instance = Precisely (Instance :: Instance (Statically Emittable) a)

class Serializable a => Emittable a where
  type Sundries a :: *
  type Sundries a = ()
  sundries :: Proxy a -> Sundries a
  default sundries :: Proxy a -> ()
  sundries _ = ()
deriving instance Typeable Emittable

-- | A type that represents the type of a message.
--   Create them with 'eventTypeOf'.
newtype EventType = EventType (Static (Some' (Instance (Statically Emittable))))
  deriving (Show, Eq, Ord, Generic, Typeable, Binary)

-- Not sure about this returning Process.  Would rather have Processor s, but
-- needs module restructuring.
unEventType :: EventType
            -> (forall a. Instance (Statically Emittable) a -> b)
            -> Process b
unEventType (EventType bs) f = unStatic bs >>= \case
    (s :: Some' (Instance (Statically Emittable))) -> return $ some f s

-- | A type representing a message we will send over the network, tagged
--   with its source.
data NetworkMessage a = NetworkMessage
  { _payload :: !a
  , _ack     :: !Bool
  , _source  :: !ProcessId
  } deriving (Typeable, Show, Eq, Ord, Generic, Functor)
instance Binary a => Binary (NetworkMessage a)

-- We prefer monomorphic lenses over makeClassy on event types as
-- using polymorphic lenses would require users of publish/subscribe
-- to provide unwieldy explicit type signatures, possibly involving
-- scoped type variables.

makeLenses ''NetworkMessage

-- | A type representing a request for subscription to a particular event.
newtype SubscribeRequest = SubscribeRequest
  { _subscribeEventType :: EventType
  } deriving (Typeable, Show, Eq, Generic, Binary)

makeFields ''SubscribeRequest

-- | A type representing a request to publish a particular event.
newtype PublishRequest = PublishRequest
  { _publishEventType :: EventType
  } deriving (Typeable, Show, Eq, Generic, Binary)

makeFields ''PublishRequest

-- | A type representing a notification that a node is no longer present.
newtype NodeRemoval = NodeRemoval
  { _removedNode :: ProcessId
  } deriving (Typeable, Show, Eq, Generic, Binary)

makeLenses ''NodeRemoval

newtype BrokerReconf = BrokerReconf
  { _newBrokers :: [Broker]
  } deriving (Typeable, Show, Eq, Generic, Binary)

makeLenses ''BrokerReconf

data Ack a = Ack
  { _ackMessage :: a
  , _ackSource  :: !ProcessId
  } deriving (Typeable, Show, Eq, Generic)
instance Binary a => Binary (Ack a)

makeLenses ''Ack

instance Emittable SubscribeRequest
instance Emittable PublishRequest
instance Emittable NodeRemoval
instance Emittable BrokerReconf

sinstSubscribeRequest :: Instance (Statically Emittable) SubscribeRequest
sinstPublishRequest   :: Instance (Statically Emittable) PublishRequest
sinstNodeRemoval      :: Instance (Statically Emittable) NodeRemoval
sinstBrokerReconf     :: Instance (Statically Emittable) BrokerReconf
sinstSubscribeRequest = Instance
sinstPublishRequest   = Instance
sinstNodeRemoval      = Instance
sinstBrokerReconf     = Instance

remotable [ 'sinstSubscribeRequest
          , 'sinstPublishRequest
          , 'sinstNodeRemoval
          , 'sinstBrokerReconf
          , 'someETInstance
          ]

instance Statically Emittable SubscribeRequest where
  staticInstance = $(mkStatic 'sinstSubscribeRequest)
instance Statically Emittable PublishRequest where
  staticInstance = $(mkStatic 'sinstPublishRequest)
instance Statically Emittable NodeRemoval where
  staticInstance = $(mkStatic 'sinstNodeRemoval)
instance Statically Emittable BrokerReconf where
  staticInstance = $(mkStatic 'sinstBrokerReconf)


eventTypeOf :: forall proxy a. Statically Emittable a => proxy a -> EventType
eventTypeOf _ = EventType . staticApply $(mkStatic 'someETInstance)
              $ (staticInstance :: Static (Instance (Statically Emittable) a))
