{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.Mero.Types
  ( module HA.Services.Mero.Types
  , KeepaliveTimedOut(..)
  ) where

import HA.Resources.HalonVars
import HA.Resources.Mero as M0
import HA.ResourceGraph
import HA.Aeson hiding (encode, decode)
import HA.SafeCopy
import qualified HA.Service
import HA.Service.TH
import qualified HA.Resources as R

import Mero.ConfC (Fid, strToFid)
import Mero.Notification (Set)

import Control.Distributed.Process
import Control.Distributed.Process.Closure

import Data.Binary (Binary, encode, decode)
import Data.ByteString (ByteString)
import Data.Hashable (Hashable)
import Data.Monoid ((<>))
import Data.Serialize (Serialize(..))
import Data.Typeable (Typeable)
import Data.UUID as UUID
import Data.Word (Word64)

import GHC.Generics (Generic)

import Options.Schema
import Options.Schema.Builder

-- | Mero kernel module configuration parameters
data MeroKernelConf = MeroKernelConf
       { mkcNodeUUID :: UUID    -- ^ Node UUID
       } deriving (Eq, Generic, Show, Typeable)
instance Hashable MeroKernelConf
instance ToJSON MeroKernelConf
deriveSafeCopy 0 'base ''MeroKernelConf

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
deriveSafeCopy 0 'base ''MeroConf

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

newtype TypedChannel a = TypedChannel (SendPort a)
    deriving (Eq, Show, Typeable, Binary, Hashable)

instance (Binary a, Typeable a) => SafeCopy (TypedChannel a) where
  getCopy = contain $ TypedChannel . decode <$> get
  putCopy  (TypedChannel p) = contain $ put $ encode p

data MeroChannel = MeroChannel deriving (Eq, Show, Typeable, Generic)

deriveSafeCopy 0 'base ''MeroChannel
instance Hashable MeroChannel

-- | Acknowledgement sent upon successfully calling m0_ha_state_set.
data NotificationAck = NotificationAck Word64 Fid
  deriving (Eq, Generic, Typeable)
instance Hashable NotificationAck
deriveSafeCopy 0 'base ''NotificationAck

-- | Acknowledgement that delivery for cetrain procedd definitely failed.
data NotificationFailure = NotificationFailure Word64 Fid
  deriving (Eq, Generic, Typeable)
instance Hashable NotificationFailure
deriveSafeCopy 0 'base ''NotificationFailure

data NotificationMessage = NotificationMessage
       { notificationEpoch   :: Word64    -- Current epoch
       , notificationMessage :: Set       -- Notification set
       , notificationRecipients :: [Fid]  -- Endpoints
       }
     deriving (Typeable, Generic, Show)
instance Binary NotificationMessage
instance Hashable NotificationMessage

-- | How to run a particular Mero Process. Processes can be hosted
--   in three ways:
--   - As part of the kernel (m0t1fs)
--   - As an ephemeral 'mkfs' process (mkfs)
--   - As a regular user-space m0d process (m0d)
data ProcessRunType =
    M0D -- ^ Run 'm0d' service.
  | M0T1FS -- ^ Run 'm0t1fs' service.
  deriving (Eq, Show, Typeable, Generic)
instance Binary ProcessRunType
instance Hashable ProcessRunType

-- | m0d Process configuration type.
--   A process may either fetch its configuration from local conf.xc file,
--   or it may connect to a confd server.
data ProcessConfig =
    ProcessConfigLocal M0.Process ByteString
    -- ^ Process fid, endpoint, conf.xc
  | ProcessConfigRemote M0.Process
  -- ^ Process fid, endpoint
  deriving (Eq, Show, Typeable, Generic)
instance Binary ProcessConfig
instance Hashable ProcessConfig

-- | Control system level m0d processes.
data ProcessControlMsg =
    StartProcess ProcessRunType M0.Process
  | StopProcess ProcessRunType M0.Process
  | ConfigureProcess ProcessRunType ProcessConfig Bool
  deriving (Eq, Show, Typeable, Generic)
instance Binary ProcessControlMsg
instance Hashable ProcessControlMsg

-- | Result of a process control invocation. Either it succeeded, or
--   it failed with a message.
data ProcessControlResultMsg =
    ProcessControlResultMsg NodeId (Either (M0.Process, String) (M0.Process, Maybe Int))
  deriving (Eq, Generic, Show, Typeable)
instance Hashable ProcessControlResultMsg
deriveSafeCopy 0 'base ''ProcessControlResultMsg

data ProcessControlResultStopMsg =
      ProcessControlResultStopMsg NodeId (Either (M0.Process, String) M0.Process)
  deriving (Eq, Generic, Show, Typeable)
instance Hashable ProcessControlResultStopMsg
deriveSafeCopy 0 'base ''ProcessControlResultStopMsg

data ProcessControlResultConfigureMsg =
      ProcessControlResultConfigureMsg NodeId (Either (M0.Process, String) M0.Process)
  deriving (Eq, Generic, Show, Typeable)
instance Hashable ProcessControlResultConfigureMsg
deriveSafeCopy 0 'base ''ProcessControlResultConfigureMsg

-- | We haven't heard back from a process for a while about keepalive so we're
data KeepaliveTimedOut = KeepaliveTimedOut [(Fid, M0.TimeSpec)]
  deriving (Eq, Generic, Show, Typeable)
instance Hashable KeepaliveTimedOut
deriveSafeCopy 0 'base ''KeepaliveTimedOut

data DeclareMeroChannel =
    DeclareMeroChannel
    { dmcPid     :: !ProcessId
    , dmcChannel :: !(TypedChannel NotificationMessage)
    , dmcCtrlChannel :: !(TypedChannel ProcessControlMsg)
    }
    deriving (Generic, Typeable)
instance Hashable DeclareMeroChannel
deriveSafeCopy 0 'base ''DeclareMeroChannel

data MeroChannelDeclared =
    MeroChannelDeclared
    { mcdPid     :: !ProcessId
    , mcdChannel :: !(TypedChannel NotificationMessage)
    , mcdCtrlChannel :: !(TypedChannel ProcessControlMsg)
    }
    deriving (Generic, Typeable)
instance Hashable MeroChannelDeclared
deriveSafeCopy 0 'base ''MeroChannelDeclared

resourceDictMeroChannel :: Dict (Resource (TypedChannel NotificationMessage))
resourceDictMeroChannel = Dict

resourceDictControlChannel :: Dict (Resource (TypedChannel ProcessControlMsg))
resourceDictControlChannel = Dict

relationDictMeroChanelServiceProcessChannel :: Dict (
    Relation MeroChannel R.Node (TypedChannel NotificationMessage)
  )
relationDictMeroChanelServiceProcessChannel = Dict

relationDictMeroChanelServiceProcessControlChannel :: Dict (
    Relation MeroChannel R.Node (TypedChannel ProcessControlMsg)
  )
relationDictMeroChanelServiceProcessControlChannel = Dict

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

kernelSchema :: Schema MeroKernelConf
kernelSchema = MeroKernelConf <$> uuid
  where
    uuid = option (maybe (fail "incorrect uuid format") return . UUID.fromString)
            $ long "uuid"
            <> short 'u'
            <> metavar "UUID"

$(generateDicts ''MeroConf)
$(deriveService ''MeroConf 'meroSchema [ 'resourceDictMeroChannel
                                       , 'resourceDictControlChannel
                                       , 'relationDictMeroChanelServiceProcessChannel
                                       , 'relationDictMeroChanelServiceProcessControlChannel
                                       ])

instance Resource (TypedChannel NotificationMessage) where
    resourceDict = $(mkStatic 'resourceDictMeroChannel)

instance Resource (TypedChannel ProcessControlMsg) where
    resourceDict = $(mkStatic 'resourceDictControlChannel)

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
