{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs                  #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE RankNTypes             #-}
{-# LANGUAGE TemplateHaskell        #-}
{-# LANGUAGE TypeFamilies           #-}
{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}
-- |
-- Copyright : (C) 2016-2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Halon-internal service machinery.
module HA.Service.Internal
  ( Configuration(..)
  , spDict
  , SomeConfigurationDict(..)
  , someConfigDict
  , ExitReason(..)
  , Supports(..)
  , Service(..)
  , ServiceState
  , ServiceFunctions(..)
  , NextStep(..)
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
  , ServiceStopNotRunning(..)
  , HA.Service.Internal.__remoteTable
  , HA.Service.Internal.__resourcesTable
  , HasInterface(..)
  ) where

import           Control.Distributed.Process hiding (try, catch, mask, onException)
import           Control.Distributed.Process.Closure
import           Control.Distributed.Process.Internal.Types ( remoteTable, processNode )
import           Control.Distributed.Static ( unstatic )
import           Control.Monad.Catch ( try, mask, onException )
import           Control.Monad.Reader ( asks )
import           Data.Binary as Binary
import           Data.Function (fix, on)
import           Data.Functor (void)
import           Data.Hashable (Hashable, hashWithSalt)
import qualified Data.Serialize as Serialize
import           Data.Typeable (Typeable)
import           GHC.Generics (Generic)
import           HA.Aeson
import           HA.Debug
import           HA.Encode
import           HA.EventQueue.Producer (promulgateWait)
import           HA.ResourceGraph
import           HA.Resources
import           HA.Resources.TH
import           HA.SafeCopy
import           HA.Service.Interface
import           Options.Schema

--------------------------------------------------------------------------------
-- Configuration                                                              --
--------------------------------------------------------------------------------

-- | A 'Configuration' instance defines the Schema defining configuration
--   data of type a.
class
  ( SafeCopy a
  , Typeable a
  , Hashable a
  , ToJSON a
  , Resource (Service a)
  , Relation Supports Cluster (Service a)
  , Show a
  , Binary a
  , Eq a
  , HasInterface a
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

-- | Internal state of the service. This state is kept while service is running,
-- and can be queried by other parties.
type family ServiceState a :: *

-- | Service handle datatype. It's used to keep information about service and to
-- requests to the graph.
data Service a = Service
    { serviceName    :: String -- ^ Name of service.
    , serviceProcess :: Closure (ServiceFunctions a)
    , configDict :: Static SomeConfigurationDict -- ^ Configuration dictionary to use during encoding.
    }
  deriving (Typeable, Generic)

instance Typeable a => SafeCopy (Service a) where
  getCopy = contain $
    Service <$> safeGet
            <*> fmap Binary.decode Serialize.get
            <*> fmap Binary.decode Serialize.get
  putCopy (Service n p d) = contain $ do
    safePut n
    Serialize.put (Binary.encode p)
    Serialize.put (Binary.encode d)

instance Show (Service a) where
    show s = "Service " ++ (show $ serviceName s)

instance (Typeable a) => Binary (Service a)

instance Eq (Service a) where
  (==) = (==) `on` serviceName

instance Ord (Service a) where
  compare = compare `on` serviceName

instance Hashable (Service a) where
  hashWithSalt s = (*3) . hashWithSalt s . serviceName

-- | Serialise service name only.
instance ToJSON (Service a) where
  toJSON (Service { serviceName = n }) = object ["serviceName" .= n]

class ( Show (ToSvc c), Typeable (ToSvc c)
      , Show (FromSvc c), Typeable (FromSvc c), Binary (FromSvc c)
      ) => HasInterface c where
  type ToSvc c :: *
  type FromSvc c :: *
  getInterface :: Service c -> Interface (ToSvc c) (FromSvc c)

data ServiceFunctions a = ServiceFunctions
  { _serviceBootstrap :: a -> Process (Either String (ServiceState a))
  -- ^ Service bootstrap function. It's run just after service is registered,
  --   but before it's considered started. Bootstrap should care about
  --   resource finalization in case of service failure.
  , _serviceMainloop  :: a -> ServiceState a -> Process [Match (NextStep, ServiceState a)]
  -- ^ Mainloop of the service. All handlers in match should be quite fast
  --   in order to not block process execution for a long time, so it can
  --   reply to the common messages.
  , _serviceTeardown :: a -> ServiceState a -> Process ()
  -- ^ Teardown service and clear all it's resources. This function is run
  --   if service considered as closing, either normally or abnormally.
  , _serviceStarted :: a -> ServiceState a -> Process ()
  -- ^ Additional notification when service is started and announced to RC.
  }

-- | Label used to register a service.
serviceLabel :: Service a -> String
serviceLabel svc = "service." ++ serviceName svc

data NextStep = Continue
              | Teardown
              | Failure

-- | A relation connecting the cluster to the services it supports.
data Supports = Supports
  deriving (Eq, Show, Ord, Typeable, Generic)
instance Hashable Supports
storageIndex ''Supports "330e72d2-746a-418d-a824-23afd7f54f95"
deriveSafeCopy 0 'base ''Supports
instance ToJSON Supports

-- | Information about a service. 'ServiceInfo' describes all information that
-- allow to identify and start service on the node.
data ServiceInfo = forall a. Configuration a => ServiceInfo (Service a) a
  deriving (Typeable)

-- | Monomorphised 'ServiceInfo' info about service, is used in messages sent over the network
-- and resource graph.
-- See 'ProcessEncode' for additional details.
newtype ServiceInfoMsg = ServiceInfoMsg ByteString64 -- XXX: memoize StaticSomeConfigurationDict
  deriving (Typeable, Eq, Hashable, Show, Generic)
storageIndex ''ServiceInfoMsg "c935f0fc-064e-4c75-be10-106b9ff3da43"
deriveSafeCopy 0 'base ''ServiceInfoMsg
instance ToJSON ServiceInfoMsg

instance ProcessEncode ServiceInfo where
  type BinRep ServiceInfo = ServiceInfoMsg
  decodeP (ServiceInfoMsg (BS64 bs)) = let
      get_ :: RemoteTable -> Serialize.Get ServiceInfo
      get_ rt = do
        bd <- Serialize.get
        case unstatic rt (Binary.decode bd) of
          Right (SomeConfigurationDict (Dict :: Dict (Configuration s))) -> do
            rest <- safeGet
            let (service, s) = extract rest
                extract :: (Service s, s)
                        -> (Service s, s)
                extract = id
            return $ ServiceInfo service s
          Left err -> error $ "decode ServiceExit: " ++ err
    in do
      rt <- asks (remoteTable . processNode)
      case Serialize.runGet (get_ rt) bs of
        Right m -> return m
        Left err -> error $ "decodeP ServiceInfo: " ++ err

  encodeP (ServiceInfo svc@(Service _ _ d) s) =
    ServiceInfoMsg . BS64 . Serialize.runPut $
      Serialize.put (Binary.encode d) >> safePut (svc, s)

-- | Extract ServiceDict info without full decoding of the 'ServiceInfoMsg'.
getServiceInfoDict :: ServiceInfoMsg -> Static SomeConfigurationDict
getServiceInfoDict (ServiceInfoMsg (BS64 bs)) =
    case Serialize.runGet Serialize.get bs of
      Right bd -> Binary.decode bd
      Left err -> error $ "getServiceInfoDict: " ++ err

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
deriveSafeCopy 0 'base ''ServiceExit

-- | A notification of a service failure.
--
-- Service or another service decided that current service have failed, and
-- throw this exception.
data ServiceFailed = ServiceFailed Node ServiceInfoMsg ProcessId
  deriving (Typeable, Generic)
deriveSafeCopy 0 'base ''ServiceFailed

-- | A notification of a service failure due to unexpected case.
--
-- In case if some exception was not caught when it should be, we notify RC
-- about it.
data ServiceUncaughtException = ServiceUncaughtException Node ServiceInfoMsg String ProcessId
  deriving (Typeable, Generic)
deriveSafeCopy 0 'base ''ServiceUncaughtException

-- | A notification of service stop failure due to service is not
-- running at all.
data ServiceStopNotRunning = ServiceStopNotRunning Node String
  deriving (Typeable, Generic)
deriveSafeCopy 0 'base ''ServiceStopNotRunning

data Result b = AlreadyRunning ProcessId
              | ServiceStarted (Either String b)

-- | Run process service.
remoteStartService :: (SendPort ProcessId, ServiceInfoMsg) -> Process ()
remoteStartService (replyCh, msg) = do
    ServiceInfo svc conf <- decodeP msg
    mask $ go svc conf (serviceName svc)
  where
    go :: Configuration a => Service a -> a -> String -> (forall b . Process b -> Process b) -> Process ()
    go svc conf name release = do
      self <- getSelfPid
      serviceLog $ "starting at " ++ show self
      serviceLog $ "config " ++ show conf
      -- Bootstrap service
      let runBootstrap bootstrap =
           let label = serviceLabel svc
               whereisOrRegister = do
                 regRes <- try $ register label self
                 case regRes of
                   Right () -> return self
                   Left (ProcessRegistrationException _ _) ->
                     whereis label >>= maybe whereisOrRegister return
           in do pid <- whereisOrRegister
                 sendChan replyCh pid
                 if pid == self
                 then ServiceStarted <$> bootstrap conf
                 else return $ AlreadyRunning pid
      (est, mainloop, teardown, confirmStarted)
         <- (do (ServiceFunctions bootstrap mainloop teardown confirm) <- unClosure (serviceProcess svc)
                (,,,) <$> (release $ runBootstrap bootstrap)
                      <*> pure mainloop
                      <*> pure teardown
                      <*> pure confirm)
             `onException` (do
                let node = processNodeId self
                serviceLog $ "uncaught exception"
                promulgateWait $ ServiceUncaughtException (Node node) msg
                                   ("uncaught exception during startup") self)
      case est of
        AlreadyRunning pid -> serviceLog $ "already running at " ++ show pid
        ServiceStarted (Left e) -> do
          let node = processNodeId self
          serviceLog $ "exception during start: " ++ e
          promulgateWait $ ServiceFailed (Node node) msg self
        ServiceStarted (Right r) -> do
          let notify :: forall a . (SafeCopy a, Typeable a)
                     => (Node -> ServiceInfoMsg -> ProcessId -> a) -> Process ()
              notify f = promulgateWait $ f (Node (processNodeId self)) msg self
          confirmStarted conf r
          fix (\loop !b -> do
              next <- runMainloop mainloop conf b
              case next of
                (Continue, b') -> loop b'
                (Teardown, b') -> do
                  serviceLog  $ "user required service stop."
                  runTeardown teardown (notify ServiceExit) b'
                (Failure,  b') -> do
                  serviceLog $ "service failed."
                  runTeardown teardown (notify ServiceFailed) b') r
      where
        serviceLog s = say $ "[Service:" ++ name ++ "] " ++ s

        runMainloop mainloop a b = do
          userEvents <- mainloop a b
          release $ (receiveWait $
            userEvents ++
            [ -- Service receives are failed if the sender has filled
              -- wfReceiveVersion which indicates it couldn't decode
              -- the message on its end. Handle those messages here.
              returnedFromSvc (getInterface svc) $ do
                return (Continue, b)
              -- Automatically deal with decode failures for all
              -- services.
            , receiveSvcFailure (getInterface svc) $ do
                return (Continue, b)
              -- Maybe the message was intended for us but it was sent
              -- from a different version, with different fingerprint.
              -- If yes then decode it and send it to ourselves again
              -- so the above handlers have a fighting chance to catch
              -- it.
            , unsafeResendUnwrapped (getInterface svc) $ \_ -> (Continue, b)
            , matchAny $ \s -> do
                serviceLog $ "unhandled mesage" ++ show s
                return (Continue, b)
            ]) `catchExit` (onExit b)

        runTeardown teardown notify b = do
          self <- getSelfPid
          teardown conf b
          void $ spawnLocalName "temporary" $ do
            mref <- monitor self
            receiveWait [ matchIf (\(ProcessMonitorNotification m _ _ ) -> m == mref)
                                  (const $ return ()) ]
            notify

        onExit b _ Shutdown = return (Teardown, b)
        onExit b _ Fail = return (Failure, b)

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

-- | Stop service.
remoteStopService :: (SendPort Bool, String) -> Process ()
remoteStopService (ackCh, label) = do
  mpid <- whereis label
  case mpid of
    Just pid -> do
      mref <- monitor pid
      exit pid Shutdown
      receiveWait [ matchIf (\(ProcessMonitorNotification m _ _) -> m == mref)
                            (const $ return ())]
      sendChan ackCh True
    Nothing -> do
      sendChan ackCh False


$(mkDicts
   [ ''ServiceInfoMsg, ''Supports]
   [ (''Node, ''Has, ''ServiceInfoMsg)
   ])
$(mkResRel
   [ ''ServiceInfoMsg, ''Supports ]
   [ (''Node, Unbounded, ''Has, Unbounded, ''ServiceInfoMsg)
   ]
   [ 'someConfigDict
   , 'remoteStartService
   , 'remoteStopService
   ]
   )
