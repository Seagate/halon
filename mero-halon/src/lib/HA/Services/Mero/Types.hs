{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.Mero.Types where

import Data.Typeable (Typeable)
import GHC.Generics (Generic)

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Data.Binary (Binary)
import Data.ByteString (ByteString)
import Data.Hashable (Hashable)
import Data.Monoid ((<>))
import Data.UUID as UUID

import HA.ResourceGraph
import HA.Service
import HA.Service.TH
import Mero.Notification (Set)
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
       , mcServiceConf      :: MeroNodeConf   -- ^ Node configuration
       }
   deriving (Eq, Generic, Show, Typeable)
instance Binary MeroConf
instance Hashable MeroConf

-- | Node configuration
data MeroNodeConf = MeroClientConf { mccProcessFid :: String
                                   , mccMeroEndpoint :: String
                                   }
                  | MeroServerConf { mscConfString :: Maybe (ByteString, String)
                                   -- ^ If confd is meant to run on
                                   -- the host, pass the conf file
                                   -- content and process fid
                                   , mscMeroEndpoint :: String
                                   }
  deriving (Eq, Generic, Show, Typeable)

instance Binary MeroNodeConf
instance Hashable MeroNodeConf

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

data DeclareMeroChannel =
    DeclareMeroChannel
    { dmcPid     :: !(ServiceProcess MeroConf)
    , dmcChannel :: !(TypedChannel NotificationMessage)
    }
    deriving (Generic, Typeable)

instance Binary DeclareMeroChannel
instance Hashable DeclareMeroChannel

resourceDictMeroChannel :: Dict (Resource (TypedChannel NotificationMessage))
resourceDictMeroChannel = Dict

relationDictMeroChanelServiceProcessChannel :: Dict (
    Relation MeroChannel (ServiceProcess MeroConf) (TypedChannel NotificationMessage)
  )
relationDictMeroChanelServiceProcessChannel = Dict

meroSchema :: Schema MeroConf
meroSchema = MeroConf <$> ha <*> pr <*> ker <*> node
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
    node = oneOf [client]
    client = compositeOption clientOpts $ long "client" <> summary "client node"
    clientOpts = MeroClientConf <$> fid <*> mero
    fid = strOption
           $ long "fid"
           <> metavar "FID"
    mero = strOption
            $ long "mero"
            <> metavar "ENDPOINT"

kernelSchema :: Schema MeroKernelConf
kernelSchema = MeroKernelConf <$> uuid
  where
    uuid = option (maybe (fail "incorrect uuid format") return . UUID.fromString)
            $ long "uuid"
            <> short 'u'
            <> metavar "UUID"


$(generateDicts ''MeroConf)
$(deriveService ''MeroConf 'meroSchema [ 'resourceDictMeroChannel
                                       , 'relationDictMeroChanelServiceProcessChannel
                                       ])

instance Resource (TypedChannel NotificationMessage) where
    resourceDict = $(mkStatic 'resourceDictMeroChannel)

instance Relation MeroChannel (ServiceProcess MeroConf) (TypedChannel NotificationMessage) where
    relationDict = $(mkStatic 'relationDictMeroChanelServiceProcessChannel)

meroServiceName :: ServiceName
meroServiceName = ServiceName "m0d"
