-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Services are uniquely named on a given node by a string. For example
-- "ioservice" may identify the IO service running on a node.
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module HA.Service
  (
    -- * Types
    Configuration
  , Service(..)
  , Runs(..)
  , HasConf(..)
  , WantsConf(..)
  , ConfigRole(..)
  , ServiceName
  , SomeConfigurationDict(..)
    -- * Functions
  , schema
  , sDict
  , readConfig
  , writeConfig
  , disconnectConfig
  , updateConfig
  , someConfigDict
  , someConfigDict__static
   -- * Messages
  , ProcessEncode
  , BinRep
  , encodeP
  , decodeP
  , ServiceFailed(..)
  , ServiceFailedMsg
  , ServiceStartRequest(..)
  , ServiceStartRequestMsg
  , ServiceStarted(..)
  , ServiceStartedMsg
  , ServiceCouldNotStart(..)
  , ServiceCouldNotStartMsg
  , ServiceUncaughtException(..)
  , NodeFilter(..)
  , ConfigurationUpdate(..)
  , ConfigurationUpdateMsg
   -- * Empty service stuff
  , emptyConfigDict
  , emptyConfigDict__static
  , emptySDict
  , emptySDict__static
   -- * CH Paraphenalia
  , HA.Service.__remoteTable
) where

import Control.Applicative (pure)
import Control.Arrow ((>>>))
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Internal.Types ( remoteTable, processNode )
import Control.Distributed.Static (unstatic)
import Control.Monad.Reader ( ask )

