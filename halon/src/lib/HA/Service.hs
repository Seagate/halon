-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Services are uniquely named on a given node by a string. For example
-- "ioservice" may identify the IO service running on a node.
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

module HA.Service
  (
    -- * Types
    Configuration
  , Service(..)
  , ServiceProcess(..)
  , Supports(..)
  , Runs(..)
  , Owns(..)
  , InstanceOf(..)
  , HasConf(..)
  , WantsConf(..)
  , ConfigRole(..)
  , ServiceName(..)
  , SomeConfigurationDict(..)
    -- * Functions
  , schema
  , sDict
  , readConfig
  , writeConfig
  , disconnectConfig
  , runningService
  , someConfigDict
  , someConfigDict__static
   -- * Messages
  , serviceLabel
  , remoteStartService
  , remoteStartService__static
  , remoteStartService__sdict
  , ProcessEncode
  , BinRep
  , encodeP
  , decodeP
  , DummyEvent(..)
  , ServiceFailed(..)
  , ServiceFailedMsg
  , ServiceExit(..)
  , ServiceExitMsg
  , ServiceStart(..)
  , ServiceStartRequest(..)
  , ServiceStartRequestMsg
  , ServiceStartResponse(..)
  , ServiceStarted(..)
  , ServiceStartedMsg
  , ServiceCouldNotStart(..)
  , ServiceCouldNotStartMsg
  , ServiceUncaughtException(..)
  , ServiceStopRequest(..)
  , ServiceStopRequestMsg
  , ServiceStatusRequest(..)
  , ServiceStatusRequestMsg
  , ServiceStatusResponse(..)
  , ServiceStatusResponseMsg
  , ExitReason(..)
   -- * CH Paraphenalia
  , HA.Service.__remoteTable
) where

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Internal.Types ( remoteTable, processNode )
import Control.Distributed.Static (unstatic)
import Control.Monad
import Control.Monad.Reader ( ask, asks )

import Data.Binary
import Data.Binary.Put (runPut)
import Data.Binary.Get (runGet)
import qualified Data.ByteString.Lazy as BS
import Data.Function (on)
import Data.List (foldl', intersect)
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
  , Relation HasConf (ServiceProcess a) a
  , Relation WantsConf (ServiceProcess a) a
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
  , Relation Supports Cluster (Service a)
  , Relation Runs Node (ServiceProcess a)
  , Relation InstanceOf (Service a) (ServiceProcess a)
  , Relation Owns (ServiceProcess a) ServiceName
  , Show a
  ) => Configuration a where

    -- | Dictionary providing evidence of the serializability of a
    sDict :: Static (SerializableDict a)

    -- | Schema for this configuration object
    schema :: Schema a

    readConfig :: ServiceProcess a -> ConfigRole -> Graph -> Maybe a
    default readConfig :: (DefaultGraphContext a)
                       => ServiceProcess a
                       -> ConfigRole
                       -> Graph
                       -> Maybe a
    readConfig svc role graph = case role of
        Current -> go HasConf
        Intended -> go WantsConf
      where
        go :: forall r . Relation r (ServiceProcess a) a => r -> Maybe a
        go r = case connectedTo svc r graph of
          a : [] -> Just a
          _ -> Nothing -- Zero or many config nodes found - err!

    writeConfig :: ServiceProcess a -> a -> ConfigRole -> Graph -> Graph
    default writeConfig :: (DefaultGraphContext a)
                        => ServiceProcess a
                        -> a
                        -> ConfigRole
                        -> Graph
                        -> Graph
    writeConfig svc conf Current =
      connect svc HasConf conf . newResource conf
    writeConfig svc conf Intended =
      connect svc WantsConf conf . newResource conf

    disconnectConfig :: ServiceProcess a -> ConfigRole -> Graph -> Graph
    default disconnectConfig :: (DefaultGraphContext a)
                             => ServiceProcess a
                             -> ConfigRole
                             -> Graph
                             -> Graph
    disconnectConfig svc role graph = case role of
        Current -> go HasConf
        Intended -> go WantsConf
      where
        go :: forall r . Relation r (ServiceProcess a) a => r -> Graph
        go r = case connectedTo svc r graph of
          (xs@(_ : _) :: [a]) -> let dc g x = disconnect svc r x g in
            foldl' dc graph xs
          _ -> graph

