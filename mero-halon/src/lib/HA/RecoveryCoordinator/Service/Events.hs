{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE StrictData                #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE TypeFamilies              #-}
-- |
-- Module    : HA.RecoveryCoordinator.Service.Events
-- Copyright : (C) 2015-2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- XXX: module documentation
module HA.RecoveryCoordinator.Service.Events
  ( -- * Start
    ServiceStartRequest(..)
  , ServiceStart(..)
  , ServiceStartRequestMsg(..)
  , ServiceStartResponse(..)
  , ServiceStartRequestResult(..)
  , ServiceStarted(..)
    -- * Stop
  , ServiceStopRequest(..)
  , ServiceStopRequestMsg(..)
  , ServiceStopRequestResult(..)
    -- * Status
  , ServiceStatusRequest(..)
  , ServiceStatusRequestMsg(..)
  , ServiceStatusResponse(..)
  , ServiceStatusResponseMsg(..)
    -- * Internal actions
  , ServiceStartedInternal(..)
  ) where

import HA.Service
import HA.Encode
import Control.Distributed.Process
import Control.Distributed.Process.Internal.Types ( remoteTable, processNode )
import Control.Distributed.Static (unstatic)
import Control.Monad.Reader ( asks )

import Data.Binary
import Data.Binary.Put (runPut)
import Data.Binary.Get (runGet)
import qualified Data.ByteString.Lazy as BS
import Data.Serialize.Get (runGetLazy)
import Data.Serialize.Put (runPutLazy)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)

import HA.ResourceGraph
import HA.Resources
import HA.SafeCopy

-- | A request to start a service on a given node.
data ServiceStartRequest =
    forall a. Configuration a =>
       ServiceStartRequest ServiceStart Node (Service a) a [ProcessId] -- XXX: remove listeners
  deriving Typeable

-- | Encoded version of 'ServiceStartRequest'.
newtype ServiceStartRequestMsg = ServiceStartRequestMsg BS.ByteString
  deriving (Typeable, Ord, Eq, Show)

instance ProcessEncode ServiceStartRequest where

  type BinRep ServiceStartRequest = ServiceStartRequestMsg

  encodeP (ServiceStartRequest start node svc@(Service _ _ d) cfg lis) =
    ServiceStartRequestMsg . runPut $
      put d >> put (runPutLazy $ safePut cfg) >> put (start, node, svc, lis)

  decodeP (ServiceStartRequestMsg bs) = let
      get_ :: RemoteTable -> Get ServiceStartRequest
      get_ rt = do
        d <- get
        case unstatic rt d of
          Right (SomeConfigurationDict (Dict :: Dict (Configuration s))) -> do
            bcfg <- get
            rest <- get
            let (start, node, service, lis) = extract rest
                extract :: (ServiceStart, Node, Service s, [ProcessId])
                        -> (ServiceStart, Node, Service s, [ProcessId])
                extract = id
            case runGetLazy safeGet bcfg of
              Right cfg ->
                return $ ServiceStartRequest start node service cfg lis
              Left err ->
                error $ "decodeP ServiceStartRequest: runGetLazy: " ++ err
          Left err -> error $ "decode ServiceStartRequest: " ++ err
    in do
      rt <- asks (remoteTable . processNode)
      return $ runGet (get_ rt) bs

-- | Repsonse from RC to any processes interested in service start.
data ServiceStartResponse =
      AttemptingToStart
    | AttemptingToRestart
    | AlreadyRunning
    | NodeUnknown
  deriving (Eq, Show, Generic, Typeable)

instance Binary ServiceStartResponse

-- | Restart service y/n
data ServiceStart = Start | Restart
  deriving (Eq, Show, Generic, Typeable)

instance Binary ServiceStart

-- | Has the request to start the service been accepted?
data ServiceStartRequestResult
       = ServiceStartRequestCancelled
       | ServiceStartRequestOk
       deriving (Eq, Show, Generic, Typeable)
instance Binary ServiceStartRequestResult

-- | A request to stop a service.
data ServiceStopRequest =
    forall a. Configuration a => ServiceStopRequest Node (Service a)
    deriving Typeable

-- | Encoded version of 'ServiceStopRequest'.
newtype ServiceStopRequestMsg = ServiceStopRequestMsg BS.ByteString
  deriving (Typeable, Show, Eq, Ord)

instance ProcessEncode ServiceStopRequest where
    type BinRep ServiceStopRequest = ServiceStopRequestMsg

    encodeP (ServiceStopRequest node svc@(Service _ _ d)) =
        ServiceStopRequestMsg $ runPut $ do
          put d
          put node
          put svc

    decodeP (ServiceStopRequestMsg bs) = do
        rt <- asks (remoteTable . processNode)
        return $ runGet (action rt) bs
      where
        action rt = do
            d <- get
            case unstatic rt d of
              Right (SomeConfigurationDict (Dict :: Dict (Configuration s))) ->
                do node               <- get
                   (svc :: Service s) <- get
                   return $ ServiceStopRequest node svc
              Left err -> error $ "decode ServiceStopRequest: " ++ err

