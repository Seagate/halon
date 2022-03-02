{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE StrictData            #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
-- |
-- Module    : HA.Services.Mero.Types
-- Copyright : (C) 2015-2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Types used by @halon:m0d@ service.
module HA.Services.Mero.Types
  ( InternalServiceReconnectReply(..)
  , InternalServiceReconnectRequest(..)
  , MeroConf(..)
  , MeroFromSvc(..)
  , MeroKernelConf(..)
  , MeroServiceInstance(..)
  , MeroToSvc(..)
  , NotificationMessage(..)
  , ProcessConfig(..)
  , ProcessControlMsg(..)
  , ProcessControlStartResult(..)
  , ProcessRunType(..)
  , interface
  , myResourcesTable
    -- * Generated stuff
  , configDictMeroConf
  , configDictMeroConf__static
  , HA.Services.Mero.Types.__remoteTable
  ) where

import           Control.Distributed.Process
import           Control.Distributed.Process.Closure
import           Data.List (union)
import           Data.Binary (Binary)
import           Data.ByteString (ByteString)
import           Data.Hashable (Hashable)
import           Data.Monoid ((<>))
import           Data.Typeable (Typeable)
import           Data.UUID as UUID
import           Data.Word (Word64)
import           GHC.Generics (Generic)
import           HA.Aeson hiding (encode, decode)
import           HA.ResourceGraph
import qualified HA.Resources as R
import           HA.Resources.HalonVars
import           HA.Resources.Mero as M0
import           HA.SafeCopy
import qualified HA.Service
import           HA.Service.Interface
import           HA.Service.TH
import           Language.Haskell.TH (mkName)
import           Mero.ConfC (Fid, strToFid)
import           Mero.Notification (Set)
import           Mero.Notification.HAState (HAMsg, ProcessEvent)
import           Options.Schema
import           Options.Schema.Builder

-- | Mero kernel module configuration parameters
data MeroKernelConf = MeroKernelConf
  { mkcNodeUUID :: UUID
  } deriving (Eq, Generic, Show, Typeable)
instance Hashable MeroKernelConf
instance ToJSON MeroKernelConf

-- | Mero service configuration
data MeroConf = MeroConf
  { mcHAAddress :: String -- ^ Address of the HA service endpoint.
    -- XXX-MULTIPOOLS: Get rid of `mcProfile` field.
  , mcProfile :: Fid      -- ^ FID of the current profile.
  , mcProcess :: Fid      -- ^ Fid of the current process.
  , mcHA :: Fid           -- ^ Fid of the HA service.
  , mcRM :: Fid           -- ^ Fid of the RM service.
  , mcKeepaliveFrequency :: Int
  -- ^ Frequency of keepalive requests in seconds.
  , mcKeepaliveTimeout :: Int
  -- ^ Number of seconds after keepalive request until the
  --   process is considered dead.
  , mcNotifAggrDelay :: Int
  -- ^ Notifications aggregation delay (in ms).
  , mcNotifMaxAggrDelay :: Int
  -- ^ Notifications aggregation maximum delay (in ms).
  , mcKernelConfig :: MeroKernelConf -- ^ Kernel configuration.
  } deriving (Eq, Generic, Show, Typeable)
instance Hashable MeroConf

instance ToJSON MeroConf where
  toJSON (MeroConf haAddress profile process ha rm kaf kat nad namd kernel) =
    object [ "endpoint_address" .= haAddress
           , "profile"          .= profile
           , "process"          .= process
           , "ha"               .= ha
           , "rm"               .= rm
           , "keepalive_frequency" .= kaf
           , "keepalive_timeout" .= kat
           , "notification_aggr_delay" .= nad
           , "notification_aggr_max_delay" .= namd
           , "kernel_config"    .= kernel
           ]

-- | Values that can be sent from RC to the halon:m0d service.
data MeroToSvc
  = -- | mero-cleanup is needed?
    Cleanup !Bool
    -- | Send given set of notifications to local m0d processes.
  | PerformNotification !NotificationMessage
    -- | Perform an action on the mero service given.
  | ProcessMsg !ProcessControlMsg
    -- | Ask the service to announce itself. This means it should send
    -- the given 'HAMsg' to the RC if it can. This means the RC will
    -- mark the service online based on the event. Normally mero sends
    -- this event when we connect with an interface but in case of a
    -- reconnect after network loss to the node, the interface isn't
    -- reconnected. Ideally we would like to ask mero to re-send this
    -- message but there isn't API for this.
  | AnnounceYourself
  deriving (Eq, Show, Generic, Typeable)

-- | Values that can be sent from the halon:m0d service to RC.
data MeroFromSvc
  = KeepaliveTimedOut [(Fid, M0.TimeSpec)]
  | MeroKernelFailed !NodeId String
  | MeroCleanupFailed !NodeId String
  | NotificationAck !Word64 !Fid
  | NotificationFailure !Word64 !Fid
  | ProcessControlResultConfigureMsg !UUID.UUID (Either (M0.Process, String) M0.Process)
  | AnnounceEvent !(HAMsg ProcessEvent)
  -- ^ Results of @mero-mkfs@ @systemctl@ invocations.
  --
  -- @ProcessControlResultConfigureMsg requestUUID result@
  --
  -- @requestUUID@ should come from 'ConfigureProcess' so the caller
  -- can identify its reply.
  | ProcessControlResultMsg !ProcessControlStartResult
  | ProcessControlResultStopMsg !NodeId (Either (M0.Process, String) M0.Process)
  -- ^ Results of @systemctl stop@ operations.
  | CheckCleanup !NodeId
  -- ^ Check with RC if mero-cleanup service should be ran.
  deriving (Eq, Generic, Show, Typeable)

-- | halon:m0d 'Interface'
interface :: Interface MeroToSvc MeroFromSvc
interface = Interface
  { ifVersion = 0
  , ifServiceName = "m0d"
  , ifEncodeToSvc = \_v -> Just . safeEncode interface
  , ifDecodeToSvc = safeDecode
  , ifEncodeFromSvc = \_v -> Just . safeEncode interface
  , ifDecodeFromSvc = safeDecode
  }

instance HA.Service.HasInterface MeroConf where
  type ToSvc MeroConf = MeroToSvc
  type FromSvc MeroConf = MeroFromSvc
  getInterface _ = interface

-- | A 'Set' of outgoing notifications from @halon:m0d@ to mero
-- processes along with epoch information.
data NotificationMessage = NotificationMessage
  { notificationEpoch   :: !Word64
  -- ^ Current epoch
  , notificationMessage :: Set
  -- ^ Notification 'Set'
  , notificationRecipients :: [Fid]
  -- ^ 'Fid's of the recepient mero processes.
  } deriving (Eq, Typeable, Generic, Show)
instance Hashable NotificationMessage
instance Monoid NotificationMessage where
  mempty = NotificationMessage 0 mempty []
  mappend (NotificationMessage e1 s1 rs1) (NotificationMessage e2 s2 rs2) =
    NotificationMessage (max e1 e2) (s1 <> s2) (union rs1 rs2)

-- | Request reconnect to the service
--
-- This is a workaround that asks the service to provide new
-- communication channels for use with control/notification processes.
-- (HALON-546)
newtype InternalServiceReconnectRequest = InternalServiceReconnectRequest ProcessId
  deriving (Show, Typeable, Generic)
instance Binary InternalServiceReconnectRequest

-- | Reply to 'ServiceReconnectRequest.
data InternalServiceReconnectReply = InternalServiceReconnectReply
  (SendPort NotificationMessage)
  (SendPort ProcessControlMsg)
  deriving (Show, Typeable, Generic)
instance Binary InternalServiceReconnectReply

-- | How to run a particular Mero Process. Processes can be hosted
--   in three ways:
--   - As part of the kernel (m0t1fs)
--   - As a regular user-space m0d process (m0d)
--   - Inside another process as a Clovis client
data ProcessRunType
  = M0D           -- ^ Run 'm0d' service.
  | M0T1FS        -- ^ Run 'm0t1fs' service.
  | CLOVIS String -- ^ Run 'clovis' service under the given name.
  deriving (Ord, Eq, Show, Typeable, Generic)
instance Hashable ProcessRunType

-- | m0d process configuration type.
--
-- A process may either fetch its configuration from local conf.xc
-- file, or it may connect to a confd server.
data ProcessConfig =
  ProcessConfigLocal !M0.Process !ByteString
  -- ^ Process should store and use local configuration. Provide
  -- @conf.xc@ content.
  | ProcessConfigRemote !M0.Process
  -- ^ Process will will fetch configuration from remote location.
  deriving (Ord, Eq, Show, Typeable, Generic)
instance Hashable ProcessConfig

-- | Control system level m0d processes.
data ProcessControlMsg
  = StartProcess !ProcessRunType !M0.Process
  | StopProcess !ProcessRunType !M0.Process
  | ConfigureProcess !ProcessRunType !ProcessConfig ![ProcessEnv] !Bool !UUID.UUID
  -- ^ @ConfigureProcess runType config environment runMkfs requestUUID@
  --
  -- 'ProcessControlResultConfigureMsg' which is used as the reply
  -- should include the @requestUUID@.
  deriving (Ord, Eq, Show, Typeable, Generic)
instance Hashable ProcessControlMsg

-- | Result of a process control invocation. Either it succeeded, or
--   it failed with a message.
data ProcessControlStartResult
  = RequiresStop !M0.Process
  -- ^ The process is not currently stopped according to systemd.
  | Started !M0.Process !Int
  -- ^ The process started fine with the given PID.
  | StartFailure !M0.Process !String
  -- ^ The process failed to start with the given reason.
  deriving (Eq, Generic, Show, Typeable)
instance Hashable ProcessControlStartResult

-- | A guide for which instance of @halon:m0d@ service to use when
-- invoking operations on the service.
--
-- This exists to allow us to swap-out real @halon:m0d@ implementation
-- for a mock implementation in tests.
newtype MeroServiceInstance = MeroServiceInstance { _msi_m0d :: HA.Service.Service MeroConf }
  deriving (Eq, Show, Generic, Typeable)
instance Hashable MeroServiceInstance
instance ToJSON MeroServiceInstance

-- | 'Schema' for the @halon:m0d@ service.
meroSchema :: Schema MeroConf
meroSchema = MeroConf <$> ha <*> pr <*> pc <*> hf <*> rm <*> kaf <*> kat
                      <*> nad <*> namd <*> ker
  where
    ha = strOption
          $  long "listenAddr"
          <> short 'l'
          <> metavar "LISTEN_ADDRESS"
          <> summary "HA service listen endpoint address"
    pr = option (maybe (fail "incorrect fid") return . strToFid)
          $  long "profile"
          <> short 'p'
          <> metavar "FID"
          <> summary "confd profile"
    pc = option (maybe (fail "incorrect fid") return . strToFid)
          $  long "process"
          <> short 's'
          <> metavar "FID"
          <> summary "halon process Fid"
    hf = option (maybe (fail "incorrect fid") return . strToFid)
          $  long "halon"
          <> short 'a'
          <> metavar "FID"
          <> summary "ha service Fid"
    rm = option (maybe (fail "incorrect fid") return . strToFid)
          $  long "rm"
          <> short 'r'
          <> metavar "FID"
          <> summary "rm service Fid"
    kaf = intOption
          $ long "keepalive_frequency"
          <> short 'f'
          <> metavar "SECONDS"
          <> summary "keepalive request frequency (seconds)"
          <> value (_hv_keepalive_frequency defaultHalonVars)
    kat = intOption
          $ long "keepalive_timeout"
          <> short 't'
          <> metavar "SECONDS"
          <> summary "keepalive request timeout (seconds)"
          <> value (_hv_keepalive_timeout defaultHalonVars)
    nad = intOption
          $ long "notifications_aggregation_delay"
          <> short 'd'
          <> metavar "MILLISECONDS"
          <> summary "notifications aggregation delay (milliseconds)"
          <> value (_hv_notification_aggr_delay defaultHalonVars)
    namd = intOption
          $ long "notifications_aggregation_max_delay"
          <> short 'D'
          <> metavar "MILLISECONDS"
          <> summary "notifications aggregation max delay (milliseconds)"
          <> value (_hv_notification_aggr_max_delay defaultHalonVars)
    ker = compositeOption kernelSchema $ long "kernel" <> summary "Kernel configuration"

-- | 'Schema' for kernel configuration used by @halon:m0d@ service.
kernelSchema :: Schema MeroKernelConf
kernelSchema = MeroKernelConf <$> uuid
  where
    uuid = option (maybe (fail "incorrect uuid format") return . UUID.fromString)
            $ long "uuid"
            <> short 'u'
            <> metavar "UUID"

storageIndex ''MeroConf                               "c6625352-ee65-486d-922c-843a5e1b6063"
storageIndex ''MeroServiceInstance                    "ef91ea04-a66e-434e-bfbd-e4449c5d947e"
serviceStorageIndex ''MeroConf                        "9ea7007a-51a8-4e2b-9208-a4e0944c54b2"
mkDictsQ
  [ (mkName "resourceDictMeroServiceInstance", [t| MeroServiceInstance |])
  ]
  [ (mkName "relationDictMeroServiceInstance"
      , ([t| R.Cluster |], [t| R.Has |], [t| MeroServiceInstance |]))
  ]
mkStorageDictsQ
  [ (mkName "storageDictMeroServiceInstance", [t| MeroServiceInstance |])
  ]
  [ (mkName "storageRelationDictMeroServiceInstance"
    , ([t| R.Cluster |], [t| R.Has |], [t| MeroServiceInstance |]))
  ]
generateDicts       ''MeroConf
deriveService       ''MeroConf 'meroSchema
  [ 'resourceDictMeroServiceInstance
  , 'relationDictMeroServiceInstance
  , 'storageDictMeroServiceInstance
  , 'storageRelationDictMeroServiceInstance
  ]
mkStorageResRelQ
  [ (mkName "storageDictMeroServiceInstance", [t| MeroServiceInstance |])
  ]
  [ (mkName "storageRelationDictMeroServiceInstance"
    , ([t| R.Cluster |], [t| R.Has |], [t| MeroServiceInstance |]))
  ]

instance Resource MeroServiceInstance where
  resourceDict = $(mkStatic 'resourceDictMeroServiceInstance)

instance Relation R.Has R.Cluster MeroServiceInstance where
  type CardinalityFrom R.Has R.Cluster MeroServiceInstance = 'AtMostOne
  type CardinalityTo R.Has R.Cluster MeroServiceInstance   = 'AtMostOne
  relationDict = $(mkStatic 'relationDictMeroServiceInstance)

type instance HA.Service.ServiceState MeroConf =
  (ProcessId, SendPort NotificationMessage, SendPort ProcessControlMsg)

myResourcesTable :: RemoteTable -> RemoteTable
myResourcesTable
  = $(makeResource [t| MeroServiceInstance |])
  . $(makeRelation [t| R.Cluster |] [t| R.Has |] [t| MeroServiceInstance |])
  . HA.Services.Mero.Types.__resourcesTable

deriveSafeCopy 0 'base ''MeroConf
deriveSafeCopy 0 'base ''MeroFromSvc
deriveSafeCopy 0 'base ''MeroKernelConf
deriveSafeCopy 0 'base ''MeroServiceInstance
deriveSafeCopy 0 'base ''MeroToSvc
deriveSafeCopy 0 'base ''NotificationMessage
deriveSafeCopy 0 'base ''ProcessConfig
deriveSafeCopy 0 'base ''ProcessControlMsg
deriveSafeCopy 0 'base ''ProcessRunType
deriveSafeCopy 0 'base ''ProcessControlStartResult
