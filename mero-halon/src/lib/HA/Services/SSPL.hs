-- |
-- Copyright : (C) 2014 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Service responsible for communication with a local SSPL instance on a node.
-- This service is used to collect low-level sensor data and to carry out
-- SSPL-mediated actions.

{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module HA.Services.SSPL
  ( sspl
  , ssplProcess
  , ssplRules
  , ActuatorChannels(..)
  , DeclareChannels(..)
  , InterestingEventMessage(..)
  , SSPLConf(..)
  , IEMChannel(..)
  , HA.Services.SSPL.LL.Resources.Channel(..)
  , HA.Services.SSPL.LL.Resources.__remoteTable
  , HA.Services.SSPL.__remoteTableDecl
  , sendNodeCmd
  , header
  ) where

import HA.EventQueue.Producer (promulgate)
import HA.RecoveryCoordinator.Mero (LoopState)
import HA.Service
import HA.Services.SSPL.CEP
import qualified HA.Services.SSPL.Rabbit as Rabbit
import HA.Services.SSPL.LL.Resources

import SSPL.Bindings

import Control.Concurrent.MVar
import Control.Distributed.Process
  ( Process
  , ProcessId
  , ProcessMonitorNotification(..)
  , expectTimeout
  , getSelfPid
  , getSelfNode
  , match
  , monitor
  , receiveChan
  , receiveWait
  , say
  , spawnChannelLocal
  , spawnLocal
  , unmonitor
  , link
  , expect
  , withMonitor
  )
import Control.Distributed.Process.Closure
import Control.Distributed.Static
  ( staticApply )
import Control.Monad.State.Strict hiding (mapM_)
import Data.Foldable (for_)

import Data.Aeson (decode, encode)
import qualified Data.Aeson as Aeson

import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Defaultable
import qualified Data.HashMap.Strict as M
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.UUID as UID
import qualified Data.HashMap.Strict as HM

import Network.AMQP
import Network.CEP (Definitions)

import Prelude hiding (id, mapM_)

import System.Random (randomIO)

header :: UID.UUID -> Aeson.Value
header uuid = Aeson.Object $ M.fromList [
    ("schema_version", Aeson.String "1.0.0")
  , ("sspl_version", Aeson.String "1.0.0")
  , ("msg_version", Aeson.String "1.0.0")
  , ("uuid", Aeson.String . T.decodeUtf8 . UID.toASCIIBytes $ uuid)
  ]


-- | Internal 'listen' handler. This is needed because AMQP runs in the
--   IO monad, so we cannot directly handle messages using `Process` actions.
msgHandler :: Network.AMQP.Message
           -> Process ()
msgHandler msg = do
  nid <- getSelfNode
  case decode (msgBody msg) :: Maybe SensorResponse of
    Just mr -> do
      say $ show mr
      void $ promulgate
        ( nid
        , sensorResponseMessageSensor_response_type
            . sensorResponseMessage $ mr
        )
    Nothing ->
      say $ "Unable to decode JSON message: " ++ (BL.unpack $ msgBody msg)

startSensors :: Network.AMQP.Channel -- ^ AMQP Channel
             -> SensorConf -- ^ Sensor configuration.
             -> Process ()
startSensors chan SensorConf{..} = do
  Rabbit.receive chan scDCS msgHandler

startActuators :: Network.AMQP.Channel
               -> ActuatorConf
               -> ProcessId -- ^ ProcessID of SSPL main process.
               -> Process ()
startActuators chan ac pid = do
    iemChan <- spawnChannelLocal (iemProcess $ acIEM ac)
    systemdChan <- spawnChannelLocal (commandProcess $ acSystemd ac)
    _ <- spawnLocal $ replyProcess (acCommandAck ac)
    informRC (ServiceProcess pid) (ActuatorChannels iemChan systemdChan)
  where
    cmdAckQueueName = T.pack . fromDefault . Rabbit.bcQueueName $ acCommandAck ac
    informRC sp chans = do
      mypid <- getSelfPid
      _ <- promulgate $ DeclareChannels mypid sp chans
      msg <- expectTimeout (fromDefault . acDeclareChanTimeout $ ac)
      case msg of
        Nothing -> informRC sp chans
        Just () -> return ()
    iemProcess Rabbit.BindConf{..} rp = forever $ do
      InterestingEventMessage foo <- receiveChan rp
      liftIO $ publishMsg
        chan
        (T.pack . fromDefault $ bcExchangeName)
        (T.pack . fromDefault $ bcRoutingKey)
        (newMsg { msgBody = BL.fromStrict $ T.encodeUtf8 foo
                , msgDeliveryMode = Just Persistent
                }
        )
    commandProcess Rabbit.BindConf{..} rp = forever $ do
      (muuid, cmd) <- receiveChan rp
      uuid <- liftIO $ maybe randomIO return muuid
      let msg = encode $ ActuatorRequest {
          actuatorRequestSignature = "Signature-is-not-implemented-yet"
        , actuatorRequestTime = ""
        , actuatorRequestExpires = Nothing
        , actuatorRequestUsername = "halon"
        , actuatorRequestMessage = ActuatorRequestMessage {
            actuatorRequestMessageSspl_ll_debug = Nothing
          , actuatorRequestMessageActuator_request_type = cmd
          , actuatorRequestMessageSspl_ll_msg_header = header uuid
          }
        }
      liftIO $ publishMsg
        chan
        (T.pack . fromDefault $ bcExchangeName)
        (T.pack . fromDefault $ bcRoutingKey)
        (newMsg { msgBody = msg
                , msgReplyTo = Just cmdAckQueueName
                , msgDeliveryMode = Just Persistent
                }
        )
    replyProcess Rabbit.BindConf{..} = Rabbit.receiveAck chan
      (T.pack . fromDefault $ bcExchangeName)
      (cmdAckQueueName)
      (T.pack . fromDefault $ bcRoutingKey)
      (\msg -> for_ (decode $ msgBody msg) $ \response -> do
          let uuid = (\(Aeson.Object hm) -> (\(Aeson.String s) -> s) <$> "uuid" `HM.lookup` hm)
                   . actuatorResponseMessageSspl_ll_msg_header
                   . actuatorResponseMessage $ response :: Maybe T.Text
              Just (ActuatorResponseMessageActuator_response_typeAck mmsg mtype)
                   = actuatorResponseMessageActuator_response_typeAck
                   . actuatorResponseMessageActuator_response_type
                   . actuatorResponseMessage $ response
          -- XXX: uuid-1.3.10 has UID.fromText primitive
          ppid <- promulgate $ CommandAck (UID.fromString =<< T.unpack <$> uuid)
                                          (parseNodeCmd  mtype)
                                          (parseAckReply mmsg)
          ProcessMonitorNotification _ _ _ <-
            withMonitor ppid $ expect
          return ())

remotableDecl [ [d|

  sspl :: Service SSPLConf
  sspl = Service
          (ServiceName "sspl")
          $(mkStaticClosure 'ssplProcess)
          ($(mkStatic 'someConfigDict)
              `staticApply` $(mkStatic 'configDictSSPLConf))

  ssplProcess :: SSPLConf -> Process ()
  ssplProcess (SSPLConf{..}) = let

    connectRetry lock = do
      me <- getSelfPid
      pid <- spawnLocal $ connectSSPL lock me
      mref <- monitor pid
      receiveWait [
          match $ \(ProcessMonitorNotification _ _ r) -> do
            say $ "SSPL Process died:\n\t" ++ show r
            connectRetry lock
        , match $ \() -> unmonitor mref >> (liftIO $ putMVar lock ())
        ]
    connectSSPL lock pid = do
      conn <- liftIO $ Rabbit.openConnection scConnectionConf
      chan <- liftIO $ openChannel conn
      startSensors chan scSensorConf
      startActuators chan scActuatorConf pid
      link pid
      () <- liftIO $ takeMVar lock
      liftIO $ closeConnection conn
      say "Connection closed."
    in do
      say $ "Starting service sspl"
      lock <- liftIO newEmptyMVar
      connectRetry lock

  |] ]

ssplRules :: Definitions LoopState ()
ssplRules = ssplRulesF sspl