import Data.Binary
import Data.Binary.Put (runPut)
import Data.Binary.Get (runGet)
import qualified Data.ByteString.Lazy as BS
import Data.Function (on)
import Data.List (foldl')
import Data.Hashable (Hashable, hashWithSalt)
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Options.Schema

import HA.ResourceGraph
import HA.Resources

--------------------------------------------------------------------------------
-- Configuration                                                              --
--------------------------------------------------------------------------------

-- | Default context
type DefaultGraphContext a =
  ( Resource a
  , Relation HasConf (Service a) a
  , Relation WantsConf (Service a) a
  )

-- | The configuration role - either current or intended.
data ConfigRole = Current -- ^ Current configuration
                | Intended -- ^ Intended configuration
  deriving (Eq, Show, Typeable)

-- | A 'Configuration' instance defines the Schema defining configuration
--   data of type a.
class
  ( Binary a
  , Typeable a
  , Hashable a
  , Resource (Service a)
  , Relation Runs Node (Service a)
  ) => Configuration a where

    -- | Dictionary providing evidence of the serializability of a
    sDict :: Static (SerializableDict a)

    -- | Schema for this configuration object
    schema :: Schema a

    readConfig :: Service a -> ConfigRole -> Graph -> Maybe a
    default readConfig :: (DefaultGraphContext a)
                       => Service a
                       -> ConfigRole
                       -> Graph
                       -> Maybe a
    readConfig svc role graph = case role of
        Current -> go HasConf
        Intended -> go WantsConf
      where
        go :: forall r . Relation r (Service a) a => r -> Maybe a
        go r = case connectedTo svc r graph of
          a : [] -> Just a
          _ -> Nothing -- Zero or many config nodes found - err!

    writeConfig :: Service a -> a -> ConfigRole -> Graph -> Graph
    default writeConfig :: (DefaultGraphContext a)
                        => Service a
                        -> a
                        -> ConfigRole
                        -> Graph
                        -> Graph
    writeConfig svc conf Current =
      connect svc HasConf conf . newResource conf
    writeConfig svc conf Intended =
      connect svc WantsConf conf . newResource conf

    disconnectConfig :: Service a -> ConfigRole -> Graph -> Graph
    default disconnectConfig :: (DefaultGraphContext a)
                             => Service a
                             -> ConfigRole
                             -> Graph
                             -> Graph
    disconnectConfig svc role graph = case role of
        Current -> go HasConf
        Intended -> go WantsConf
      where
        go :: forall r . Relation r (Service a) a => r -> Graph
        go r = case connectedTo svc r graph of
          (xs@(_ : _) :: [a]) -> let dc g x = disconnect svc r x g in
            foldl' dc graph xs
          _ -> graph

    updateConfig :: Service a
                 -> Graph
                 -> Graph
    default updateConfig :: (DefaultGraphContext a)
                         => Service a
                         -> Graph
                         -> Graph
    updateConfig svc rg = rg' where
      -- Update RG to change 'Wants' config to 'Has'
      oldConf = (connectedTo svc HasConf rg :: [a])
      newConf = (connectedTo svc WantsConf rg :: [a])
      rg' = case (oldConf, newConf) of
        ([old], [new]) -> disconnect svc HasConf old >>>
                          disconnect svc WantsConf new >>>
                          connect svc HasConf new $ rg
        ([], [new])    -> disconnect svc WantsConf new >>>
                          connect svc HasConf new $ rg
        _              -> rg

deriving instance Typeable Configuration

-- | Reified evidence of a Configuration
data SomeConfigurationDict = forall a. SomeConfigurationDict (Dict (Configuration a))
  deriving (Typeable)

someConfigDict :: Dict (Configuration a) -> SomeConfigurationDict
someConfigDict = SomeConfigurationDict

--------------------------------------------------------------------------------
-- Resources and Relations                                                    --
--------------------------------------------------------------------------------

data HasConf = HasConf
  deriving (Eq, Show, Typeable, Generic)

instance Binary HasConf
instance Hashable HasConf

-- | A relation connecting a node to its intended configuration.
data WantsConf = WantsConf
  deriving (Eq, Show, Typeable, Generic)

instance Binary WantsConf
instance Hashable WantsConf

-- | An identifier for services, unique across the resource graph.
type ServiceName = String

-- | A resource graph representation for services.
data Service a = Service
    { serviceName    :: ServiceName           -- ^ Name of service.
    , serviceProcess :: Closure (a -> Process ())  -- ^ Process implementing service.
    , configDict :: Static (SomeConfigurationDict)
    }
  deriving (Typeable, Generic)

instance (Typeable a, Binary a) => Binary (Service a)

instance Eq (Service a) where
  (==) = (==) `on` serviceName

instance Ord (Service a) where
  compare = compare `on` serviceName

instance Hashable (Service a) where
  hashWithSalt s = hashWithSalt s . serviceName

---- Empty services                                                         ----

emptyConfigDict :: Dict (Configuration ())
emptyConfigDict = Dict

emptySDict :: SerializableDict ()
emptySDict = SerializableDict

--TODO Can we auto-gen this whole section?
resourceDictServiceEmpty :: Dict (Resource (Service ()))
resourceDictConfigItemEmpty :: Dict (Resource ())
resourceDictServiceEmpty = Dict
resourceDictConfigItemEmpty = Dict

relationDictRunsNodeServiceEmpty :: Dict (Relation Runs Node (Service ()))
relationDictWantsServiceEmptyConfigItemEmpty :: Dict (Relation WantsConf (Service ()) ())
relationDictHasServiceEmptyConfigItemEmpty :: Dict (Relation HasConf (Service ()) ())
relationDictRunsNodeServiceEmpty = Dict
relationDictWantsServiceEmptyConfigItemEmpty = Dict
relationDictHasServiceEmptyConfigItemEmpty = Dict

remotable
  [ 'someConfigDict
  , 'emptyConfigDict
  , 'emptySDict
  , 'resourceDictServiceEmpty
  , 'resourceDictConfigItemEmpty
  , 'relationDictRunsNodeServiceEmpty
  , 'relationDictHasServiceEmptyConfigItemEmpty
  , 'relationDictWantsServiceEmptyConfigItemEmpty
  ]

instance Resource (Service ()) where
  resourceDict = $(mkStatic 'resourceDictServiceEmpty)

instance Resource () where
  resourceDict = $(mkStatic 'resourceDictConfigItemEmpty)

instance Relation Runs Node (Service ()) where
  relationDict = $(mkStatic 'relationDictRunsNodeServiceEmpty)

instance Relation HasConf (Service ()) () where
  relationDict = $(mkStatic 'relationDictHasServiceEmptyConfigItemEmpty)

instance Relation WantsConf (Service ()) () where
  relationDict = $(mkStatic 'relationDictWantsServiceEmptyConfigItemEmpty)

instance Configuration () where
  schema = pure ()
  sDict = $(mkStatic 'emptySDict)

--------------------------------------------------------------------------------
-- Service messages                                                           --
--------------------------------------------------------------------------------

-- | Type class to support encoding difficult types (e.g. existentials) using
--   Static machinery in the Process monad.
class ProcessEncode a where
  type BinRep a :: *
  encodeP :: a -> BinRep a
  decodeP :: BinRep a -> Process a

-- | A request to start a service on a given node.
data ServiceStartRequest =
    forall a. Configuration a => ServiceStartRequest Node (Service a) a
  deriving Typeable

newtype ServiceStartRequestMsg = ServiceStartRequestMsg BS.ByteString
  deriving (Typeable, Binary)

instance ProcessEncode ServiceStartRequest where

  type BinRep ServiceStartRequest = ServiceStartRequestMsg

  encodeP (ServiceStartRequest node svc@(Service _ _ d) cfg) =
    ServiceStartRequestMsg . runPut $ put d >> put (node, svc, cfg)

  decodeP (ServiceStartRequestMsg bs) = let
      get_ :: RemoteTable -> Get ServiceStartRequest
      get_ rt = do
        d <- get
        case unstatic rt d of
          Right (SomeConfigurationDict (Dict :: Dict (Configuration s))) -> do
            rest <- get
            let (node, service, cfg) = extract rest
                extract :: (Node, Service s, s)
                        -> (Node, Service s, s)
                extract = id
            return $ ServiceStartRequest node service cfg
          Left err -> error $ "decode ServiceStartRequest: " ++ err
    in do
      rt <- fmap (remoteTable . processNode) ask
      return $ runGet (get_ rt) bs

-- | A notification of a service failure.
data ServiceFailed = forall a. Configuration a => ServiceFailed Node (Service a)
  deriving (Typeable)

newtype ServiceFailedMsg = ServiceFailedMsg BS.ByteString
  deriving (Typeable, Binary)

instance ProcessEncode ServiceFailed where

  type BinRep ServiceFailed = ServiceFailedMsg

  decodeP (ServiceFailedMsg bs) = let
      get_ :: RemoteTable -> Get ServiceFailed
      get_ rt = do
        d <- get
        case unstatic rt d of
          Right (SomeConfigurationDict (Dict :: Dict (Configuration s))) -> do
            rest <- get
            let (node, service) = extract rest
                extract :: (Node, Service s)
                        -> (Node, Service s)
                extract = id
            return $ ServiceFailed node service
          Left err -> error $ "decode ServiceFailed: " ++ err
    in do
      rt <- fmap (remoteTable . processNode) ask
      return $ runGet (get_ rt) bs

  encodeP (ServiceFailed node svc@(Service _ _ d)) = ServiceFailedMsg . runPut $
    put d >> put (node, svc)

-- | A notification of a successful service start.
data ServiceStarted = forall a. Configuration a
                    => ServiceStarted Node (Service a)
  deriving (Typeable)

newtype ServiceStartedMsg = ServiceStartedMsg BS.ByteString
  deriving (Typeable, Binary)

instance ProcessEncode ServiceStarted where

  type BinRep ServiceStarted = ServiceStartedMsg

  decodeP (ServiceStartedMsg bs) = let
      get_ :: RemoteTable -> Get ServiceStarted
      get_ rt = do
        d <- get
        case unstatic rt d of
          Right (SomeConfigurationDict (Dict :: Dict (Configuration s))) -> do
            rest <- get
            let (node, service) = extract rest
                extract :: (Node, Service s)
                        -> (Node, Service s)
                extract = id
            return $ ServiceStarted node service
          Left err -> error $ "decode ServiceStarted: " ++ err
    in do
      rt <- fmap (remoteTable . processNode) ask
      return $ runGet (get_ rt) bs

  encodeP (ServiceStarted node svc@(Service _ _ d)) = ServiceStartedMsg . runPut $
    put d >> put (node, svc)

-- | A notification of a failure to start a service.
data ServiceCouldNotStart = forall a. Configuration a
                          => ServiceCouldNotStart Node (Service a)
  deriving (Typeable)

newtype ServiceCouldNotStartMsg = ServiceCouldNotStartMsg BS.ByteString
  deriving (Typeable, Binary)

instance ProcessEncode ServiceCouldNotStart where

  type BinRep ServiceCouldNotStart = ServiceCouldNotStartMsg

  decodeP (ServiceCouldNotStartMsg bs) = let
      get_ :: RemoteTable -> Get ServiceCouldNotStart
      get_ rt = do
        d <- get
        case unstatic rt d of
          Right (SomeConfigurationDict (Dict :: Dict (Configuration s))) -> do
            rest <- get
            let (node, service) = extract rest
                extract :: (Node, Service s)
                        -> (Node, Service s)
                extract = id
            return $ ServiceCouldNotStart node service
          Left err -> error $ "decode ServiceCouldNotStart: " ++ err
    in do
      rt <- fmap (remoteTable . processNode) ask
      return $ runGet (get_ rt) bs

  encodeP (ServiceCouldNotStart node svc@(Service _ _ d)) =
    ServiceCouldNotStartMsg . runPut $ put d >> put (node, svc)

newtype NodeFilter = NodeFilter [NodeId]
  deriving (Binary, Eq, Generic, Show, Typeable)

data ConfigurationUpdate = forall a. Configuration a =>
    ConfigurationUpdate EpochId a (Service a) NodeFilter
  deriving (Typeable)

newtype ConfigurationUpdateMsg = ConfigurationUpdateMsg BS.ByteString
  deriving (Typeable, Binary)

instance ProcessEncode ConfigurationUpdate where

  type BinRep ConfigurationUpdate = ConfigurationUpdateMsg

  decodeP (ConfigurationUpdateMsg bs) = let
      get_ :: RemoteTable -> Get ConfigurationUpdate
      get_ rt = do
        d <- get
        case unstatic rt d of
          Right (SomeConfigurationDict (Dict :: Dict (Configuration s))) -> do
            rest <- get
            let (epoch, a, svc, fltr) = extract rest
                extract :: (EpochId, s, Service s, NodeFilter)
                        -> (EpochId, s, Service s, NodeFilter)
                extract = id
            return $ ConfigurationUpdate epoch a svc fltr
          Left err -> error $ "decode ConfigurationUpdate: " ++ err
    in do
      rt <- fmap (remoteTable . processNode) ask
      return $ runGet (get_ rt) bs

  encodeP (ConfigurationUpdate epoch a svc@(Service _ _ d) fltr) =
    ConfigurationUpdateMsg . runPut $ put d >> put (epoch, a, svc, fltr)

-- | A notification of a service failure.
--
--  TODO: explain the difference with respect to 'ServiceFailed'.
data ServiceUncaughtException = ServiceUncaughtException Node String String
    deriving (Typeable, Generic)

instance Binary ServiceUncaughtException
