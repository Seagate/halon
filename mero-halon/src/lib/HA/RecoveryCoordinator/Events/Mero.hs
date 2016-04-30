-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
module HA.RecoveryCoordinator.Events.Mero
   ( SyncComplete(..)
   , NewMeroClient(..)
   , NewMeroClientProcessed(..)
   , NewMeroServer(..)
   , StopMeroServer(..)
   -- * Requests
   , GetSpielAddress(..)
   -- * State changes
   , AnyStateSet(..)
   , AnyStateChange(..)
   , InternalObjectStateChange(..)
   , InternalObjectStateChangeMsg(..)
   , stateSet
   )
   where

import HA.Encode (ProcessEncode(..))
import HA.Resources
import HA.Resources.Castor
import HA.Resources.Mero.Note

import Control.Applicative (some)
import Control.Distributed.Process (ProcessId, RemoteTable, Static)
import Control.Distributed.Process.Internal.Types ( remoteTable, processNode )
import Control.Distributed.Static (unstatic)
import Control.Monad.Reader (ask)

import Data.Binary
import Data.Binary.Put (runPut)
import Data.Binary.Get (runGet)
import qualified Data.ByteString.Lazy as BS
import Data.Constraint (Dict(..))
import Data.Foldable (traverse_)
import Data.Typeable
import Data.UUID
import GHC.Generics

data SyncComplete = SyncComplete UUID
      deriving (Eq, Show, Typeable, Generic)

instance Binary SyncComplete

-- | New mero client was connected.
data NewMeroClient = NewMeroClient Node
      deriving (Eq, Show, Typeable, Generic)

instance Binary NewMeroClient

-- | New mero server was connected.
data NewMeroServer = NewMeroServer Node
      deriving (Eq, Show, Typeable, Generic)

instance Binary NewMeroServer

data StopMeroServer = StopMeroServer Node
       deriving (Eq, Show, Typeable, Generic)
instance Binary StopMeroServer

-- | Event about processing 'NewMeroClient' event.
data NewMeroClientProcessed = NewMeroClientProcessed Host
       deriving (Eq, Show, Typeable, Generic)

instance Binary NewMeroClientProcessed

data GetSpielAddress = GetSpielAddress ProcessId
       deriving (Eq, Show, Typeable, Generic)
instance Binary GetSpielAddress

-- | Universally quantified state 'set' request.
--   Typically, one creates a state 'set' request, then
--   resolves it against the graph, which will yield
--   a state change event.
data AnyStateSet =
  forall a. HasConfObjectState a => AnyStateSet a (StateCarrier a)
  deriving Typeable

-- | Create a state 'set' request.
stateSet :: HasConfObjectState a
         => a
         -> StateCarrier a
         -> AnyStateSet
stateSet = AnyStateSet

-- | Universally quantified state 'change' event.
data AnyStateChange =
  forall a. HasConfObjectState a =>
    AnyStateChange {
        asc_object :: a
      , asc_old_state :: StateCarrier a
      , asc_new_state :: StateCarrier a
      , asc_dict :: Static SomeHasConfObjectStateDict
      }
  deriving (Typeable)

-- | Event sent when the state of an object changes internally to Halon.
--   This event should be sent *after* the state of the references objects
--   has changed in the resource graph.
newtype InternalObjectStateChange = InternalObjectStateChange [AnyStateChange]
  deriving (Monoid, Typeable)

newtype InternalObjectStateChangeMsg =
    InternalObjectStateChangeMsg BS.ByteString
  deriving (Binary, Typeable)

instance ProcessEncode InternalObjectStateChange where
  type BinRep InternalObjectStateChange = InternalObjectStateChangeMsg

  decodeP (InternalObjectStateChangeMsg bs) = let
      get_ :: RemoteTable -> Get [AnyStateChange]
      get_ rt = some $ do
        d <- get
        case unstatic rt d of
          Right (SomeHasConfObjectStateDict
                  (Dict :: Dict (HasConfObjectState s))) -> do
            rest <- get
            let (obj, old, new) = extract rest
                extract :: (s, StateCarrier s, StateCarrier s)
                        -> (s, StateCarrier s, StateCarrier s)
                extract = id
            return $ AnyStateChange obj old new d
          Left err -> error $ "decode InternalObjectStateChange: " ++ err
    in do
      rt <- fmap (remoteTable . processNode) ask
      return . InternalObjectStateChange $ runGet (get_ rt) bs

  encodeP (InternalObjectStateChange xs) =
      InternalObjectStateChangeMsg . runPut $ traverse_ go xs
    where
      go (AnyStateChange obj old new dict) = put dict >> put (obj, old, new)
