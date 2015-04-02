-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}

module HA.Services.SSPL.LL.Resources where

import Prelude hiding (id, mapM_, (<$>),(<*>))
import HA.Service
import HA.Service.TH
import qualified HA.Services.SSPL.Rabbit as Rabbit
import HA.ResourceGraph

import Control.Applicative ((<$>), (<*>))

import Control.Distributed.Process
  ( ProcessId
  , SendPort
  )
import Control.Distributed.Process.Closure

import Data.Binary (Binary)
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Defaultable
import Data.Hashable (Hashable)
import Data.Monoid ((<>))
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Options.Schema (Schema)
import Options.Schema.Builder hiding (name, desc)

import System.IO.Unsafe (unsafePerformIO)
import System.Process (readProcess)

-- | Interesting Event Message.
--   TODO Make this more interesting.
newtype InterestingEventMessage = InterestingEventMessage BL.ByteString
  deriving (Binary, Hashable, Typeable)

-- | Systemd actuation message.
--   TODO Bind this to schema.
data SystemdRequest = SystemdRequest {
      srService :: BL.ByteString
    , srCommand :: BL.ByteString
  } deriving (Generic, Typeable, Show)

instance Binary SystemdRequest
instance Hashable SystemdRequest

-- | Actuator channel list
data ActuatorChannels = ActuatorChannels
    { iemPort :: SendPort InterestingEventMessage
    , systemdPort :: SendPort SystemdRequest
    }
  deriving (Generic, Typeable)

instance Binary ActuatorChannels
instance Hashable ActuatorChannels

-- | Message to the RC advertising which channels to talk on.
data DeclareChannels = DeclareChannels
    ProcessId -- ^ Identity of reporting process
    (ServiceProcess SSPLConf) -- ^ Identity of the service process
    ActuatorChannels -- ^ Relevant channels
  deriving (Generic, Typeable)

instance Binary DeclareChannels
instance Hashable DeclareChannels

-- | Resource graph representation of a channel
newtype Channel a = Channel (SendPort a)
  deriving (Eq, Show, Typeable, Binary, Hashable)

-- | Relation connecting the SSPL service process to its IEM channel.
data IEMChannel = IEMChannel
  deriving (Eq, Show, Typeable, Generic)

instance Binary IEMChannel
instance Hashable IEMChannel

data SystemdChannel = SystemdChannel
  deriving (Eq, Show, Typeable, Generic)

instance Binary SystemdChannel
instance Hashable SystemdChannel

--------------------------------------------------------------------------------
-- Configuration                                                              --
--------------------------------------------------------------------------------

iemSchema :: Schema Rabbit.BindConf
iemSchema = let
    en = defaultable "sspl_iem" . strOption
        $ long "iem_exchange"
        <> metavar "EXCHANGE_NAME"
    rk = defaultable "sspl_ll" . strOption
          $ long "iem_routingKey"
          <> metavar "ROUTING_KEY"
    qn = defaultable "sspl_iem" . strOption
          $ long "dcs_queue"
          <> metavar "QUEUE_NAME"
  in Rabbit.BindConf <$> en <*> rk <*> qn

systemdSchema :: Schema Rabbit.BindConf
systemdSchema = let
    en = defaultable "halon_sspl" . strOption
        $ long "systemd_exchange"
        <> metavar "EXCHANGE_NAME"
    rk = defaultable "sspl_ll" . strOption
          $ long "systemd_routingKey"
          <> metavar "ROUTING_KEY"
    qn = defaultable "halon_sspl" . strOption
          $ long "dcs_queue"
          <> metavar "QUEUE_NAME"
  in Rabbit.BindConf <$> en <*> rk <*> qn

data ActuatorConf = ActuatorConf {
    acIEM :: Rabbit.BindConf
  , acSystemd :: Rabbit.BindConf
  , acDeclareChanTimeout :: Defaultable Int
} deriving (Eq, Generic, Show, Typeable)

