-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}

module HA.Services.SSPL.Resources where

import HA.Service hiding (configDict)
import HA.ResourceGraph
import HA.Resources (Cluster(..), Node(..))


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

import Prelude hiding (id, mapM_)

import System.IO.Unsafe (unsafePerformIO)
import System.Process (readProcess)

-- | Interesting Event Message.
--   TODO Make this more interesting.
newtype InterestingEventMessage = InterestingEventMessage BL.ByteString
  deriving (Binary, Hashable, Typeable)

-- | Actuator channel list
data ActuatorChannels = ActuatorChannels
    { iemPort :: SendPort InterestingEventMessage }
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

--------------------------------------------------------------------------------
-- Configuration                                                              --
--------------------------------------------------------------------------------

data IEMConf = IEMConf {
    iemExchangeName :: Defaultable String
  , iemRoutingKey :: Defaultable String
} deriving (Eq, Generic, Show, Typeable)

instance Binary IEMConf
instance Hashable IEMConf

iemSchema :: Schema IEMConf
iemSchema = let
    en = defaultable "sspl_iem" . strOption
        $ long "iem_exchange"
        <> metavar "EXCHANGE_NAME"
    rk = defaultable "sspl_ll" . strOption
          $ long "routingKey"
          <> metavar "ROUTING_KEY"
  in IEMConf <$> en <*> rk

data ActuatorConf = ActuatorConf {
    acIEM :: IEMConf
  , acDeclareChanTimeout :: Defaultable Int
} deriving (Eq, Generic, Show, Typeable)

instance Binary ActuatorConf
instance Hashable ActuatorConf

actuatorSchema :: Schema ActuatorConf
actuatorSchema = compositeOption subOpts
                  $ long "actuator"
                  <> summary "Actuator configuration."
  where
    subOpts = ActuatorConf <$> iemSchema <*> timeout
    timeout = defaultable 5000000 . intOption
                $ long "declareChannelsTimeout"
                <> summary "Timeout to use when declaring channels to the RC."
                <> metavar "MICROSECONDS"

data DCSConf = DCSConf {
    dcsExchangeName :: Defaultable String
  , dcsRoutingKey :: Defaultable String
  , dcsQueueName :: Defaultable String
} deriving (Eq, Generic, Show, Typeable)

instance Binary DCSConf
instance Hashable DCSConf

dcsSchema :: Schema DCSConf
dcsSchema = let
    en = defaultable "sspl_bcast" . strOption
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
  in DCSConf <$> en <*> rk <*> qn

data SensorConf = SensorConf {
    scDCS :: DCSConf
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
    scHostname :: Defaultable String
  , scVirtualHost :: Defaultable String
  , scLoginName :: String
  , scPassword :: String
  , scSensorConf :: SensorConf
  , scActuatorConf :: ActuatorConf
} deriving (Eq, Generic, Show, Typeable)

instance Binary SSPLConf
instance Hashable SSPLConf

ssplSchema :: Schema SSPLConf
ssplSchema = let
    hn = defaultable "127.0.0.1" . strOption
          $  long "hostname"
          <> metavar "HOSTNAME"
    vh = defaultable "SSPL" . strOption
          $  long "vhost"
          <> metavar "VIRTUAL_HOST"
          <> summary "RabbitMQ Virtual Host to connect to."
    un = strOption
          $  long "username"
          <> short 'u'
          <> metavar "USERNAME"
    pw = strOption
          $ long "password"
          <> short 'p'
          <> metavar "PASSWORD"
  in SSPLConf <$> hn <*> vh <*> un <*> pw <*> sensorSchema <*> actuatorSchema

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

configDict :: Dict (Configuration SSPLConf)
configDict = Dict

serializableDict :: SerializableDict SSPLConf
serializableDict = SerializableDict

--TODO Can we auto-gen this whole section?
resourceDictService :: Dict (Resource (Service SSPLConf))
resourceDictServiceProcess :: Dict (Resource (ServiceProcess SSPLConf))
resourceDictConfigItem :: Dict (Resource SSPLConf)
resourceDictChannelIEM :: Dict (Resource (Channel InterestingEventMessage))
resourceDictService = Dict
resourceDictServiceProcess = Dict
resourceDictConfigItem = Dict
resourceDictChannelIEM = Dict

