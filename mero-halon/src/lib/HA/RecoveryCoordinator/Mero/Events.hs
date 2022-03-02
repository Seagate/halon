{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE TypeFamilies              #-}
{-# LANGUAGE TypeOperators             #-}
{-# LANGUAGE ViewPatterns              #-}
-- |
-- Module    : HA.RecoveryCoordinator.Mero.Events
-- Copyright : (C) 2016-2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Events for the mero RC.
module HA.RecoveryCoordinator.Mero.Events
  ( ForceObjectStateUpdateRequest(..)
  , ForceObjectStateUpdateReply(..)
  , UpdateResult(..)
  , SyncComplete(..)
  , NewMeroClientProcessed(..)
  , NewMeroServer(..)
  -- * Requests
  , GetSpielAddress(..)
  -- * Jobs
  , AbortSNSOperation(..)
  , AbortSNSOperationResult(..)
  , GetFailureVector(..)
  , QuiesceSNSOperation(..)
  , QuiesceSNSOperationResult(..)
  , RestartSNSOperationRequest(..)
  , RestartSNSOperationResult(..)
  -- * State changes
  , AnyStateSet(..)
  , AnyStateChange(..)
  , InternalObjectStateChange(..)
  , InternalObjectStateChangeMsg(..)
  , stateSet
  -- * Exceptions
  , WorkerIsNotAvailableException(..)
  ) where

import           Control.Applicative (many)
import           Control.Distributed.Process (ProcessId, RemoteTable, Static, SendPort)
import           Control.Distributed.Process.Internal.Types (processNode, remoteTable)
import           Control.Distributed.Static (unstatic)
import           Control.Exception (Exception)
import           Control.Monad.Reader (ask)
import           Data.Binary
import           Data.Binary.Get (runGet)
import           Data.Binary.Put (runPut)
import qualified Data.ByteString.Lazy as BS
import           Data.Constraint (Dict(..))
import           Data.Foldable (traverse_)
import           Data.Hashable (Hashable)
import           Data.Serialize.Get (runGetLazy)
import           Data.Serialize.Put (runPutLazy)
import           Data.Typeable
import           Data.UUID
import           GHC.Generics
import           HA.Aeson
import           HA.Encode (ProcessEncode(..))
import           HA.RecoveryCoordinator.Mero.Transitions
import qualified HA.Resources as R (Node(..))
import qualified HA.Resources.Castor as Cas (Host(..))
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note
import           HA.SafeCopy
import           Mero.ConfC (Fid)
import           Mero.Notification.HAState (Note(..))

-- | Request force update of the configuration object state.
data ForceObjectStateUpdateRequest = ForceObjectStateUpdateRequest
  [(Fid, String)]
  (SendPort ForceObjectStateUpdateReply)
  deriving (Generic, Typeable, Show)

-- | Result of the update operation
data UpdateResult
      = Success         -- ^ Operation completed succesfully
      | ObjectNotFound  -- ^ Object to update was not found
      | DictNotFound    -- ^ Object can't be updated
      | ParseFailed     -- ^ Failed to parse object state.
      deriving (Generic, Typeable, Show)

-- | Reply to the 'ForceObjectStateUpdateRequest'
newtype ForceObjectStateUpdateReply = ForceObjectStateUpdateReply [(Fid, UpdateResult)]
  deriving (Generic, Typeable, Show)

-- | Local sync to confd has completed.
data SyncComplete = SyncComplete UUID
      deriving (Eq, Show, Typeable, Generic)
instance Binary SyncComplete

-- | New mero server was connected.
data NewMeroServer = NewMeroServer R.Node
                   | NewMeroServerFailure R.Node
      deriving (Eq, Show, Typeable, Generic)
instance Binary NewMeroServer

-- | Event about processing 'NewMeroClient' event.
data NewMeroClientProcessed = NewMeroClientProcessed Cas.Host
       deriving (Eq, Show, Typeable, Generic)

instance Binary NewMeroClientProcessed

-- | Request for 'SpielAddress'.
data GetSpielAddress = GetSpielAddress
       { entrypointProcessFid :: Fid
       , entrypointProfileFid :: Fid
       , entrypointRequester  :: ProcessId
       } deriving (Eq, Show, Typeable, Generic)

-- | Universally quantified state transition request. Typically, one
-- creates a state 'set' request, then resolves it against the graph,
-- which will yield a state change event.
data AnyStateSet =
  forall a. HasConfObjectState a => AnyStateSet a (Transition a)
  deriving Typeable

-- | Create a state 'set' request.
stateSet :: HasConfObjectState a
         => a
         -> Transition a
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

deriving instance Show AnyStateChange

instance Eq AnyStateChange where
  AnyStateChange (a :: a) oa na _ == AnyStateChange (b :: b) ob nb _ =
    case eqT of
      Just (Refl :: a :~: b) -> a == b && oa == ob && na == nb
      _ -> False

-- | Event sent when the state of an object changes internally to Halon.
--   This event should be sent *after* the state of the references objects
--   has changed in the resource graph.
newtype InternalObjectStateChange = InternalObjectStateChange [AnyStateChange]
  deriving (Monoid, Typeable, Show)

-- | Encoded version of 'InternalObjectStateChange'.
newtype InternalObjectStateChangeMsg = InternalObjectStateChangeMsg ByteString64
  deriving (Typeable, Eq, Show, Ord, Hashable, Generic)
instance ToJSON InternalObjectStateChangeMsg

instance ProcessEncode InternalObjectStateChange where
  type BinRep InternalObjectStateChange = InternalObjectStateChangeMsg

  decodeP (InternalObjectStateChangeMsg (BS64 (BS.fromStrict -> bs))) = let
      get_ :: RemoteTable -> Get [AnyStateChange]
      get_ rt = many $ do
        d <- get
        case unstatic rt d of
          Right (SomeHasConfObjectStateDict
                  (Dict :: Dict (HasConfObjectState s))) -> do
            bobj <- get
            case runGetLazy safeGet bobj of
              Right obj -> do
                rest <- get
                let (old, new) = extract rest
                    extract :: (StateCarrier s, StateCarrier s)
                            -> (StateCarrier s, StateCarrier s)
                    extract = id
                return $ AnyStateChange (obj :: s) old new d
              Left err -> error $
                "decodeP InternalObjectStateChange: runGetLazy: " ++ err
          Left err -> error $ "decode InternalObjectStateChange: " ++ err
    in do
      rt <- fmap (remoteTable . processNode) ask
      return . InternalObjectStateChange $ runGet (get_ rt) bs

  encodeP (InternalObjectStateChange xs) =
      InternalObjectStateChangeMsg . BS64 . BS.toStrict . runPut $ traverse_ go xs
    where
      go (AnyStateChange obj old new dict) =
        put dict >> put (runPutLazy $ safePut obj) >> put (old, new)

-- | Request abort on the given pool.
data AbortSNSOperation = AbortSNSOperation M0.Pool UUID
  deriving (Eq, Show, Ord, Typeable, Generic)

-- | Reply to SNS operation abort.
data AbortSNSOperationResult
          = AbortSNSOperationOk M0.Pool -- ^ Operation  abort succesfull.
          | AbortSNSOperationFailure M0.Pool String -- ^ Operation abort completed with failure.
          | AbortSNSOperationSkip M0.Pool -- ^ Operation abort was skipped because no SNS operation was running.
  deriving (Eq, Show, Ord, Typeable, Generic)

instance Binary AbortSNSOperationResult

-- | Request SNS quiesce on the given 'M0.Pool'.
newtype QuiesceSNSOperation = QuiesceSNSOperation M0.Pool
  deriving (Eq, Show, Ord, Typeable, Generic)

-- | Result of SNS quiesce request.
data QuiesceSNSOperationResult
          = QuiesceSNSOperationOk M0.Pool
          | QuiesceSNSOperationFailure M0.Pool String
          | QuiesceSNSOperationSkip M0.Pool
  deriving (Eq, Show, Ord, Typeable, Generic)
instance Binary QuiesceSNSOperationResult

-- | Request restart of the SNS operation on the given pool.
data RestartSNSOperationRequest = RestartSNSOperationRequest M0.Pool UUID
  deriving (Eq, Show, Ord, Typeable, Generic)

-- | Result of SNS restart request.
data RestartSNSOperationResult =
    RestartSNSOperationSuccess M0.Pool
  | RestartSNSOperationFailed M0.Pool String
  | RestartSNSOperationSkip M0.Pool
  deriving (Eq, Show, Ord, Typeable, Generic)
instance Binary RestartSNSOperationResult

-- | Failure vector request.
data GetFailureVector = GetFailureVector
    Fid  -- ^ pool fid
    (SendPort (Maybe [Note]))
  deriving (Eq, Show, Typeable, Generic)

-- | The endpoint hasn't been initialised yet so the m0 worker is not
-- available yet.
data WorkerIsNotAvailableException = WorkerIsNotAvailable
  deriving (Show, Typeable, Generic)
instance Exception WorkerIsNotAvailableException
instance Binary WorkerIsNotAvailableException

deriveSafeCopy 0 'base ''AbortSNSOperation
deriveSafeCopy 0 'base ''ForceObjectStateUpdateReply
deriveSafeCopy 0 'base ''ForceObjectStateUpdateRequest
deriveSafeCopy 0 'base ''GetFailureVector
deriveSafeCopy 0 'base ''GetSpielAddress
deriveSafeCopy 0 'base ''InternalObjectStateChangeMsg
deriveSafeCopy 0 'base ''QuiesceSNSOperation
deriveSafeCopy 0 'base ''RestartSNSOperationRequest
deriveSafeCopy 0 'base ''UpdateResult