-- | Has the service stop request been accepted?
data ServiceStopRequestResult
        = ServiceStopRequestCancelled
        | ServiceStopRequestOk
        | ServiceStopTimedOut
        deriving (Eq, Show, Generic, Typeable, Ord)

instance Binary ServiceStopRequestResult

-- | A request to query the status of service.
data ServiceStatusRequest =
    forall a. Configuration a =>
      ServiceStatusRequest Node (Service a) [ProcessId]
    deriving Typeable

-- | Encoded version of 'ServiceStatusRequest'.
newtype ServiceStatusRequestMsg = ServiceStatusRequestMsg BS.ByteString
  deriving (Typeable)

instance ProcessEncode ServiceStatusRequest where
    type BinRep ServiceStatusRequest = ServiceStatusRequestMsg

    encodeP (ServiceStatusRequest node svc@(Service _ _ d) lis) =
        ServiceStatusRequestMsg $ runPut $ do
          put d
          put node
          put svc
          put lis

    decodeP (ServiceStatusRequestMsg bs) = do
        rt <- asks (remoteTable . processNode)
        return $ runGet (action rt) bs
      where
        action rt = do
            d <- get
            case unstatic rt d of
              Right (SomeConfigurationDict (Dict :: Dict (Configuration s))) ->
                do node               <- get
                   (svc :: Service s) <- get
                   lis                <- get
                   return $ ServiceStatusRequest node svc lis
              Left err -> error $ "decode ServiceStatusRequest: " ++ err

-- | Report on the status of a service
data ServiceStatusResponse =
    SrvStatNotRunning
  | SrvStatStillRunning ProcessId
  | forall a. Configuration a =>
      SrvStatRunning (Static SomeConfigurationDict) ProcessId a
  | forall a. Configuration a =>
      SrvStatFailed (Static SomeConfigurationDict) a
  | SrvStatError String
  deriving Typeable

-- | Encoded version of 'ServiceStatusResponse'.
newtype ServiceStatusResponseMsg = ServiceStatusResponseMsg BS.ByteString
  deriving (Typeable, Binary)

instance ProcessEncode ServiceStatusResponse where
    type BinRep ServiceStatusResponse = ServiceStatusResponseMsg

    encodeP SrvStatNotRunning = ServiceStatusResponseMsg . runPut $
      put (0 :: Int)
    encodeP (SrvStatRunning d pid a) = ServiceStatusResponseMsg . runPut $
      put (1 :: Int) >> put d >> put pid >> put (runPutLazy $ safePut a)
    encodeP (SrvStatFailed d a) = ServiceStatusResponseMsg . runPut $
      put (2 :: Int) >> put d >> put (runPutLazy $ safePut a)
    encodeP (SrvStatError s) = ServiceStatusResponseMsg . runPut $
      put (3 :: Int) >> put s
    encodeP (SrvStatStillRunning pid) = ServiceStatusResponseMsg . runPut $
      put (4 :: Int) >> put pid

    decodeP (ServiceStatusResponseMsg bs) = do
        rt <- asks (remoteTable . processNode)
        return $ runGet (action rt) bs
      where
        action rt = do
          cstr <- get
          case cstr of
            (0 :: Int) -> return SrvStatNotRunning
            (3 :: Int) -> get >>= return . SrvStatError
            (4 :: Int) -> get >>= return . SrvStatStillRunning
            x | x > 3 || x < 0 -> error
              $ "decode ServiceStatusResponse: invalid "
                ++ "constructor value: " ++ show x
            x -> do
              d <- get
              case unstatic rt d of
                Right (SomeConfigurationDict (Dict :: Dict (Configuration s))) ->
                  do
                    case x of
                      1 -> do
                        pid <- get
                        bcfg <- get
                        case runGetLazy safeGet bcfg of
                          Right cfg -> return $ SrvStatRunning d pid (cfg :: s)
                          Left err -> error $
                            "decodeP SrvStatRunning: runGetLazy: " ++ err
                      2 -> do
                        bcfg <- get
                        case runGetLazy safeGet bcfg of
                          Right cfg -> return $ SrvStatFailed d (cfg :: s)
                          Left err -> error $
                            "decodeP SrvStatFailed: runGetLazy: " ++ err
                      _ -> error "impossible"
                Left err -> error $ "decode ServiceStatusResponse: " ++ err

-- | Internal notification about service being started and registered.
data ServiceStartedInternal a = ServiceStartedInternal Node a ProcessId
  deriving (Typeable, Generic, Show)

instance Binary a => Binary (ServiceStartedInternal a)

deriveSafeCopy 0 'base ''ServiceStartRequestMsg
deriveSafeCopy 0 'base ''ServiceStatusRequestMsg
deriveSafeCopy 0 'base ''ServiceStopRequestMsg