instance Binary ActuatorConf
instance Hashable ActuatorConf

actuatorSchema :: Schema ActuatorConf
actuatorSchema = compositeOption subOpts
                  $ long "actuator"
                  <> summary "Actuator configuration."
  where
    subOpts = ActuatorConf <$> iemSchema <*> systemdSchema <*> timeout
    timeout = defaultable 5000000 . intOption
                $ long "declareChannelsTimeout"
                <> summary "Timeout to use when declaring channels to the RC."
                <> metavar "MICROSECONDS"

dcsSchema :: Schema Rabbit.BindConf
dcsSchema = let
    en = defaultable "sspl_halon" . strOption
        $ long "dcs_exchange"
        <> metavar "EXCHANGE_NAME"
    rk = defaultable "sspl_ll" . strOption
          $ long "dcs_routingKey"
          <> metavar "ROUTING_KEY"
    qn = defaultable shortHostName . strOption
          $ long "dcs_queue"
          <> metavar "QUEUE_NAME"
          where
            shortHostName = unsafePerformIO $ readProcess "hostname" ["-s"] ""
  in Rabbit.BindConf <$> en <*> rk <*> qn

data SensorConf = SensorConf {
    scDCS :: Rabbit.BindConf
} deriving (Eq, Generic, Show, Typeable)

instance Binary SensorConf
instance Hashable SensorConf

sensorSchema :: Schema SensorConf
sensorSchema = compositeOption subOpts
                  $ long "sensor"
                  <> summary "Sensor configuration."
  where
    subOpts = SensorConf <$> dcsSchema

data SSPLConf = SSPLConf {
    scConnectionConf :: Rabbit.ConnectionConf
  , scSensorConf :: SensorConf
  , scActuatorConf :: ActuatorConf
} deriving (Eq, Generic, Show, Typeable)

instance Binary SSPLConf
instance Hashable SSPLConf

ssplSchema :: Schema SSPLConf
ssplSchema = SSPLConf
            <$> Rabbit.connectionSchema
            <*> sensorSchema
            <*> actuatorSchema

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------
resourceDictChannelIEM :: Dict (Resource (Channel InterestingEventMessage))
resourceDictChannelIEM = Dict

resourceDictChannelSystemd :: Dict (Resource (Channel SystemdRequest))
resourceDictChannelSystemd = Dict

relationDictIEMChannelServiceProcessChannel :: Dict (
    Relation IEMChannel (ServiceProcess SSPLConf) (Channel InterestingEventMessage)
  )
relationDictIEMChannelServiceProcessChannel = Dict

relationDictSystemdChannelServiceProcessChannel :: Dict (
    Relation SystemdChannel (ServiceProcess SSPLConf) (Channel SystemdRequest)
  )
relationDictSystemdChannelServiceProcessChannel = Dict

$(generateDicts ''SSPLConf)
$(deriveService ''SSPLConf 'ssplSchema [ 'resourceDictChannelIEM
                                       , 'relationDictIEMChannelServiceProcessChannel
                                       , 'resourceDictChannelSystemd
                                       , 'relationDictSystemdChannelServiceProcessChannel
                                       ])

instance Resource (Channel InterestingEventMessage) where
  resourceDict = $(mkStatic 'resourceDictChannelIEM)

instance Resource (Channel SystemdRequest) where
  resourceDict = $(mkStatic 'resourceDictChannelSystemd)

instance Relation IEMChannel
                  (ServiceProcess SSPLConf)
                  (Channel InterestingEventMessage) where
  relationDict = $(mkStatic 'relationDictIEMChannelServiceProcessChannel)

instance Relation SystemdChannel
                  (ServiceProcess SSPLConf)
                  (Channel SystemdRequest) where
  relationDict = $(mkStatic 'relationDictSystemdChannelServiceProcessChannel)
--------------------------------------------------------------------------------
-- End Dictionaries                                                           --
--------------------------------------------------------------------------------