deriving instance Typeable Configuration

-- | Find the `ServiceProcess` corresponding to a running service on a node.
runningService :: forall a. Configuration a
               => Node
               -> Service a
               -> Graph
               -> Maybe (ServiceProcess a)
runningService n svc rg = case intersect s1 s2 of
    [sp] -> Just sp
    _ -> Nothing
  where
    s1 = (connectedTo n Runs rg :: [ServiceProcess a])
    s2 = (connectedTo svc InstanceOf rg :: [ServiceProcess a])

-- | Reified evidence of a Configuration
data SomeConfigurationDict = forall a. SomeConfigurationDict (Dict (Configuration a))
  deriving (Typeable)

someConfigDict :: Dict (Configuration a) -> SomeConfigurationDict
someConfigDict = SomeConfigurationDict

--------------------------------------------------------------------------------
-- Resources and Relations                                                    --
--------------------------------------------------------------------------------

-- | A Resource for the C-H process embodying a service on a node.
newtype ServiceProcess a = ServiceProcess ProcessId
  deriving (Eq, Show, Typeable, Binary, Hashable)

-- | A relation connecting a node to its current configuration.
data HasConf = HasConf
  deriving (Eq, Show, Typeable, Generic)

instance Binary HasConf
instance Hashable HasConf

-- | A relation connecting a node to its intended configuration.
data WantsConf = WantsConf
  deriving (Eq, Show, Typeable, Generic)

instance Binary WantsConf
instance Hashable WantsConf

-- | A relation connecting the cluster to the services it supports.
data Supports = Supports
  deriving (Eq, Show, Typeable, Generic)

instance Binary Supports
instance Hashable Supports

-- | A relation connecting a process to the Service it is an instance of.
data InstanceOf = InstanceOf
  deriving (Eq, Show, Typeable, Generic)

instance Binary InstanceOf
instance Hashable InstanceOf

-- | A relation connecting a ServiceProcess to the resources it owns.
data Owns = Owns
  deriving (Eq, Show, Typeable, Generic)

instance Binary Owns
instance Hashable Owns

-- | An identifier for services, unique across the resource graph.
newtype ServiceName = ServiceName {
    snString :: String
  } deriving (Eq, Ord, Show, Typeable, Binary, Hashable)

-- | A resource graph representation for services.
data Service a = Service
    { serviceName    :: ServiceName           -- ^ Name of service.
    , serviceProcess :: Closure (a -> Process ())  -- ^ Process implementing service.
    , configDict :: Static (SomeConfigurationDict)
    }
  deriving (Typeable, Generic)

instance Show (Service a) where
    show s = "Service " ++ (show $ serviceName s)

instance (Typeable a, Binary a) => Binary (Service a)

instance Eq (Service a) where
  (==) = (==) `on` serviceName

instance Ord (Service a) where
  compare = compare `on` serviceName

instance Hashable (Service a) where
  hashWithSalt s = (*3) . hashWithSalt s . serviceName

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

resourceDictServiceName :: Dict (Resource ServiceName)
resourceDictServiceName = Dict

--------------------------------------------------------------------------------
-- Service messages                                                           --
--------------------------------------------------------------------------------

data ExitReason = Shutdown     -- ^ Internal shutdown, for example bouncing service.
                | Reconfigure  -- ^ Service reconfiguration.
                | UserStop     -- ^ Shutdown requested by user.
                deriving (Eq, Show, Generic, Typeable)

instance Binary ExitReason

-- | Label used to register a service.
serviceLabel :: ServiceName -> String
serviceLabel sn = "service." ++ snString sn

