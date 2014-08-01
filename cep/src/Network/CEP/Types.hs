-- |
-- Copyright: (C) 2014 Tweag I/O Limited
-- 
-- Types, lenses, and smart constructors used throughout the CEP framework.
-- 

{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}

module Network.CEP.Types
  ( Broker
  , EventType ()
  , eventTypeOf
  , NetworkMessage (..)
  , payload
  , source
  , SubscribeRequest (..)
  , PublishRequest (..)
  , eventType
  , NodeRemoval (..)
  , removedNode
  , BrokerReconf (..)
  , newBrokers ) where

import Control.Distributed.Process (ProcessId)
import Control.Distributed.Process.Serializable
  (Fingerprint, fingerprint, encodeFingerprint, decodeFingerprint)
import Control.Lens
import Data.Binary (Binary, get, put)

import Control.Applicative ((<$>))
import Data.Typeable (Typeable)
import GHC.Generics (Generic)

type Broker = ProcessId

-- | A type that represents the type of a message.
--   Create them with 'eventTypeOf'.
newtype EventType = EventType Fingerprint
  deriving (Show, Eq, Ord)

instance Binary EventType where
  put (EventType f) = put $ encodeFingerprint f
  get = EventType . decodeFingerprint <$> get

-- | Get the 'EventType' given a proxy to that type.
eventTypeOf :: forall proxy a. Typeable a => proxy a -> EventType
eventTypeOf _ = EventType $ fingerprint (error "CEP::eventTypeOf" :: a)

-- | A type representing a message we will send over the network, tagged
--   with its source.
data NetworkMessage a = NetworkMessage
  { _payload :: !a
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
