-- |
-- Copyright : (C) 2014 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Service responsible for communication with a local SSPL instance on a node.
-- This service is used to collect low-level sensor data and to carry out
-- SSPL-mediated actions.

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module HA.Services.SSPL
  ( sspl
  , ssplProcess
  , ActuatorChannels(..)
  , DeclareChannels(..)
  , InterestingEventMessage(..)
  , SSPLConf(..)
  , HA.Services.SSPL.__remoteTable
  , HA.Services.SSPL.__remoteTableDecl
  ) where

import HA.NodeAgent.Messages
import HA.EventQueue.Producer (promulgate)
import HA.Service hiding (configDict)
import HA.ResourceGraph
import HA.Resources (Cluster, Node)

import SSPL.Bindings

import Control.Applicative ((<$>), (<*>))
import Control.Concurrent.Chan
import Control.Concurrent.MVar
import Control.Distributed.Process
  ( Process
  , SendPort
  , catch
  , catchExit
  , expect
  , expectTimeout
  , getSelfPid
  , liftIO
  , receiveChan
  , say
  , spawnChannelLocal
  , spawnLocal
  )
import Control.Distributed.Process.Closure
import Control.Distributed.Static
  ( staticApply )
import Control.Monad (forever)

import Data.Aeson (decode)
import Data.Binary (Binary)
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Defaultable
import Data.Foldable (mapM_)
import Data.Hashable (Hashable)
import Data.Monoid ((<>))
import qualified Data.Text as T
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Network.AMQP

import Options.Schema (Schema)
import Options.Schema.Builder hiding (name, desc)

import Prelude hiding (mapM_)

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
    en = defaultable "iem_bcast" . strOption
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
resourceDictChannelIEM :: Dict (Resource (HA.Services.SSPL.Channel InterestingEventMessage))
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
    Relation IEMChannel (ServiceProcess SSPLConf) (HA.Services.SSPL.Channel InterestingEventMessage)
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

instance Resource (HA.Services.SSPL.Channel InterestingEventMessage) where
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
                  (HA.Services.SSPL.Channel InterestingEventMessage) where
  relationDict = $(mkStatic 'relationDictIEMChannelServiceProcessChannel)
--------------------------------------------------------------------------------
-- End Dictionaries                                                           --
--------------------------------------------------------------------------------

instance Configuration SSPLConf where
  schema = ssplSchema
  sDict = $(mkStatic 'serializableDict)

-- | Internal 'listen' handler. This is needed because AMQP runs in the
--   IO monad, so we cannot directly handle messages using `Process` actions.
msgHandler :: Chan Network.AMQP.Message
           -> Process ()
msgHandler chan = forever $ do
  msg <- liftIO $ readChan chan
  case decode (msgBody msg) :: Maybe MonitorResponse of
    Just mr -> do
      mapM_ promulgate
            $ monitorResponseMonitor_msg_typeHost_update
            . monitorResponseMonitor_msg_type
            $ mr
      mapM_ promulgate
            $ monitorResponseMonitor_msg_typeDisk_status_drivemanager
            . monitorResponseMonitor_msg_type
            $ mr
    Nothing ->
      say $ "Unable to decode JSON message: " ++ (BL.unpack $ msgBody msg)

startSensors :: Network.AMQP.Channel -- ^ AMQP Channel
             -> Chan Network.AMQP.Message -- ^ Local channel to forward messages to.
             -> SensorConf -- ^ Sensor configuration.
             -> Process ()
startSensors chan lChan sc = do
    liftIO $ do
      declareExchange chan newExchange
        { exchangeName = exchangeName
        , exchangeType = "topic"
        , exchangeDurable = True
        }
      _ <- declareQueue chan newQueue { queueName = queueName }
      bindQueue chan queueName exchangeName routingKey

      _ <- consumeMsgs chan queueName Ack $ \(message, envelope) -> do
        writeChan lChan message
        ackEnv envelope
      return ()
  where
    DCSConf{..} = scDCS sc
    exchangeName = T.pack . fromDefault $ dcsExchangeName
    queueName = T.pack . fromDefault $ dcsQueueName
    routingKey = T.pack . fromDefault $ dcsRoutingKey

startActuators :: Network.AMQP.Channel
               -> ActuatorConf
               -> Process ()
startActuators chan ac = do
    pid <- getSelfPid
    iemChan <- spawnChannelLocal (iemProcess $ acIEM ac)
    informRC (ServiceProcess pid) (ActuatorChannels iemChan)
  where
    informRC sp chans = do
      promulgate $ DeclareChannels sp chans
      msg <- expectTimeout (fromDefault . acDeclareChanTimeout $ ac)
      case msg of
        Nothing -> informRC sp chans
        Just () -> return ()
    iemProcess IEMConf{..} rp = forever $ do
      InterestingEventMessage foo <- receiveChan rp
      liftIO $ publishMsg
        chan
        (T.pack . fromDefault $ iemExchangeName)
        (T.pack . fromDefault $ iemRoutingKey)
        (newMsg { msgBody = foo
                , msgDeliveryMode = Just Persistent
                }
        )

remotableDecl [ [d|

  ssplProcess :: SSPLConf -> Process ()
  ssplProcess (SSPLConf{..}) = let
    host = fromDefault $ scHostname
    vhost = T.pack . fromDefault $ scVirtualHost
    un = T.pack scLoginName
    pw = T.pack scPassword

    onExit _ Shutdown = say $ "SSPLService stopped."
    onExit _ Reconfigure = say $ "SSPLService stopping for reconfiguration."

    connectRetry lChan lock = catch
      (connectSSPL lChan lock)
      (\e -> let _ = (e :: AMQPException) in
        connectRetry lChan lock
      )
    connectSSPL lChan lock = do
      conn <- liftIO $ openConnection host vhost un pw
      chan <- liftIO $ openChannel conn
      startSensors chan lChan scSensorConf
      startActuators chan scActuatorConf
      () <- liftIO $ takeMVar lock
      liftIO $ closeConnection conn
      say "Connection closed."
    in (`catchExit` onExit) $ do
      say $ "Starting service sspl"
      lChan <- liftIO newChan
      lock <- liftIO newEmptyMVar
      _ <- spawnLocal $ msgHandler lChan
      _ <- spawnLocal $ connectRetry lChan lock
      () <- expect
      liftIO $ putMVar lock ()
      return ()

  sspl :: Service SSPLConf
  sspl = Service
          (ServiceName "sspl")
          $(mkStaticClosure 'ssplProcess)
          ($(mkStatic 'someConfigDict)
              `staticApply` $(mkStatic 'configDict))

  |] ]
