{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
-- |
-- Copyright : (C) 2014-2017 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Service responsible for communication with a local SSPL instance on a node.
-- This service is used to collect low-level sensor data and to carry out
-- SSPL-mediated actions.
module HA.Services.SSPL
  ( sspl
  , ssplProcess
  , InterestingEventMessage(..)
  , SSPLConf(..)
  , NodeCmd(..)
  , CommandAck(..)
  , AckReply(..)
  , HA.Services.SSPL.LL.Resources.Channel(..)
  , HA.Services.SSPL.LL.Resources.__remoteTable
  , HA.Services.SSPL.__resourcesTable
  , HA.Services.SSPL.__remoteTableDecl
  , header
    -- * Unused but defined
  , sspl__static
  ) where

import           Control.Concurrent.MVar
import           Control.Distributed.Process
import           Control.Distributed.Process.Closure
import           Control.Distributed.Static ( staticApply, RemoteTable )
import qualified Control.Monad.Catch as C
import           Control.Monad.State.Strict hiding (mapM_)
import           Control.Monad.Trans.Maybe
import           Data.Binary (Binary)
import qualified Data.ByteString.Lazy.Char8 as BL
import           Data.Defaultable
import           Data.Foldable (for_)
import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import           Data.Time (getCurrentTime, addUTCTime)
import           Data.Typeable (Typeable)
import qualified Data.UUID as UID
import           GHC.Generics (Generic)
import qualified HA.Aeson as Aeson
import           HA.Debug
import           HA.Logger (mkHalonTracer)
import           HA.Service
import           HA.Service.Interface
import           HA.Services.SSPL.IEM
import           HA.Services.SSPL.LL.Resources
import qualified HA.Services.SSPL.Rabbit as Rabbit
import           Network.AMQP
import           Prelude hiding (id, mapM_)
import           SSPL.Bindings
import           System.Random (randomIO)
import qualified System.SystemD.API as SystemD

__resourcesTable :: RemoteTable -> RemoteTable
__resourcesTable = HA.Services.SSPL.LL.Resources.myResourcesTable

header :: UID.UUID -> ActuatorRequestMessageSspl_ll_msg_header
header uuid = ActuatorRequestMessageSspl_ll_msg_header {
    actuatorRequestMessageSspl_ll_msg_headerMsg_expiration = Nothing
  , actuatorRequestMessageSspl_ll_msg_headerUuid =
      Just $ T.decodeUtf8 . UID.toASCIIBytes $ uuid
  , actuatorRequestMessageSspl_ll_msg_headerSspl_version = "1.0.0"
  , actuatorRequestMessageSspl_ll_msg_headerMsg_version = "1.0.0"
  , actuatorRequestMessageSspl_ll_msg_headerSchema_version = "1.0.0"
  }

-- | Messages that are always logged.
saySSPL :: String -> Process ()
saySSPL msg = say $ "[Service:SSPL] " ++ msg

-- | Trace messages, output only in case if debug mode is set.
traceSSPL :: String -> Process ()
traceSSPL = mkHalonTracer "service:sspl"

-- | Messages that are always logged.
logSSPL :: String -> IO ()
logSSPL msg = putStrLn $ "[Service:SSPL] " ++ msg

-- | Maximum allowed timeout between any sspl messages.
ssplMaxMessageTimeout :: Int
ssplMaxMessageTimeout = 10*60*1000000

-- | Internal 'listen' handler. This is needed because AMQP runs in the
--   IO monad, so we cannot directly handle messages using `Process` actions.
msgHandler :: SendPort () -- ^ Monitor channel.
           -> Network.AMQP.Message
           -> Process ()
msgHandler chan msg = do
  sendChan chan ()
  nid <- getSelfNode
  case Aeson.decode (msgBody msg) :: Maybe SensorResponse of
    Just mr -> whenNotExpired mr $ do
      -- XXX: check that message was sent by sspl service
      let srms = sensorResponseMessageSensor_response_type . sensorResponseMessage $ mr
          sendMessage s f = forM_ (f srms) $ \x -> do
            traceSSPL $ "[SSPL-Service] received " ++ s
            sendRC interface x
          ignoreMessage s f = forM_ (f srms) $ \_ -> do
            traceSSPL $ s ++ " is not used by RC, ignoring."
      sendMessage "SensorResponse.HPI" $
        fmap (DiskHpi nid) . sensorResponseMessageSensor_response_typeDisk_status_hpi
      ignoreMessage "SensorResponse.IF"
        sensorResponseMessageSensor_response_typeIf_data
      ignoreMessage "SensorResponse.Host"
        sensorResponseMessageSensor_response_typeHost_update
      sendMessage "SensorResponse.DriveManager" $
        fmap (DiskStatusDm nid) . sensorResponseMessageSensor_response_typeDisk_status_drivemanager
      sendMessage "SensorResponse.Watchdog" $
        fmap ServiceWatchdog . sensorResponseMessageSensor_response_typeService_watchdog
      ignoreMessage "SensorResponse.MountData"
        sensorResponseMessageSensor_response_typeLocal_mount_data
      ignoreMessage "SensorResponse.CPU"
        sensorResponseMessageSensor_response_typeCpu_data
      sendMessage "SensorResponse.Raid" $
        fmap (RaidData nid) . sensorResponseMessageSensor_response_typeRaid_data
      sendMessage "SensorResponse.ExpanderReset" $
        fmap (const (ExpanderResetInternal nid)) . sensorResponseMessageSensor_response_typeExpander_reset

    Nothing -> case Aeson.decode (msgBody msg) :: Maybe ActuatorResponse of
      Just ar -> do
        let arms = actuatorResponseMessageActuator_response_type . actuatorResponseMessage $ ar
            sendMessage s f = forM_ (f arms) $ \x -> do
              traceSSPL $ "received " ++ s
              sendRC interface x
        sendMessage "ActuatorResponse.ThreadController" $
          fmap (ThreadController nid) . actuatorResponseMessageActuator_response_typeThread_controller
      Nothing -> saySSPL $ "Unable to decode JSON message: " ++ BL.unpack (msgBody msg)
   where
     whenNotExpired s f = do
      mte <- runMaybeT $ (,) <$> (parseTimeSSPL $ sensorResponseTime s)
                             <*> (maybe mzero return $ sensorResponseExpires s)
      case mte of
        Nothing -> f
        Just (t,e) -> do c <- liftIO $ getCurrentTime
                         if fromIntegral e `addUTCTime` t < c
                           then saySSPL $ "Message outdated: " ++ show s
                           else f

startSensors :: Network.AMQP.Channel -- ^ AMQP Channel.
             -> SendPort () -- ^ Monitor channel.
             -> SensorConf -- ^ Sensor configuration.
             -> Process ()
startSensors chan monChan SensorConf{..} = do
  Rabbit.receive chan scDCS (msgHandler monChan)

startActuators :: Network.AMQP.Channel
               -> ActuatorConf
               -> ProcessId -- ^ ProcessID of SSPL main process.
               -> SendPort ()
               -> Process ActuatorChannels
startActuators chan ac pid monitorChan = do
    iemChan <- spawnChannelLocal $ \ch -> do
      liftIO $ Rabbit.setupBind chan (acIEM ac)
      link pid
      iemProcess (acIEM ac) ch

    systemdChan <- spawnChannelLocal $ \ch -> do
      liftIO $ Rabbit.setupBind chan (acSystemd ac)
      link pid
      commandProcess (acSystemd ac) ch

    _ <- spawnLocal $ link pid >> replyProcess (acCommandAck ac)
    return $! ActuatorChannels iemChan systemdChan
  where
    cmdAckQueueName = T.pack . fromDefault . Rabbit.bcQueueName $ acCommandAck ac
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
      let msg = Aeson.encode $ ActuatorRequest {
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
      saySSPL $ unwords [ "commandProcess"
                        , fromDefault bcExchangeName
                        , fromDefault bcRoutingKey
                        , show msg ]
      liftIO $ publishMsg
        chan
        (T.pack $ fromDefault bcExchangeName)
        (T.pack $ fromDefault bcRoutingKey)
        (newMsg { msgBody = msg
                , msgReplyTo = Just cmdAckQueueName
                , msgDeliveryMode = Just Persistent
                }
        )
    replyProcess Rabbit.BindConf{..} = Rabbit.receiveAck chan cmdAckQueueName
      (\msg -> for_ (Aeson.decode $ msgBody msg) $ \response -> do
          uuid <- case actuatorResponseMessageSspl_ll_msg_header $ actuatorResponseMessage $ response of
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
               let ca = CommandAck (UID.fromString =<< T.unpack <$> uuid)
                                              (parseNodeCmd  mtype)
                                              reply
               traceSSPL $ "Sending reply: " ++ show ca
               sendRC interface $! CAck ca
               sendChan monitorChan ())

-- | Test that messages are sent on a timely manner.
monitorProcess :: ReceivePort () -> Process()
monitorProcess rchan = forever $ receiveChanTimeout ssplMaxMessageTimeout rchan >>= \case
      Nothing -> do node <- getSelfNode
                    sendRC interface $ SSPLServiceTimeout node
      _ -> return ()

-- | Tell 'ssplProcess' that it's time to stop and that it should
-- disconnect.
data StopServiceInternal = StopServiceInternal
  deriving (Eq, Typeable, Generic)
instance Binary StopServiceInternal

-- | Main daemon for SSPL halon service
ssplProcess :: SSPLConf -> Process ()
ssplProcess (SSPLConf{..}) = let

  connectRetry lock = do
    me <- getSelfPid
    pid <- spawnLocal $ connectSSPL lock me
    ActuatorChannels iemCh sysCh <- expect :: Process ActuatorChannels
    mref <- monitor pid
    flip fix False $ \loop !shutdown -> do
      receiveWait [
          matchIf (\(ProcessMonitorNotification m _ _) -> m == mref)
                  $ \(ProcessMonitorNotification _ _ r) -> do
            saySSPL $ "Process died:" ++ show r
            unless shutdown $ do
              saySSPL "Restarting connectRetry..."
              _ <- receiveTimeout 2000000 []
              connectRetry lock
        , match $ \case
            ResetSSPLService -> do
              saySSPL "restarting RabbitMQ and sspl-ll."
              liftIO $ do
                void $ SystemD.restartService "rabbitmq-server.service"
                void $ SystemD.restartService "sspl-ll.service"
                void $ tryPutMVar lock ()
              loop shutdown
            SsplIem iem -> do
              sendChan iemCh iem
              loop shutdown
            SystemdMessage muid arma -> do
              sendChan sysCh (muid, arma)
              loop shutdown
        , match $ \StopServiceInternal -> do
            saySSPL $ "tearing server down"
            liftIO . void $ tryPutMVar lock ()
            loop True
        ]
  connectSSPL lock pid = do
    node <- getSelfNode
    -- In case if it's not possible to connect to rabbitmq service
    -- just exits.
    let failure = do saySSPL "Failed to connect to RabbitMQ"
                     usend pid ()
                     sendRC interface $ SSPLConnectFailure node
    let retry 0 action = action `C.onException` failure
        retry n action = do
          C.try action >>= \case
            Right x -> return x
            Left (_ :: C.SomeException) -> do
              _ <- receiveTimeout 1000000 []
              retry (n-1 :: Int) action
    conn <- retry 10 (liftIO $ Rabbit.openConnection scConnectionConf)
    chan <- liftIO $ do
      chan <- openChannel conn
      addReturnListener chan $ \(_msg, err) ->
        logSSPL $ unlines [ "Error during publishing message (" ++ show (errReplyCode err) ++ ")"
                          , "  " ++ maybe ("No exchange") (\x -> "Exchange: " ++ T.unpack x) (errExchange err)
                          , "  Routing key: " ++ T.unpack (errRoutingKey err)
                          ]
      addChannelExceptionHandler chan $ \se -> do
        logSSPL $ "Exception on channel: " ++ show se
        void $ tryPutMVar lock ()
      return chan
    (sendPort, receivePort) <- newChan
    startSensors chan sendPort scSensorConf
    decl <- startActuators chan scActuatorConf pid sendPort
    usend pid decl
    rc <- spawnLocal $ link pid >> monitorProcess receivePort
    link pid
    () <- liftIO $ takeMVar lock
    kill rc "restart"
    liftIO $ closeConnection conn
    saySSPL "Connection closed."
  in do
    say $ "Starting service sspl"
    lock <- liftIO newEmptyMVar
    connectRetry lock

remotableDecl [ [d|

  sspl :: Service SSPLConf
  sspl = Service (ifServiceName interface)
          $(mkStaticClosure 'ssplFunctions)
          ($(mkStatic 'someConfigDict)
              `staticApply` $(mkStatic 'configDictSSPLConf))

  ssplFunctions :: ServiceFunctions SSPLConf
  ssplFunctions = ServiceFunctions  bootstrap mainloop teardown confirm where
    bootstrap conf = do
      self <- getSelfPid
      pid <- spawnLocalName "service::sspl::process" $ do
        link self
        () <- expect
        ssplProcess conf
      -- TODO: We no longer store or declare channels in RG. We should
      -- therefore not mark the service as running until the channels
      -- are ready or fail the service if we can not connect to them.
      -- It's the right thing to do.
      --
      -- Not all is lost if channels aren't ready however: the process
      -- will not start consuming the messages until it has created
      -- the channels. This is a double-edged sword: on one side, we
      -- will not lose any messages that we send before the channels
      -- are up. On the other side however, we will just indefinitely
      -- accumulate messages if the channels never come up. We should
      -- only declare service as started once we have channels and we
      -- should only send messages to it after it has started.
      --
      -- It turns out that even if we announce service start late,
      -- service internals announce service as started straight away.
      return (Right pid)
    mainloop _ pid = return
      [ matchIf (\(ProcessMonitorNotification _ p _) -> p == pid) $ \_ ->
          return (Teardown, pid)
      , match $ \x@(ProcessMonitorNotification _ _ _) -> do
          usend pid x >> return (Continue, pid)
      , receiveSvc interface $ \msg -> do
          usend pid msg
          return (Continue, pid)
      , match $ \() -> usend pid () >> return (Continue, pid)
      ]
    teardown _ pid = do
      mref <- monitor pid
      usend pid StopServiceInternal
      receiveWait [ matchIf (\(ProcessMonitorNotification m _ _) -> mref == m)
                            (\_ -> return ())
                  ]
    confirm  _ pid = usend pid ()
  |] ]
