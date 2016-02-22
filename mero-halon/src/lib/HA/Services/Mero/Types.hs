{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.Mero.Types where

import HA.ResourceGraph
import HA.Service
import HA.Service.TH

import Mero.ConfC (Fid)
import Mero.Notification (Set)

import Control.Distributed.Process
import Control.Distributed.Process.Closure

import Data.Binary (Binary)
import Data.ByteString (ByteString)
import Data.Hashable (Hashable)
import Data.Monoid ((<>))
import Data.Typeable (Typeable)
import Data.UUID as UUID

import GHC.Generics (Generic)

import Options.Schema
import Options.Schema.Builder

-- | Mero kernel module configuration parameters
data MeroKernelConf = MeroKernelConf
       { mkcNodeUUID :: UUID    -- ^ Node UUID
       } deriving (Eq, Generic, Show, Typeable)
instance Binary MeroKernelConf
instance Hashable MeroKernelConf

-- | Mero service configuration
data MeroConf = MeroConf
       { mcHAAddress        :: String         -- ^ Address of the HA service endpoint
       , mcProfile          :: String         -- ^ FID of the current profile
       , mcKernelConfig     :: MeroKernelConf -- ^ Kernel configuration
       }
   deriving (Eq, Generic, Show, Typeable)
instance Binary MeroConf
instance Hashable MeroConf

newtype TypedChannel a = TypedChannel (SendPort a)
    deriving (Eq, Show, Typeable, Binary, Hashable)

data MeroChannel = MeroChannel deriving (Eq, Show, Typeable, Generic)

instance Binary MeroChannel
instance Hashable MeroChannel

data NotificationMessage = NotificationMessage
       { notificationMessage :: Set
       , notificationRecipients :: [String]
       }
     deriving (Typeable, Generic)
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
  | M0MKFS -- ^ Run 'mero-mkfs' service.
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
    StartProcesses [([ProcessRunType], ProcessConfig)]
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

data DeclareMeroChannel =
    DeclareMeroChannel
    { dmcPid     :: !(ServiceProcess MeroConf)
    , dmcChannel :: !(TypedChannel NotificationMessage)
    , dmcCtrlChannel :: !(TypedChannel ProcessControlMsg)
    }
    deriving (Generic, Typeable)

instance Binary DeclareMeroChannel
instance Hashable DeclareMeroChannel

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
meroSchema = MeroConf <$> ha <*> pr <*> ker
  where
    ha = strOption
          $  long "listenAddr"
          <> short 'l'
          <> metavar "LISTEN_ADDRESS"
          <> summary "HA service listen endpoint address"
    pr = strOption
          $  long "profile"
          <> short 'p'
          <> metavar "MERO_ADDRESS"
          <> summary "confd profile"
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
