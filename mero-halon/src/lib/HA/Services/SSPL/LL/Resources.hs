-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module HA.Services.SSPL.LL.Resources where

import Prelude hiding (id, mapM_, (<$>),(<*>))
import HA.Service
import HA.Service.TH
import qualified HA.Services.SSPL.Rabbit as Rabbit
import HA.ResourceGraph

import SSPL.Bindings
  ( ActuatorRequestMessageActuator_request_type (..)
  , ActuatorRequestMessageActuator_request_typeService_controller (..)
  , ActuatorRequestMessageActuator_request_typeNode_controller (..)
  )

import Control.Applicative ((<$>), (<*>))

import Control.Distributed.Process
  ( ProcessId
  , SendPort
  )
import Control.Distributed.Process.Closure

import Data.Binary (Binary)
import Data.Defaultable
import Data.Hashable (Hashable)
import Data.Monoid ((<>))
import qualified Data.Text as T
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Options.Schema (Schema)
import Options.Schema.Builder hiding (name, desc)

import System.IO.Unsafe (unsafePerformIO)
import System.Process (readProcess)

--------------------------------------------------------------------------------
-- SSPL Control messages                                                      --
--------------------------------------------------------------------------------

-- | Interesting Event Message.
--   TODO Make this more interesting.
newtype InterestingEventMessage = InterestingEventMessage T.Text
  deriving (Binary, Hashable, Typeable)

data ServiceOp = SERVICE_START | SERVICE_STOP | SERVICE_RESTART | SERVICE_STATUS
  deriving (Eq, Show, Generic, Typeable)

instance Binary ServiceOp
instance Hashable ServiceOp

serviceOpString :: ServiceOp -> T.Text
serviceOpString SERVICE_START = "start"
serviceOpString SERVICE_STOP = "stop"
serviceOpString SERVICE_RESTART = "restart"
serviceOpString SERVICE_STATUS = "status"

data SystemdCmd = SystemdCmd T.Text ServiceOp
  deriving (Eq, Show, Generic, Typeable)

instance Binary SystemdCmd
instance Hashable SystemdCmd

data IPMIOp = IPMI_ON | IPMI_OFF | IPMI_CYCLE | IPMI_STATUS
  deriving (Eq, Show, Generic, Typeable)

instance Binary IPMIOp
instance Hashable IPMIOp

ipmiOpString :: IPMIOp -> T.Text
ipmiOpString IPMI_ON = "on"
ipmiOpString IPMI_OFF = "off"
ipmiOpString IPMI_CYCLE = "cycle"
ipmiOpString IPMI_STATUS = "status"

data NodeCmd =
    IPMICmd IPMIOp T.Text -- ^ IP address
  deriving (Eq, Show, Generic, Typeable)

instance Binary NodeCmd
instance Hashable NodeCmd

nodeCmdString :: NodeCmd -> T.Text
nodeCmdString (IPMICmd op ip) = T.intercalate " "
  [ "IPMI:", ip, ipmiOpString op ]

emptyActuatorMsg :: ActuatorRequestMessageActuator_request_type
emptyActuatorMsg = ActuatorRequestMessageActuator_request_type
  { actuatorRequestMessageActuator_request_typeThread_controller = Nothing
  , actuatorRequestMessageActuator_request_typeLogin_controller = Nothing
  , actuatorRequestMessageActuator_request_typeNode_controller = Nothing
  , actuatorRequestMessageActuator_request_typeLogging = Nothing
  , actuatorRequestMessageActuator_request_typeService_controller = Nothing
  }

makeSystemdMsg :: SystemdCmd -> ActuatorRequestMessageActuator_request_type
makeSystemdMsg (SystemdCmd svcName op) = emptyActuatorMsg {
  actuatorRequestMessageActuator_request_typeService_controller = Just $
    ActuatorRequestMessageActuator_request_typeService_controller
      svcName (serviceOpString op)
}

makeNodeMsg :: NodeCmd -> ActuatorRequestMessageActuator_request_type
makeNodeMsg nc = emptyActuatorMsg {
  actuatorRequestMessageActuator_request_typeNode_controller = Just $
    ActuatorRequestMessageActuator_request_typeNode_controller
      (nodeCmdString nc)
}
--------------------------------------------------------------------------------
-- Channels                                                                   --
--------------------------------------------------------------------------------

-- | Actuator channel list
data ActuatorChannels = ActuatorChannels
    { iemPort :: SendPort InterestingEventMessage
    , systemdPort :: SendPort ActuatorRequestMessageActuator_request_type
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

data CommandChannel = CommandChannel
  deriving (Eq, Show, Typeable, Generic)

instance Binary CommandChannel
instance Hashable CommandChannel

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

commandSchema :: Schema Rabbit.BindConf
commandSchema = let
    en = defaultable "sspl_halon" . strOption
        $ long "systemd_exchange"
        <> metavar "EXCHANGE_NAME"
    rk = defaultable "sspl_ll" . strOption
          $ long "systemd_routingKey"
          <> metavar "ROUTING_KEY"
    qn = defaultable "sspl_halon" . strOption
          $ long "systemd_queue"
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
    subOpts = ActuatorConf <$> iemSchema <*> commandSchema <*> timeout
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

resourceDictChannelSystemd :: Dict (Resource (Channel ActuatorRequestMessageActuator_request_type))
resourceDictChannelSystemd = Dict

relationDictIEMChannelServiceProcessChannel :: Dict (
    Relation IEMChannel (ServiceProcess SSPLConf) (Channel InterestingEventMessage)
  )
relationDictIEMChannelServiceProcessChannel = Dict

relationDictCommandChannelServiceProcessChannel :: Dict (
    Relation CommandChannel (ServiceProcess SSPLConf) (Channel ActuatorRequestMessageActuator_request_type)
  )
relationDictCommandChannelServiceProcessChannel = Dict

$(generateDicts ''SSPLConf)
$(deriveService ''SSPLConf 'ssplSchema [ 'resourceDictChannelIEM
                                       , 'relationDictIEMChannelServiceProcessChannel
                                       , 'resourceDictChannelSystemd
                                       , 'relationDictCommandChannelServiceProcessChannel
                                       ])

instance Resource (Channel InterestingEventMessage) where
  resourceDict = $(mkStatic 'resourceDictChannelIEM)

instance Resource (Channel ActuatorRequestMessageActuator_request_type) where
  resourceDict = $(mkStatic 'resourceDictChannelSystemd)

instance Relation IEMChannel
                  (ServiceProcess SSPLConf)
                  (Channel InterestingEventMessage) where
  relationDict = $(mkStatic 'relationDictIEMChannelServiceProcessChannel)

instance Relation CommandChannel
                  (ServiceProcess SSPLConf)
                  (Channel ActuatorRequestMessageActuator_request_type) where
  relationDict = $(mkStatic 'relationDictCommandChannelServiceProcessChannel)
--------------------------------------------------------------------------------
-- End Dictionaries                                                           --
--------------------------------------------------------------------------------

