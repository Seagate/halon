-- |
-- Copyright : (C) 2014 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Service responsible for communication with a local SSPL instance on a node.
-- This service is used to collect low-level sensor data and to carry out
-- SSPL-mediated actions.
--
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE LambdaCase #-}

module HA.Services.SSPL
  ( sspl
  , ssplProcess
  , ssplRules
  , ActuatorChannels(..)
  , DeclareChannels(..)
  , InterestingEventMessage(..)
  , SSPLConf(..)
  , IEMChannel(..)
  , NodeCmd(..)
  , CommandAck(..)
  , AckReply(..)
  , HA.Services.SSPL.LL.Resources.Channel(..)
  , HA.Services.SSPL.LL.Resources.__remoteTable
  , HA.Services.SSPL.__remoteTableDecl
  , sendNodeCmd
  , header
  , sendInterestingEvent
  ) where

import HA.EventQueue.Producer (promulgate, promulgateWait)
import HA.RecoveryCoordinator.Mero (LoopState)
import HA.Service
import HA.Services.SSPL.CEP
import HA.Services.SSPL.IEM
import qualified HA.Services.SSPL.Rabbit as Rabbit
import HA.Services.SSPL.LL.Resources
import qualified System.SystemD.API as SystemD

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
  , receiveChanTimeout
  , receiveWait
  , say
  , sendChan
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
import Control.Monad.Trans.Maybe
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
import Data.Time (getCurrentTime, addUTCTime)

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

saySSPL :: String -> Process ()
saySSPL msg = say $ "[Service:SSPL] " ++ msg

-- | Maximum allowed timeout between any sspl messages.
ssplMaxMessageTimeout :: Int
ssplMaxMessageTimeout = 4*60*1000000

-- | Internal 'listen' handler. This is needed because AMQP runs in the
--   IO monad, so we cannot directly handle messages using `Process` actions.
msgHandler :: Network.AMQP.Message
           -> Process ()