-- | Starts and registers a service in the current node.
-- Sends @ProcessId@ of the running service to the caller.
remoteStartService :: (ProcessId, ServiceName) -> Process () -> Process ()
remoteStartService (caller, sn) p = do
    self <- getSelfPid
    -- Register the service if it is not already registered.
    let whereisOrRegister = do
          let label = serviceLabel sn
          regRes <- try $ register label self
          case regRes of
            Right () -> return self
            Left (ProcessRegistrationException _ _) ->  do
                whereis label >>= maybe whereisOrRegister return
    pid <- whereisOrRegister
    usend caller pid
    when (pid == self) $
      p `catchExit` onExit
  where
    onExit _ Shutdown = say $ "[Service " ++ snString sn ++ "] stopped."
    onExit _ Reconfigure = say $ "[Service " ++ snString sn ++ "] reconfigured."
    onExit _ UserStop = say $ "[Service " ++ snString sn ++ "] user required service stop."

remotable
  [ 'remoteStartService
  , 'someConfigDict
  , 'resourceDictServiceName
  ]

instance Resource ServiceName where
  resourceDict = $(mkStatic 'resourceDictServiceName)

-- | Type class to support encoding difficult types (e.g. existentials) using
--   Static machinery in the Process monad.
class ProcessEncode a where
  type BinRep a :: *
  encodeP :: a -> BinRep a
  decodeP :: BinRep a -> Process a

-- | Restart service y/n
data ServiceStart = Start | Restart
  deriving (Eq, Show, Generic, Typeable)

instance Hashable ServiceStart
instance Binary ServiceStart

-- | A request to start a service on a given node.
data ServiceStartRequest =
    forall a. Configuration a =>
      ServiceStartRequest ServiceStart Node (Service a) a [ProcessId]
  deriving Typeable

newtype ServiceStartRequestMsg = ServiceStartRequestMsg BS.ByteString
  deriving (Typeable, Binary)

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
      rt <- fmap (remoteTable . processNode) ask
      return $ runGet (get_ rt) bs

-- | Repsonse from RC to any processes interested in service start.
data ServiceStartResponse =
      AttemptingToStart
    | AttemptingToRestart
    | AlreadyRunning
    | NotAlreadyRunning
    | NodeUnknown
  deriving (Eq, Show, Generic, Typeable)

instance Hashable ServiceStartResponse
instance Binary ServiceStartResponse

-- | A notification of a service failure.
data ServiceFailed = forall a. Configuration a => ServiceFailed Node (Service a) ProcessId
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
            pid  <- get
            let (node, service) = extract rest
                extract :: (Node, Service s)
                        -> (Node, Service s)
                extract = id
            return $ ServiceFailed node service pid
          Left err -> error $ "decode ServiceFailed: " ++ err
    in do
      rt <- fmap (remoteTable . processNode) ask
      return $ runGet (get_ rt) bs

  encodeP (ServiceFailed node svc@(Service _ _ d) pid) = ServiceFailedMsg . runPut $
    put d >> put (node, svc) >> put pid

-- | A notification about service normal exit.
data ServiceExit = forall a. Configuration a => ServiceExit Node (Service a) ProcessId
  deriving (Typeable)

newtype ServiceExitMsg = ServiceExitMsg BS.ByteString
  deriving (Typeable, Binary)

instance ProcessEncode ServiceExit where

  type BinRep ServiceExit = ServiceExitMsg

  decodeP (ServiceExitMsg bs) = let
      get_ :: RemoteTable -> Get ServiceExit
      get_ rt = do
        d <- get
        case unstatic rt d of
          Right (SomeConfigurationDict (Dict :: Dict (Configuration s))) -> do
            rest <- get
            pid  <- get
            let (node, service) = extract rest
                extract :: (Node, Service s)
                        -> (Node, Service s)
                extract = id
            return $ ServiceExit node service pid
          Left err -> error $ "decode ServiceExit: " ++ err
    in do
      rt <- fmap (remoteTable . processNode) ask
      return $ runGet (get_ rt) bs

  encodeP (ServiceExit node svc@(Service _ _ d) pid) = ServiceExitMsg . runPut $
    put d >> put (node, svc) >> put pid


-- | An event which produces no action in the RC. Used for testing.
data DummyEvent = DummyEvent String
  deriving (Typeable, Generic)

instance Binary DummyEvent

-- | A notification of a successful service start.
data ServiceStarted = forall a. Configuration a
                    => ServiceStarted Node (Service a) a (ServiceProcess a)
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
            let (node, service, conf, sp) = extract rest
                extract :: (Node, Service s, s, ServiceProcess s)
                        -> (Node, Service s, s, ServiceProcess s)
                extract = id
            return $ ServiceStarted node service conf sp
          Left err -> error $ "decode ServiceStarted: " ++ err
    in do
      rt <- fmap (remoteTable . processNode) ask
      return $ runGet (get_ rt) bs

  encodeP (ServiceStarted node svc@(Service _ _ d) conf sp) = ServiceStartedMsg . runPut $
    put d >> put (node, svc, conf, sp)

-- | A notification of a failure to start a service.
data ServiceCouldNotStart = forall a. Configuration a
                          => ServiceCouldNotStart Node (Service a) a
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
            let (node, service, cfg) = extract rest
                extract :: (Node, Service s, s)
                        -> (Node, Service s, s)
                extract = id
            return $ ServiceCouldNotStart node service cfg
          Left err -> error $ "decode ServiceCouldNotStart: " ++ err
    in do
      rt <- fmap (remoteTable . processNode) ask
      return $ runGet (get_ rt) bs

  encodeP (ServiceCouldNotStart node svc@(Service _ _ d) cfg) =
    ServiceCouldNotStartMsg . runPut $ put d >> put (node, svc, cfg)

-- | A notification of a service failure.
--
--  TODO: explain the difference with respect to 'ServiceFailed'.
data ServiceUncaughtException = ServiceUncaughtException Node String String
    deriving (Typeable, Generic)

instance Binary ServiceUncaughtException

-- | A request to stop a service.
data ServiceStopRequest =
    forall a. Configuration a => ServiceStopRequest Node (Service a)
    deriving Typeable

newtype ServiceStopRequestMsg = ServiceStopRequestMsg BS.ByteString
  deriving (Typeable, Binary)

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
  | forall a. Configuration a =>
      SrvStatRunning (Static SomeConfigurationDict) ProcessId a
  | forall a. Configuration a =>
      SrvStatRestarting (Static SomeConfigurationDict) ProcessId a a
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
    encodeP (SrvStatRestarting d pid a b) = ServiceStatusResponseMsg . runPut $
      put (2 :: Int) >> put d >> put pid >> put a >> put b
    encodeP (SrvStatError s) = ServiceStatusResponseMsg . runPut $
      put (3 :: Int) >> put s

    decodeP (ServiceStatusResponseMsg bs) = do
        rt <- asks (remoteTable . processNode)
        return $ runGet (action rt) bs
      where
        action rt = do
          cstr <- get
          case cstr of
            (0 :: Int) -> return SrvStatNotRunning
            (3 :: Int) -> get >>= return . SrvStatError
            x | x > 3 || x < 0 -> error
              $ "decode ServiceStatusResponse: invalid "
                ++ "constructor value: " ++ show x
            x -> do
              d <- get
              case unstatic rt d of
                Right (SomeConfigurationDict (Dict :: Dict (Configuration s))) ->
                  do
                    pid        <- get
                    (cfg :: s) <- get
                    case x of
                      1 -> return $ SrvStatRunning d pid cfg
                      2 -> get >>= return . SrvStatRestarting d pid cfg
                      _ -> error "impossible"
                Left err -> error $ "decode ServiceStatusResponse: " ++ err
