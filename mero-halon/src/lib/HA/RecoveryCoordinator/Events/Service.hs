{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE TypeFamilies #-}


-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- XXX: module documentation
module HA.RecoveryCoordinator.Events.Service
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
import Data.Typeable (Typeable)
import GHC.Generics (Generic)

import HA.ResourceGraph
import HA.Resources

-- | A request to start a service on a given node.
data ServiceStartRequest =
    forall a. Configuration a =>
       ServiceStartRequest ServiceStart Node (Service a) a [ProcessId] -- XXX: remove listeners
  deriving Typeable

newtype ServiceStartRequestMsg = ServiceStartRequestMsg BS.ByteString
  deriving (Typeable, Binary, Ord, Eq, Show)

instance ProcessEncode ServiceStartRequest where

  type BinRep ServiceStartRequest = ServiceStartRequestMsg

  encodeP (ServiceStartRequest start node svc@(Service _ _ d) cfg lis) =
    ServiceStartRequestMsg . runPut $ put d >> put (start, node, svc, cfg, lis)

  decodeP (ServiceStartRequestMsg bs) = let
      get_ :: RemoteTable -> Get ServiceStartRequest
      get_ rt = do
        d <- get
        case unstatic rt d of
          Right (SomeConfigurationDict (Dict :: Dict (Configuration s))) -> do
            rest <- get
            let (start, node, service, cfg, lis) = extract rest
                extract :: (ServiceStart, Node, Service s, s, [ProcessId])
                        -> (ServiceStart, Node, Service s, s, [ProcessId])
                extract = id
            return $ ServiceStartRequest start node service cfg lis
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

data ServiceStartRequestResult
       = ServiceStartRequestCancelled
       | ServiceStartRequestOk
       deriving (Eq, Show, Generic, Typeable)
instance Binary ServiceStartRequestResult

-- | A request to stop a service.
data ServiceStopRequest =
    forall a. Configuration a => ServiceStopRequest Node (Service a)
    deriving Typeable

newtype ServiceStopRequestMsg = ServiceStopRequestMsg BS.ByteString
  deriving (Typeable, Binary, Show, Eq, Ord)

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

data ServiceStopRequestResult
        = ServiceStopRequestCancelled
        | ServiceStopRequestOk
        deriving (Eq, Show, Generic, Typeable)

instance Binary ServiceStopRequestResult

-- | A request to query the status of service.
data ServiceStatusRequest =
    forall a. Configuration a =>
      ServiceStatusRequest Node (Service a) [ProcessId]
    deriving Typeable

newtype ServiceStatusRequestMsg = ServiceStatusRequestMsg BS.ByteString
  deriving (Typeable, Binary)

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

data ServiceStatusResponse =
    SrvStatNotRunning
  | SrvStatStillRunning ProcessId
  | forall a. Configuration a =>
      SrvStatRunning (Static SomeConfigurationDict) ProcessId a
  | forall a. Configuration a =>
      SrvStatFailed (Static SomeConfigurationDict) a
  | SrvStatError String
  deriving Typeable

newtype ServiceStatusResponseMsg = ServiceStatusResponseMsg BS.ByteString
  deriving (Typeable, Binary)

instance ProcessEncode ServiceStatusResponse where
    type BinRep ServiceStatusResponse = ServiceStatusResponseMsg

    encodeP SrvStatNotRunning = ServiceStatusResponseMsg . runPut $
      put (0 :: Int)
    encodeP (SrvStatRunning d pid a) = ServiceStatusResponseMsg . runPut $
      put (1 :: Int) >> put d >> put pid >> put a
    encodeP (SrvStatFailed d a) = ServiceStatusResponseMsg . runPut $
      put (2 :: Int) >> put d >> put a
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
                      1 -> do pid <- get
                              (cfg :: s) <- get
                              return $ SrvStatRunning d pid cfg
                      2 -> do (cfg :: s) <- get
                              return $ SrvStatFailed d cfg
                      _ -> error "impossible"
                Left err -> error $ "decode ServiceStatusResponse: " ++ err