relationDictSupportsClusterService :: Dict (
    Relation Supports Cluster (Service SSPLConf)
  )
relationDictHasNodeServiceProcess :: Dict (
    Relation Runs Node (ServiceProcess SSPLConf)
  )
relationDictWantsServiceProcessConfigItem :: Dict (
    Relation WantsConf (ServiceProcess SSPLConf) SSPLConf
  )
relationDictHasServiceProcessConfigItem :: Dict (
    Relation HasConf (ServiceProcess SSPLConf) SSPLConf
  )
relationDictInstanceOfServiceServiceProcess :: Dict (
    Relation InstanceOf (Service SSPLConf) (ServiceProcess SSPLConf)
  )
relationDictOwnsServiceProcessServiceName :: Dict (
    Relation Owns (ServiceProcess SSPLConf) ServiceName
  )
relationDictIEMChannelServiceProcessChannel :: Dict (
    Relation IEMChannel
             (ServiceProcess SSPLConf)
             (Channel InterestingEventMessage)
  )
relationDictSupportsClusterService = Dict
relationDictHasNodeServiceProcess = Dict
relationDictWantsServiceProcessConfigItem = Dict
relationDictHasServiceProcessConfigItem = Dict
relationDictInstanceOfServiceServiceProcess = Dict
relationDictOwnsServiceProcessServiceName = Dict
relationDictIEMChannelServiceProcessChannel = Dict

remotable
  [ 'configDict
  , 'serializableDict
  , 'resourceDictService
  , 'resourceDictServiceProcess
  , 'resourceDictConfigItem
  , 'resourceDictChannelIEM
  , 'relationDictSupportsClusterService
  , 'relationDictHasNodeServiceProcess
  , 'relationDictWantsServiceProcessConfigItem
  , 'relationDictHasServiceProcessConfigItem
  , 'relationDictInstanceOfServiceServiceProcess
  , 'relationDictOwnsServiceProcessServiceName
  , 'relationDictIEMChannelServiceProcessChannel
  ]

instance Resource (Service SSPLConf) where
  resourceDict = $(mkStatic 'resourceDictService)

instance Resource (ServiceProcess SSPLConf) where
  resourceDict = $(mkStatic 'resourceDictServiceProcess)

instance Resource SSPLConf where
  resourceDict = $(mkStatic 'resourceDictConfigItem)

instance Resource (Channel InterestingEventMessage) where
  resourceDict = $(mkStatic 'resourceDictChannelIEM)

instance Relation Supports Cluster (Service SSPLConf) where
  relationDict = $(mkStatic 'relationDictSupportsClusterService)

instance Relation Runs Node (ServiceProcess SSPLConf) where
  relationDict = $(mkStatic 'relationDictHasNodeServiceProcess)

instance Relation HasConf (ServiceProcess SSPLConf) SSPLConf where
  relationDict = $(mkStatic 'relationDictHasServiceProcessConfigItem)

instance Relation WantsConf (ServiceProcess SSPLConf) SSPLConf where
  relationDict = $(mkStatic 'relationDictWantsServiceProcessConfigItem)

instance Relation InstanceOf (Service SSPLConf) (ServiceProcess SSPLConf) where
  relationDict = $(mkStatic 'relationDictInstanceOfServiceServiceProcess)

instance Relation Owns (ServiceProcess SSPLConf) ServiceName where
  relationDict = $(mkStatic 'relationDictOwnsServiceProcessServiceName)

instance Relation IEMChannel
                  (ServiceProcess SSPLConf)
                  (Channel InterestingEventMessage) where
  relationDict = $(mkStatic 'relationDictIEMChannelServiceProcessChannel)
--------------------------------------------------------------------------------
-- End Dictionaries                                                           --
--------------------------------------------------------------------------------

instance Configuration SSPLConf where
  schema = ssplSchema
  sDict = $(mkStatic 'serializableDict)