msgHandler msg = do
  nid <- getSelfNode
  case decode (msgBody msg) :: Maybe SensorResponse of
    Just mr -> whenNotExpired mr $ do
      -- XXX: check that message was sent by sspl service
      -- XXX: check that message was not expired yet
      let srms = sensorResponseMessageSensor_response_type . sensorResponseMessage $ mr
          sendMessage s f = forM_ (f srms) $ \x -> do
            say $ "[SSPL-Service] received " ++ s
            promulgate (nid, x)
          ignoreMessage s f = forM_ (f srms) $ \_ -> do
            saySSPL $ s ++ "is not used by RC, ignoring"
      sendMessage "SensorResponse.HPI"
        sensorResponseMessageSensor_response_typeDisk_status_hpi
      ignoreMessage "SensorResponse.IF"
        sensorResponseMessageSensor_response_typeIf_data
      sendMessage "SensorResponse.Host"
        sensorResponseMessageSensor_response_typeHost_update 
      sendMessage "SensorResponse.DriveManager"
         sensorResponseMessageSensor_response_typeDisk_status_drivemanager
      ignoreMessage "SensorResponse.Watchdog"
         sensorResponseMessageSensor_response_typeService_watchdog
      ignoreMessage "SensorResponse.MountData"
         sensorResponseMessageSensor_response_typeLocal_mount_data
      sendMessage "SensorResponse.CPU"
         sensorResponseMessageSensor_response_typeCpu_data
      sendMessage "SensorResponse.Raid"
         sensorResponseMessageSensor_response_typeRaid_data 

    Nothing -> case decode (msgBody msg) :: Maybe ActuatorResponse of
      Just ar -> do 
        let arms = actuatorResponseMessageActuator_response_type . actuatorResponseMessage $ ar
            sendMessage s f = forM_ (f arms) $ \x -> do
              saySSPL $ "received " ++ s
              promulgate (nid, x)
        sendMessage "ActuatorResponse.ThreadController"
          actuatorResponseMessageActuator_response_typeThread_controller
      Nothing -> say $ "Unable to decode JSON message: " ++ (BL.unpack $ msgBody msg)
   where
     whenNotExpired s f = do
      mte <- runMaybeT $ (,) <$> (parseTimeSSPL $ sensorResponseTime s)
                             <*> (maybe mzero return $ sensorResponseExpires s)
      case mte of
        Nothing -> f
        Just (t,e) -> do c <- liftIO $ getCurrentTime
                         saySSPL $ show (t,e, fromIntegral e `addUTCTime` t, c)
                         if fromIntegral e `addUTCTime` t < c
                           then saySSPL $ "Message outdated: " ++ show s
                           else f

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
    monitorChan <- spawnChannelLocal monitorProcess
    iemChan <- spawnChannelLocal (iemProcess $ acIEM ac)
    systemdChan <- spawnChannelLocal (commandProcess $ acSystemd ac)
    _ <- spawnLocal $ replyProcess (acCommandAck ac) monitorChan
    informRC (ServiceProcess pid) (ActuatorChannels iemChan systemdChan)
  where
    cmdAckQueueName = T.pack . fromDefault . Rabbit.bcQueueName $ acCommandAck ac
    informRC sp chans = do
      mypid <- getSelfPid
      _ <- promulgate $ DeclareChannels mypid sp chans
      _ <- expect :: Process ProcessMonitorNotification
      msg <- expectTimeout (fromDefault . acDeclareChanTimeout $ ac)
      case msg of
        Nothing -> informRC sp chans
        Just () -> return ()
    iemProcess Rabbit.BindConf{..} rp = forever $ do
      InterestingEventMessage iem <- receiveChan rp
      liftIO $ publishMsg
        chan
        (T.pack . fromDefault $ bcExchangeName)
        (T.pack . fromDefault $ bcRoutingKey)
        (newMsg { msgBody = BL.fromChunks [iemToBytes iem]
                , msgDeliveryMode = Just Persistent
                }
        )
    commandProcess Rabbit.BindConf{..} rp = forever $ do
      (muuid, cmd) <- receiveChan rp
      uuid <- liftIO $ maybe randomIO return muuid
      msgTime <- liftIO getCurrentTime
      let msg = encode $ ActuatorRequest {
          actuatorRequestSignature = "Signature-is-not-implemented-yet"
        , actuatorRequestTime = formatTimeSSPL msgTime
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
    replyProcess Rabbit.BindConf{..} monitorChan = Rabbit.receiveAck chan
      (T.pack . fromDefault $ bcExchangeName)
      (cmdAckQueueName)
      (T.pack . fromDefault $ bcRoutingKey)
      (\msg -> for_ (decode $ msgBody msg) $ \response -> do
          uuid <- case (actuatorResponseMessageSspl_ll_msg_header $ actuatorResponseMessage $ response) of
             Aeson.Object hm ->  case "uuid" `HM.lookup` hm of
                                   Just (Aeson.String s) -> return (Just s)
                                   Just Aeson.Null -> return Nothing
                                   _ -> do saySSPL $ "Unexpected structure in message header: " ++ show hm
                                           return Nothing
             _ -> do saySSPL $ "Unexpected structure in reply " ++ show response
                     return Nothing
          let Just (ActuatorResponseMessageActuator_response_typeAck mmsg mtype)
                   = actuatorResponseMessageActuator_response_typeAck
                   . actuatorResponseMessageActuator_response_type
                   . actuatorResponseMessage $ response
          -- XXX: uuid-1.3.10 has UID.fromText primitive
          case tryParseAckReply mmsg of
            Left t -> saySSPL $ "Failed to parse SSPL reply (" ++ t ++ ") in " ++ T.unpack mmsg
            Right reply -> do
               let ca =  CommandAck (UID.fromString =<< T.unpack <$> uuid)
                                               (parseNodeCmd  mtype)
                                               reply
               saySSPL $ "Sending reply: " ++ show ca
               ppid <- promulgateWait  ca
               sendChan monitorChan ())
    monitorProcess rchan = forever $ receiveChanTimeout ssplMaxMessageTimeout rchan >>= \case
      Nothing -> do node <- getSelfNode 
                    promulgateWait (SSPLServiceTimeout node)
      _ -> return ()

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
      fix $ \loop -> 
        receiveWait [
            match $ \(ProcessMonitorNotification _ _ r) -> do
              say $ "SSPL Process died:\n\t" ++ show r
              connectRetry lock
          , match $ \ResetSSPLService -> do
              liftIO $ do
                void $ SystemD.restartService "rabbitmq-server.service"
                void $ SystemD.restartService "sspl-ll.service"
                putMVar lock ()
              loop
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
