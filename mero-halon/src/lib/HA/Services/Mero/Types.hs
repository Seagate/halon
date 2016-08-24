{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
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
import HA.Service
import HA.Service.TH

import Mero.ConfC (Fid, strToFid, Word128)
import Mero.Notification (Set)

import Control.Distributed.Process
import Control.Distributed.Process.Closure

import Data.Aeson
import Data.Binary (Binary)
import Data.ByteString (ByteString)
import Data.Hashable (Hashable)
import Data.Monoid ((<>))
import Data.Typeable (Typeable)
import Data.UUID as UUID
import Data.Word (Word64)

import GHC.Generics (Generic)

import Options.Schema
import Options.Schema.Builder
import System.Clock
import Text.Read (readMaybe)

-- | Mero kernel module configuration parameters
data MeroKernelConf = MeroKernelConf
       { mkcNodeUUID :: UUID    -- ^ Node UUID
       } deriving (Eq, Generic, Show, Typeable)
instance Binary MeroKernelConf
instance Hashable MeroKernelConf
instance ToJSON MeroKernelConf where
  toJSON (MeroKernelConf uuid) = object [ "uuid" .= UUID.toString uuid ]

-- | Mero service configuration
data MeroConf = MeroConf
       { mcHAAddress        :: String         -- ^ Address of the HA service endpoint
       , mcProfile          :: Fid            -- ^ FID of the current profile
       , mcProcess          :: Fid            -- ^ Fid of the current process.
       , mcKeepaliveFrequency :: Int
       -- ^ Frequency of keepalive requests in seconds.
       , mcKeepaliveTimeout :: Int
       -- ^ Number of seconds after keepalive request until the
       -- process is considered dead.
       , mcKernelConfig     :: MeroKernelConf -- ^ Kernel configuration
       }
   deriving (Eq, Generic, Show, Typeable)
instance Binary MeroConf
instance Hashable MeroConf

instance ToJSON MeroConf where
  toJSON (MeroConf haAddress profile process kaf kat kernel) =
    object [ "endpoint_address" .= haAddress
           , "profile"          .= profile
           , "process"          .= process
           , "keepalive_frequency" .= kaf
           , "keepalive_timeout" .= kat
           , "kernel_config"    .= kernel
           ]

newtype TypedChannel a = TypedChannel (SendPort a)
    deriving (Eq, Show, Typeable, Binary, Hashable)

data MeroChannel = MeroChannel deriving (Eq, Show, Typeable, Generic)

instance Binary MeroChannel
instance Hashable MeroChannel

-- | Acknowledgement sent upon successfully calling m0_ha_state_set
newtype NotificationAck = NotificationAck ()
  deriving (Binary, Eq, Hashable, Generic, Typeable)

data NotificationMessage = NotificationMessage
       { notificationMessage :: Set
       , notificationRecipients :: [String] -- Endpoints
       , notificationAckTo :: [ProcessId] -- Processes to send ack that
                                          -- notification is complete.
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
    ProcessConfigLocal Fid String ByteString -- ^ Process fid, endpoint, conf.xc
  | ProcessConfigRemote Fid String -- ^ Process fid, endpoint
  deriving (Eq, Show, Typeable, Generic)
instance Binary ProcessConfig
instance Hashable ProcessConfig

-- | Control system level m0d processes.
data ProcessControlMsg =
    StartProcesses [(ProcessRunType, Fid)]
  | StopProcesses [(ProcessRunType, Fid)]
  | RestartProcesses [(ProcessRunType, Fid)]
  | ConfigureProcesses [(ProcessRunType, ProcessConfig, Bool)]
  deriving (Eq, Show, Typeable, Generic)
instance Binary ProcessControlMsg
instance Hashable ProcessControlMsg

-- | Result of a process control invocation. Either it succeeded, or
--   it failed with a message.
data ProcessControlResultMsg =
    ProcessControlResultMsg NodeId [Either Fid (Fid, String)]
  deriving (Eq, Generic, Show, Typeable)
instance Binary ProcessControlResultMsg
instance Hashable ProcessControlResultMsg

data ProcessControlResultStopMsg =
      ProcessControlResultStopMsg NodeId [Either Fid (Fid,String)]
  deriving (Eq, Generic, Show, Typeable)
instance Binary ProcessControlResultStopMsg
instance Hashable ProcessControlResultStopMsg

data ProcessControlResultRestartMsg =
      ProcessControlResultRestartMsg NodeId [Either Fid (Fid,String)]
  deriving (Eq, Generic, Show, Typeable)
instance Binary ProcessControlResultRestartMsg
instance Hashable ProcessControlResultRestartMsg

data ProcessControlResultConfigureMsg =
      ProcessControlResultConfigureMsg NodeId [Either Fid (Fid,String)]
  deriving (Eq, Generic, Show, Typeable)
instance Binary ProcessControlResultConfigureMsg
instance Hashable ProcessControlResultConfigureMsg

-- | We haven't heard back from a process for a while about keepalive so we're
data KeepaliveTimedOut = KeepaliveTimedOut [(Fid, M0.TimeSpec)]
  deriving (Eq, Generic, Show, Typeable)
instance Binary KeepaliveTimedOut
instance Hashable KeepaliveTimedOut

data DeclareMeroChannel =
    DeclareMeroChannel
    { dmcPid     :: !(ServiceProcess MeroConf)
    , dmcChannel :: !(TypedChannel NotificationMessage)
    , dmcCtrlChannel :: !(TypedChannel ProcessControlMsg)
    }
    deriving (Generic, Typeable)

instance Binary DeclareMeroChannel
instance Hashable DeclareMeroChannel

data MeroChannelDeclared =
    MeroChannelDeclared
    { mcdPid     :: !(ServiceProcess MeroConf)
    , mcdChannel :: !(TypedChannel NotificationMessage)
    , mcdCtrlChannel :: !(TypedChannel ProcessControlMsg)
    }
    deriving (Generic, Typeable)

instance Binary MeroChannelDeclared
instance Hashable MeroChannelDeclared


resourceDictMeroChannel :: Dict (Resource (TypedChannel NotificationMessage))
resourceDictMeroChannel = Dict

resourceDictControlChannel :: Dict (Resource (TypedChannel ProcessControlMsg))
resourceDictControlChannel = Dict

relationDictMeroChanelServiceProcessChannel :: Dict (
    Relation MeroChannel (ServiceProcess MeroConf) (TypedChannel NotificationMessage)
  )
relationDictMeroChanelServiceProcessChannel = Dict

relationDictMeroChanelServiceProcessControlChannel :: Dict (
    Relation MeroChannel (ServiceProcess MeroConf) (TypedChannel ProcessControlMsg)
  )
relationDictMeroChanelServiceProcessControlChannel = Dict

meroSchema :: Schema MeroConf
meroSchema = MeroConf <$> ha <*> pr <*> pc <*> kaf <*> kat <*> ker
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

instance Relation MeroChannel (ServiceProcess MeroConf) (TypedChannel NotificationMessage) where
    relationDict = $(mkStatic 'relationDictMeroChanelServiceProcessChannel)

instance Relation MeroChannel (ServiceProcess MeroConf) (TypedChannel ProcessControlMsg) where
    relationDict = $(mkStatic 'relationDictMeroChanelServiceProcessControlChannel)


meroServiceName :: ServiceName
meroServiceName = ServiceName "m0d"
