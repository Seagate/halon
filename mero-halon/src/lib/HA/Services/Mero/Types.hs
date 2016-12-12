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

-- | How to run a particular Mero Process. Processes can be hosted
--   in three ways:
--   - As part of the kernel (m0t1fs)
--   - As an ephemeral 'mkfs' process (mkfs)
--   - As a regular user-space m0d process (m0d)
data ProcessRunType =
    M0D -- ^ Run 'm0d' service.
  | M0T1FS -- ^ Run 'm0t1fs' service.
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
  | ConfigureProcess ProcessRunType ProcessConfig Bool
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

-- | Results of @mero-mkfs@ @systemctl@ invocations.
data ProcessControlResultConfigureMsg =
      ProcessControlResultConfigureMsg NodeId (Either (M0.Process, String) M0.Process)
  deriving (Eq, Generic, Show, Typeable)
instance Hashable ProcessControlResultConfigureMsg

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

newtype MeroServiceInstance = MeroServiceInstance { _msi_m0d :: HA.Service.Service MeroConf }
  deriving (Eq, Show, Generic, Typeable)
instance Hashable MeroServiceInstance

resourceDictMeroServiceInstance :: Dict (Resource MeroServiceInstance)
resourceDictMeroServiceInstance = Dict

-- | Explicit 'NotificationMessage' channel dictionary used for
-- 'Binary' instance.
resourceDictMeroChannel :: Dict (Resource (TypedChannel NotificationMessage))
resourceDictMeroChannel = Dict

-- | Explicit 'ProcessControlMsg' channel dictionary used for 'Binary'
-- instance.
resourceDictControlChannel :: Dict (Resource (TypedChannel ProcessControlMsg))
resourceDictControlChannel = Dict

-- | Explicit 'MeroServiceInstances' relation dictionary used for
-- 'Binary' instance.
relationDictMeroServiceInstance :: Dict (Relation R.Has R.Cluster MeroServiceInstance)
relationDictMeroServiceInstance = Dict

-- | Explicit 'NotificationMessage' channel relation dictionary used for
-- 'Binary' instance.
relationDictMeroChanelServiceProcessChannel :: Dict (
    Relation MeroChannel R.Node (TypedChannel NotificationMessage)
  )
relationDictMeroChanelServiceProcessChannel = Dict

-- | Explicit 'ProcessControlMsg' channel relation dictionary used for
-- 'Binary' instance.
relationDictMeroChanelServiceProcessControlChannel :: Dict (
    Relation MeroChannel R.Node (TypedChannel ProcessControlMsg)
  )
relationDictMeroChanelServiceProcessControlChannel = Dict

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

$(generateDicts ''MeroConf)
$(deriveService ''MeroConf 'meroSchema [ 'resourceDictMeroServiceInstance
                                       , 'resourceDictMeroChannel
                                       , 'resourceDictControlChannel
                                       , 'relationDictMeroServiceInstance
                                       , 'relationDictMeroChanelServiceProcessChannel
                                       , 'relationDictMeroChanelServiceProcessControlChannel
                                       ])

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
      = 'Unbounded
    relationDict = $(mkStatic 'relationDictMeroChanelServiceProcessChannel)

instance Relation MeroChannel R.Node (TypedChannel ProcessControlMsg) where
    type CardinalityFrom MeroChannel R.Node (TypedChannel ProcessControlMsg)
      = 'AtMostOne
    type CardinalityTo MeroChannel R.Node (TypedChannel ProcessControlMsg)
      = 'Unbounded
    relationDict = $(mkStatic 'relationDictMeroChanelServiceProcessControlChannel)

type instance HA.Service.ServiceState MeroConf =
  (ProcessId, SendPort NotificationMessage, SendPort ProcessControlMsg)

deriveSafeCopy 0 'base ''DeclareMeroChannel
deriveSafeCopy 0 'base ''KeepaliveTimedOut
deriveSafeCopy 0 'base ''MeroChannel
deriveSafeCopy 0 'base ''MeroChannelDeclared
deriveSafeCopy 0 'base ''MeroConf
deriveSafeCopy 0 'base ''MeroKernelConf
deriveSafeCopy 0 'base ''MeroServiceInstance
deriveSafeCopy 0 'base ''NotificationAck
deriveSafeCopy 0 'base ''NotificationFailure
deriveSafeCopy 0 'base ''ProcessControlResultConfigureMsg
deriveSafeCopy 0 'base ''ProcessControlResultMsg
deriveSafeCopy 0 'base ''ProcessControlResultStopMsg
