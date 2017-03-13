{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
-- |
-- Module    : HA.Services.Mero.Types
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Types used by @halon:m0d@ service.
module HA.Services.Mero.Types
  ( module HA.Services.Mero.Types
  , KeepaliveTimedOut(..)
  ) where

import           Control.Distributed.Process
import           Control.Distributed.Process.Closure
import           HA.Aeson hiding (encode, decode)
import           HA.ResourceGraph
import qualified HA.Resources as R
import           HA.Resources.HalonVars
import           HA.Resources.Mero as M0
import           HA.SafeCopy
import qualified HA.Service
import           HA.Service.TH
import           Mero.ConfC (Fid, strToFid)
import           Mero.Notification (Set)

import           Data.Binary (Binary, encode, decode)
import           Data.ByteString (ByteString)
import           Data.Hashable (Hashable)
import           Data.Monoid ((<>))
import           Data.Serialize (Serialize(..))
import           Data.Typeable (Typeable)
import           Data.UUID as UUID
import           Data.Word (Word64)
import           GHC.Generics (Generic)
import           Options.Schema
import           Options.Schema.Builder
import           Language.Haskell.TH (mkName)

-- | Mero kernel module configuration parameters
data MeroKernelConf = MeroKernelConf
       { mkcNodeUUID :: UUID    -- ^ Node UUID
       } deriving (Eq, Generic, Show, Typeable)
instance Hashable MeroKernelConf
instance ToJSON MeroKernelConf

-- | Mero service configuration
data MeroConf = MeroConf
       { mcHAAddress        :: String         -- ^ Address of the HA service endpoint
       , mcProfile          :: Fid            -- ^ FID of the current profile
       , mcProcess          :: Fid            -- ^ Fid of the current process.
       , mcHA               :: Fid            -- ^ Fid of the HA service.
       , mcRM               :: Fid            -- ^ Fid of the RM service.
       , mcKeepaliveFrequency :: Int
       -- ^ Frequency of keepalive requests in seconds.
       , mcKeepaliveTimeout :: Int
       -- ^ Number of seconds after keepalive request until the
       -- process is considered dead.
       , mcKernelConfig     :: MeroKernelConf -- ^ Kernel configuration
       }
   deriving (Eq, Generic, Show, Typeable)
instance Hashable MeroConf


instance ToJSON MeroConf where
  toJSON (MeroConf haAddress profile process ha rm kaf kat kernel) =
    object [ "endpoint_address" .= haAddress
           , "profile"          .= profile
           , "process"          .= process
           , "ha"               .= ha
           , "rm"               .= rm
           , "keepalive_frequency" .= kaf
           , "keepalive_timeout" .= kat
           , "kernel_config"    .= kernel
           ]

-- | 'SendPort' with 'SafeCopy' instance.
newtype TypedChannel a = TypedChannel (SendPort a)
    deriving (Eq, Show, Typeable, Binary, Hashable)

instance (Binary a, Typeable a) => SafeCopy (TypedChannel a) where
  getCopy = contain $ TypedChannel . decode <$> get
  putCopy  (TypedChannel p) = contain $ put $ encode p

-- | Relation index connecting channels used by @halon:m0d@ service
-- and the corresponding 'R.Node'.
data MeroChannel = MeroChannel deriving (Eq, Show, Typeable, Generic)
instance Hashable MeroChannel

-- | Acknowledgement sent upon successfully calling m0_ha_state_set.
data NotificationAck = NotificationAck Word64 Fid
  deriving (Eq, Generic, Typeable)
instance Hashable NotificationAck

-- | Acknowledgement that delivery for cetrain procedd definitely failed.
data NotificationFailure = NotificationFailure Word64 Fid
  deriving (Eq, Generic, Typeable)
instance Hashable NotificationFailure

-- | A 'Set' of outgoing notifications from @halon:m0d@ to mero
-- processes along with epoch information.
data NotificationMessage = NotificationMessage
  { notificationEpoch   :: Word64
  -- ^ Current epoch
  , notificationMessage :: Set
  -- ^ Notification 'Set'
  , notificationRecipients :: [Fid]
  -- ^ 'Fid's of the recepient mero processes.
  } deriving (Typeable, Generic, Show)
instance Binary NotificationMessage
instance Hashable NotificationMessage

-- | Request information about service
data ServiceStateRequest = ServiceStateRequest
  deriving (Show, Typeable, Generic)
instance Binary ServiceStateRequest

-- | Request reconnect to the service
--
-- This is a workaround that asks the service to provide new
-- communication channels for use with control/notification processes.
-- (HALON-546)
data ServiceReconnectRequest = ServiceReconnectRequest
  deriving (Show, Typeable, Generic)
instance Binary ServiceReconnectRequest

-- | Reply to 'ServiceReconnectRequest.
data ServiceReconnectReply = ServiceReconnectReply
  (SendPort NotificationMessage)
  (SendPort ProcessControlMsg)
  deriving (Show, Typeable, Generic)
instance Binary ServiceReconnectReply

-- | How to run a particular Mero Process. Processes can be hosted
--   in three ways:
--   - As part of the kernel (m0t1fs)
--   - As a regular user-space m0d process (m0d)
--   - Inside another process as a Clovis client
data ProcessRunType =
    M0D -- ^ Run 'm0d' service.
  | M0T1FS -- ^ Run 'm0t1fs' service.
  | CLOVIS String -- ^ Run 'clovis' service under the given name.
  deriving (Ord, Eq, Show, Typeable, Generic)
instance Binary ProcessRunType
instance Hashable ProcessRunType

-- | m0d process configuration type.
--
-- A process may either fetch its configuration from local conf.xc
-- file, or it may connect to a confd server.
data ProcessConfig =
  ProcessConfigLocal M0.Process ByteString
  -- ^ Process should store and use local configuration. Provide
  -- @conf.xc@ content.
  | ProcessConfigRemote M0.Process
  -- ^ Process will will fetch configuration from remote location.
  deriving (Ord, Eq, Show, Typeable, Generic)
instance Binary ProcessConfig
instance Hashable ProcessConfig

-- | Control system level m0d processes.
data ProcessControlMsg =
    StartProcess ProcessRunType M0.Process
  | StopProcess ProcessRunType M0.Process
  | ConfigureProcess ProcessRunType ProcessConfig Bool UUID.UUID
  -- ^ @ConfigureProcess runType config runMkfs requestUUID@
  --
  -- 'ProcessControlResultConfigureMsg' which is used as the reply
  -- should include the @requestUUID@.
  deriving (Ord, Eq, Show, Typeable, Generic)
instance Binary ProcessControlMsg
instance Hashable ProcessControlMsg

-- | Result of a process control invocation. Either it succeeded, or
--   it failed with a message.
data ProcessControlResultMsg =
    ProcessControlResultMsg NodeId (Either (M0.Process, String) (M0.Process, Maybe Int))
  deriving (Eq, Generic, Show, Typeable)
instance Hashable ProcessControlResultMsg

-- | Results of @systemctl stop@ operations.
data ProcessControlResultStopMsg =
      ProcessControlResultStopMsg NodeId (Either (M0.Process, String) M0.Process)
  deriving (Eq, Generic, Show, Typeable)
instance Hashable ProcessControlResultStopMsg

-- | Base version of 'ProcessControlResultConfigureMsg'.
data ProcessControlResultConfigureMsg_v0 =
      ProcessControlResultConfigureMsg_v0 NodeId (Either (M0.Process, String) M0.Process)
  deriving (Eq, Generic, Show, Typeable)
instance Hashable ProcessControlResultConfigureMsg_v0

-- | Results of @mero-mkfs@ @systemctl@ invocations.
data ProcessControlResultConfigureMsg =
      ProcessControlResultConfigureMsg NodeId UUID.UUID (Either (M0.Process, String) M0.Process)
      -- ^ @ProcessControlResultConfigureMsg nid requestUUID result@
      --
      -- @requestUUID@ should come from 'ConfigureProcess' so the
      -- caller can identify its reply.
  deriving (Eq, Generic, Show, Typeable)
instance Hashable ProcessControlResultConfigureMsg

-- | We use 'UUID.nil' for the 'UUID.UUID' that's missing in
-- 'ProcessControlResultConfigureMsg_v0': no configure request will
-- have such UUID and RC will discard it. This is desired because if
-- RC has restarted and we have mid-flight configure result, it's
-- stale and RC will restart the rule anyway.
instance Migrate ProcessControlResultConfigureMsg where
  type MigrateFrom ProcessControlResultConfigureMsg = ProcessControlResultConfigureMsg_v0
  migrate (ProcessControlResultConfigureMsg_v0 n r) =
    ProcessControlResultConfigureMsg n UUID.nil r

-- | The process hasn't replied to keepalive request for a too long.
-- Carry this information to RC.
data KeepaliveTimedOut =
  KeepaliveTimedOut [(Fid, M0.TimeSpec)]
  -- ^ List of processes that we have not replied to keepalive fast
  -- enough when we last checked along with the time we have lasts
  -- heard from them.
  --
  -- TODO: Use NonEmpty
  deriving (Eq, Generic, Show, Typeable)
instance Hashable KeepaliveTimedOut

-- | Information about the @halon:m0d@ process as along with
-- communication channels used by the service.
data DeclareMeroChannel =
    DeclareMeroChannel
    { dmcPid     :: !ProcessId
    -- ^ @halon:m0d@ 'ProcessId'
    , dmcChannel :: !(TypedChannel NotificationMessage)
    -- ^ Notification message channel
    , dmcCtrlChannel :: !(TypedChannel ProcessControlMsg)
    -- ^ Channel used to request various process control actions on
    -- the hosting node.
    }
    deriving (Generic, Typeable)
instance Hashable DeclareMeroChannel

-- | 'DeclareMeroChannel' has been acted upon and registered in the
-- RG. 'MeroChannelDeclared' is used to inform the rest of the system
-- that the service is ready to be communicated with.
data MeroChannelDeclared =
    MeroChannelDeclared
    { mcdPid     :: !ProcessId
    -- ^ @halon:m0d@ 'ProcessId'
    , mcdChannel :: !(TypedChannel NotificationMessage)
    -- ^ Notification message channel
    , mcdCtrlChannel :: !(TypedChannel ProcessControlMsg)
    -- ^ Channel used to request various process control actions on
    -- the hosting node.
    }
    deriving (Generic, Typeable)
instance Hashable MeroChannelDeclared

-- | A guide for which instance of @halon:m0d@ service to use when
-- invoking operations on the service.
--
-- This exists to allow us to swap-out real @halon:m0d@ implementation
-- for a mock implementation in tests.
newtype MeroServiceInstance = MeroServiceInstance { _msi_m0d :: HA.Service.Service MeroConf }
  deriving (Eq, Show, Generic, Typeable)
instance Hashable MeroServiceInstance


-- | 'Schema' for the @halon:m0d@ service.
meroSchema :: Schema MeroConf
meroSchema = MeroConf <$> ha <*> pr <*> pc <*> hf <*> rm <*> kaf <*> kat <*> ker
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
storageIndex ''MeroChannel                            "998366fa-dc24-4325-83b1-32f27b146d03"
storageIndex ''MeroServiceInstance                    "ef91ea04-a66e-434e-bfbd-e4449c5d947e"
storageIndexQ [t| TypedChannel NotificationMessage |] "5adbe0dc-f0d6-44c4-81e9-5d5accd3bf4a"
storageIndexQ [t| TypedChannel ProcessControlMsg |]   "1c924292-d246-46e9-8a24-79b7daa4e346"
serviceStorageIndex ''MeroConf                        "9ea7007a-51a8-4e2b-9208-a4e0944c54b2"
mkDictsQ 
  [ (mkName "resourceDictMeroServiceInstance", [t| MeroServiceInstance |])
  , (mkName "storageDictMeroChannel_1",        [t| MeroChannel |])
  , (mkName "resourceDictMeroChannel",         [t| TypedChannel NotificationMessage |])
  , (mkName "resourceDictControlChannel",      [t| TypedChannel ProcessControlMsg |])
  ]
  [ (mkName "relationDictMeroServiceInstance"
      , ([t| R.Cluster |], [t| R.Has |], [t| MeroServiceInstance |]))
    , (mkName "relationDictMeroChanelServiceProcessChannel"
      , ([t| R.Node |], [t| MeroChannel |], [t| TypedChannel NotificationMessage |]))
    , (mkName "relationDictMeroChanelServiceProcessControlChannel" 
      , ([t| R.Node |], [t| MeroChannel |], [t| TypedChannel ProcessControlMsg |]))
  ]
mkStorageDictsQ
  [ (mkName "storageDictMeroChannel_",        [t| MeroChannel |])
  , (mkName "storageDictMeroServiceInstance", [t| MeroServiceInstance |])
  , (mkName "storageDictMeroChannel",         [t| TypedChannel NotificationMessage |])
  , (mkName "storageDictControlChannel",      [t| TypedChannel ProcessControlMsg |])
  ]
  [ (mkName "storageRelationDictMeroServiceInstance"
    , ([t| R.Cluster |], [t| R.Has |], [t| MeroServiceInstance |]))
  , (mkName "storageDictMeroChanelServiceProcessChannel"
    , ([t| R.Node |], [t| MeroChannel |], [t| TypedChannel NotificationMessage|]))
  , (mkName "storageDictMeroChanelServiceProcessControlChannel"
    , ([t| R.Node |], [t| MeroChannel |], [t| TypedChannel ProcessControlMsg|]))
  ]
generateDicts       ''MeroConf
deriveService        ''MeroConf 'meroSchema
  [ 'resourceDictMeroServiceInstance
  , 'resourceDictMeroChannel
  , 'resourceDictControlChannel
  , 'relationDictMeroServiceInstance
  , 'relationDictMeroChanelServiceProcessChannel
  , 'relationDictMeroChanelServiceProcessControlChannel
  , 'storageDictMeroServiceInstance
  , 'storageDictMeroChannel
  , 'storageDictMeroChannel_
  , 'storageDictMeroChannel_1
  , 'storageDictControlChannel
  , 'storageRelationDictMeroServiceInstance
  , 'storageDictMeroChanelServiceProcessChannel
  , 'storageDictMeroChanelServiceProcessControlChannel
  ]
mkStorageResRelQ
  [ (mkName "storageDictMeroChannel_",        [t| MeroChannel |])
  , (mkName "storageDictMeroServiceInstance", [t| MeroServiceInstance |])
  , (mkName "storageDictMeroChannel",         [t| TypedChannel NotificationMessage |])
  , (mkName "storageDictControlChannel",      [t| TypedChannel ProcessControlMsg |])
  ]
  [ (mkName "storageRelationDictMeroServiceInstance"
    , ([t| R.Cluster |], [t| R.Has |], [t| MeroServiceInstance |]))
  , (mkName "storageDictMeroChanelServiceProcessChannel"
    , ([t| R.Node |], [t| MeroChannel |], [t| TypedChannel NotificationMessage|]))
  , (mkName "storageDictMeroChanelServiceProcessControlChannel"
    , ([t| R.Node |], [t| MeroChannel |], [t| TypedChannel ProcessControlMsg|]))
  ]

instance Resource MeroChannel where
  resourceDict = $(mkStatic 'storageDictMeroChannel_1)

instance Resource MeroServiceInstance where
  resourceDict = $(mkStatic 'resourceDictMeroServiceInstance)

instance Resource (TypedChannel NotificationMessage) where
  resourceDict = $(mkStatic 'resourceDictMeroChannel)

instance Resource (TypedChannel ProcessControlMsg) where
  resourceDict = $(mkStatic 'resourceDictControlChannel)

instance Relation R.Has R.Cluster MeroServiceInstance where
  type CardinalityFrom R.Has R.Cluster MeroServiceInstance = 'AtMostOne
  type CardinalityTo R.Has R.Cluster MeroServiceInstance   = 'AtMostOne
  relationDict = $(mkStatic 'relationDictMeroServiceInstance)

instance Relation MeroChannel R.Node (TypedChannel NotificationMessage) where
    type CardinalityFrom MeroChannel R.Node (TypedChannel NotificationMessage)
      = 'AtMostOne
    type CardinalityTo MeroChannel R.Node (TypedChannel NotificationMessage)
      = 'AtMostOne
    relationDict = $(mkStatic 'relationDictMeroChanelServiceProcessChannel)

instance Relation MeroChannel R.Node (TypedChannel ProcessControlMsg) where
    type CardinalityFrom MeroChannel R.Node (TypedChannel ProcessControlMsg)
      = 'AtMostOne
    type CardinalityTo MeroChannel R.Node (TypedChannel ProcessControlMsg)
      = 'AtMostOne
    relationDict = $(mkStatic 'relationDictMeroChanelServiceProcessControlChannel)

type instance HA.Service.ServiceState MeroConf =
  (ProcessId, SendPort NotificationMessage, SendPort ProcessControlMsg)

myResourcesTable :: RemoteTable -> RemoteTable
myResourcesTable
  = $(makeResource [t| TypedChannel ProcessControlMsg |])
  . $(makeResource [t| TypedChannel NotificationMessage |])
  . $(makeResource [t| MeroServiceInstance |])
  . $(makeRelation [t| R.Node |] [t| MeroChannel |] [t| TypedChannel NotificationMessage |])
  . $(makeRelation [t| R.Node |] [t| MeroChannel |] [t| TypedChannel ProcessControlMsg |])
  . $(makeRelation [t| R.Cluster |] [t| R.Has |] [t| MeroServiceInstance |])
  . HA.Services.Mero.Types.__resourcesTable

deriveSafeCopy 0 'base ''DeclareMeroChannel
deriveSafeCopy 0 'base ''KeepaliveTimedOut
deriveSafeCopy 0 'base ''MeroChannel
deriveSafeCopy 0 'base ''MeroChannelDeclared
deriveSafeCopy 0 'base ''MeroConf
deriveSafeCopy 0 'base ''MeroKernelConf
deriveSafeCopy 0 'base ''MeroServiceInstance
deriveSafeCopy 0 'base ''NotificationAck
deriveSafeCopy 0 'base ''NotificationFailure
deriveSafeCopy 0 'base ''ProcessControlResultConfigureMsg_v0
deriveSafeCopy 1 'extension ''ProcessControlResultConfigureMsg
deriveSafeCopy 0 'base ''ProcessControlResultMsg
deriveSafeCopy 0 'base ''ProcessControlResultStopMsg
