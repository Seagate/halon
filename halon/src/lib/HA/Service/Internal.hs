{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE GADTs #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
module HA.Service.Internal
  ( Configuration(..)
  , spDict
  , SomeConfigurationDict(..)
  , someConfigDict
  , ExitReason(..)
  , Supports(..)
  , Service(..)
  , serviceLabel
  , ServiceInfo(..)
  , ServiceInfoMsg
  , getServiceInfoDict
  , remoteStartService
  , remoteStartService__static
  , remoteStartService__sdict
  , remoteStartService__tdict
  , remoteStopService
  , remoteStopService__static
  , remoteStopService__sdict
  , remoteStopService__tdict
  , someConfigDict__static
  , ServiceExit(..)
  , ServiceFailed(..)
  , ServiceUncaughtException(..)
  , HA.Service.Internal.__remoteTable
  ) where

import Control.Distributed.Process hiding (try, catch)
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Internal.Types ( remoteTable, processNode )
import Control.Distributed.Static ( unstatic )
import Control.Monad.Catch ( SomeException, try, catch, throwM )
import Control.Monad.Reader ( asks )

import Data.Aeson
import Data.Binary as Binary
import Data.Binary.Get (runGet)
import Data.Binary.Put (runPut)
import qualified Data.ByteString.Lazy as BS
import Data.Foldable (for_)
import Data.Function (on)
import Data.Hashable (Hashable, hashWithSalt)
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Options.Schema

import HA.Encode
import HA.EventQueue.Producer (promulgateWait)
import HA.ResourceGraph
import HA.Resources
import HA.Resources.TH

--------------------------------------------------------------------------------
-- Configuration                                                              --
--------------------------------------------------------------------------------

-- | A 'Configuration' instance defines the Schema defining configuration
--   data of type a.
class
  ( Binary a
  , Typeable a
  , Hashable a
  , ToJSON a
  , Resource (Service a)
  , Relation Supports Cluster (Service a)
  , Show a
  , Eq a
  ) => Configuration a where
    -- | Dictionary providing evidence of the serializability of a
    sDict :: Static (SerializableDict a)
    -- | Schema for this configuration object
    schema :: Schema a

deriving instance Typeable Configuration

-- | Another version of the 'sDict' that takes a proxy in order to infer right
-- type in case if it can't be infered from environment.
spDict :: Configuration a => proxy a -> Static (SerializableDict a)
spDict _ = sDict

-- | Reified evidence of a Configuration
data SomeConfigurationDict = forall a. SomeConfigurationDict (Dict (Configuration a))
  deriving (Typeable)

-- | Helper that allow to create static value that creates
-- 'SomeConfiguationDict'
someConfigDict :: Dict (Configuration a) -> SomeConfigurationDict
someConfigDict = SomeConfigurationDict

-- | A relation connecting the cluster to the services it supports.
data Supports = Supports
  deriving (Eq, Show, Typeable, Generic)
instance Binary Supports
instance Hashable Supports

-- | Service handle datatype. It's used to keep information about service and to
-- requests to the graph.
data Service a = Service
    { serviceName    :: String -- ^ Name of service.
    , serviceProcess :: Closure (a -> Process ())  -- ^ Process implementing service.
    , configDict :: Static (SomeConfigurationDict) -- ^ Configuration dictionary to use during encoding.
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

-- | Label used to register a service.
serviceLabel :: Service a -> String
serviceLabel svc = "service." ++ serviceName svc

-- | Information about a service. 'ServiceInfo' describes all information that
-- allow to identify and start service on the node.
data ServiceInfo = forall a. Configuration a => ServiceInfo (Service a) a
  deriving (Typeable)

-- | Monomorphised 'ServiceInfo' info about service, is used in messages sent over the network
-- and resource graph.
-- See 'ProcessEncode' for additional details.
newtype ServiceInfoMsg = ServiceInfoMsg BS.ByteString -- XXX: memoize StaticSomeConfigurationDict
  deriving (Typeable, Binary, Eq, Hashable, Show)

instance ProcessEncode ServiceInfo where
  type BinRep ServiceInfo = ServiceInfoMsg
  decodeP (ServiceInfoMsg bs) = let
      get_ :: RemoteTable -> Get ServiceInfo
      get_ rt = do
        d <- get
        case unstatic rt d of
          Right (SomeConfigurationDict (Dict :: Dict (Configuration s))) -> do
            rest <- get
            let (service, s) = extract rest
                extract :: (Service s, s)
                        -> (Service s, s)
                extract = id
            return $ ServiceInfo service s
          Left err -> error $ "decode ServiceExit: " ++ err
    in do
      rt <- asks (remoteTable . processNode)
      return $ runGet (get_ rt) bs

  encodeP (ServiceInfo svc@(Service _ _ d) s) = ServiceInfoMsg . runPut $
    put d >> put (svc, s)

-- | Extract ServiceDict info without full decoding of the 'ServiceInfoMsg'.
getServiceInfoDict :: ServiceInfoMsg -> Static SomeConfigurationDict
getServiceInfoDict (ServiceInfoMsg bs) = runGet get bs

--------------------------------------------------------------------------------
-- Mesages
--------------------------------------------------------------------------------

-- | Possible exit reason for the any service.
data ExitReason = Shutdown     -- ^ Shutdown service, interpreted like normal exit.
                | Fail         -- ^ Fail service.
                deriving (Eq, Show, Generic, Typeable)

instance Binary ExitReason

-- | A notification about service normal exit.
data ServiceExit = ServiceExit Node ServiceInfoMsg ProcessId
  deriving (Typeable, Generic)
instance Binary ServiceExit

-- | A notification of a service failure.
--
-- Service or another service decided that current service have failed, and
-- throw this exception.
data ServiceFailed = ServiceFailed Node ServiceInfoMsg ProcessId
  deriving (Typeable, Generic)
instance Binary ServiceFailed

-- | A notification of a service failure due to unexpected case.
--
-- In case if some exception was not caught when it should be, we notify RC
-- about it.
data ServiceUncaughtException = ServiceUncaughtException Node ServiceInfoMsg String ProcessId
  deriving (Typeable, Generic)
instance Binary ServiceUncaughtException

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

-- | Starts and registers a service in the current node.
-- Sends @ProcessId@ of the running service to the caller.
remoteStartService :: (ProcessId, ServiceInfoMsg) -> Process ()
remoteStartService (caller, msg) = do
    ServiceInfo svc conf <- decodeP msg
    let label = serviceLabel svc
        name  = serviceName svc
    self <- getSelfPid
    -- Register the service if it is not already registered.
    let whereisOrRegister = do
          regRes <- try $ register label self
          case regRes of
            Right () -> return self
            Left (ProcessRegistrationException _ _) ->  do
                whereis label >>= maybe whereisOrRegister return
    pid <- whereisOrRegister
    usend caller pid
    if pid == self
    then do
      say $ "[Service:" ++ name ++ "] starting at " ++ show pid
      say $ "[Service:" ++ name ++ "] config " ++ show conf
      prc <- unClosure (serviceProcess svc)
      ((prc conf >> (do
            say $ "[Service:" ++ name  ++ "] exited without setting that it's safe."
            promulgateWait $ ServiceFailed (Node (processNodeId pid)) msg pid))
         `catchExit` onExit name)
         `catch` unhandled pid name
    else say $ "[Service:" ++ name ++ "] already running at " ++ show pid
  where
    onExit name pid Shutdown = do
      let node = processNodeId pid
      say $ "[Service:" ++ name  ++ "] user required service stop."
      promulgateWait $ ServiceExit (Node node) msg pid
    onExit name pid Fail = do
      let node = processNodeId pid
      say $ "[Service:" ++ name  ++ "] service failed."
      promulgateWait $ ServiceFailed (Node node) msg pid
    unhandled :: ProcessId -> String -> SomeException -> Process ()
    unhandled pid name e = do
      let node = processNodeId pid
      say $ "[Service:" ++ name  ++ "] died because of exception: " ++ show e
      promulgateWait $ ServiceUncaughtException (Node node) msg (show e) pid
      throwM e -- rethrow exception, unfortunatelly it will be synchronous now.

-- | Stop service.
remoteStopService :: (ProcessId, String) -> Process ()
remoteStopService (caller, label) = do
  mpid <- whereis label
  for_ mpid $ \pid -> do
    mref <- monitor pid
    exit pid Shutdown
    receiveWait [ matchIf (\(ProcessMonitorNotification m _ _) -> m == mref)
                          (const $ return ())]
  usend caller ()

$(mkDicts
   [ ''ServiceInfoMsg]
   [ (''Node, ''Has, ''ServiceInfoMsg)
   ])
$(mkResRel
   [ ''ServiceInfoMsg ]
   [ (''Node, ''Has, ''ServiceInfoMsg)
   ]
   [ 'someConfigDict
   , 'remoteStartService
   , 'remoteStopService
   ]
   )
