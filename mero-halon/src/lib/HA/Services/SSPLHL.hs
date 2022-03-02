{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
-- |
-- Copyright : (C) 2015-2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- SSPLHL service implementation
module HA.Services.SSPLHL where

import           Control.Applicative ((<$>), (<*>))
import           Control.Concurrent.STM
import           Control.Distributed.Process
import           Control.Distributed.Process.Closure
import           Control.Distributed.Static ( staticApply )
import           Control.Monad (mapM_)
import qualified Control.Monad.Catch as C
import           Control.Monad.State.Strict hiding (mapM_)
import           Data.Binary (Binary)
import qualified Data.ByteString.Lazy.Char8 as BL
import           Data.Defaultable
import           Data.Foldable (forM_)
import           Data.Hashable (Hashable)
import           Data.Maybe (isJust)
import           Data.Monoid ((<>))
import qualified Data.Text as T
import           Data.Typeable (Typeable)
import           Data.UUID (toString)
import           Data.UUID.V4 (nextRandom)
import           GHC.Generics (Generic)
import           HA.Aeson (ToJSON, decode, encode)
import           HA.Debug
import           HA.Logger
import           HA.SafeCopy
import           HA.Service
import           HA.Service.Interface
import           HA.Service.TH
import qualified HA.Services.SSPL.Rabbit as Rabbit
import           Network.AMQP
import           Options.Schema (Schema)
import           Options.Schema.Builder hiding (name, desc)
import           Prelude hiding ((<$>), (<*>), id, mapM_)
import           SSPL.Bindings
import qualified System.SystemD.API as SystemD
import           Text.Printf (printf)

--------------------------------------------------------------------------------
-- Configuration                                                              --
--------------------------------------------------------------------------------

commandSchema :: Schema Rabbit.BindConf
commandSchema = let
    en = defaultable "sspl_hl_cmd" . strOption
        $ long "cmd_exchange"
        <> metavar "EXCHANGE_NAME"
    rk = defaultable "sspl_hl_cmd" . strOption
          $ long "cmd_routingKey"
          <> metavar "ROUTING_KEY"
    qn = defaultable "sspl_hl_cmd" . strOption
          $ long "cmd_queue"
          <> metavar "QUEUE_NAME"
  in Rabbit.BindConf <$> en <*> rk <*> qn

responseSchema :: Schema Rabbit.BindConf
responseSchema = let
    en = defaultable "sspl_hl_resp" . strOption
        $ long "cmd_resp_exchange"
        <> metavar "EXCHANGE_NAME"
        <> summary "Exchange to send command responses to."
    rk = defaultable "sspl_hl_resp" . strOption
          $ long "cmd_resp_routingKey"
          <> metavar "ROUTING_KEY"
          <> summary "Routing key to apply to command responses."
    qn = defaultable "sspl_hl_resp" . strOption
          $ long "cmd_resp_queue"
          <> metavar "QUEUE_NAME"
          <> summary "Queue to bind command responses to."
  in Rabbit.BindConf <$> en <*> rk <*> qn

data SSPLHLConf = SSPLHLConf {
    scConnectionConf :: Rabbit.ConnectionConf
  , scCommandConf :: Rabbit.BindConf
  , scResponseConf :: Rabbit.BindConf
} deriving (Eq, Generic, Show, Typeable)

type instance ServiceState SSPLHLConf = ProcessId

instance Hashable SSPLHLConf
instance ToJSON SSPLHLConf

deriveSafeCopy 0 'base ''SSPLHLConf

ssplhlSchema :: Schema SSPLHLConf
ssplhlSchema = SSPLHLConf <$> Rabbit.connectionSchema
                          <*> commandSchema
                          <*> responseSchema

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

storageIndex ''SSPLHLConf "235a6c98-7405-4909-9407-35f61c905e02"
serviceStorageIndex ''SSPLHLConf "62d727bc-3f65-40c2-b8a9-a469623cb33f"
$(generateDicts ''SSPLHLConf)
$(deriveService ''SSPLHLConf 'ssplhlSchema [])

--------------------------------------------------------------------------------
-- End Dictionaries                                                           --
--------------------------------------------------------------------------------

data KeepAlive = KeepAlive deriving (Eq, Show, Generic, Typeable)
instance Binary KeepAlive

newtype StatusHandlerUp = StatusHandlerUp ProcessId
  deriving (Eq, Show, Generic, Typeable, Binary)

-- | Values that can be sent to SSPL-HL service from the RC.
data SsplHlToSvc =
    SResponse !CommandResponseMessage
  | Reset -- ^ Reset this service, including restarting rabbitmq
  deriving (Show, Eq, Generic, Typeable)

-- | Values that can be sent to RC from the SSPL-HL service.
data SsplHlFromSvc
  = CRequest !CommandRequest
  | SRequest !CommandRequestMessageStatusRequest !(Maybe T.Text) !NodeId
  deriving (Show, Eq, Generic, Typeable)

-- | SSPL-HL 'Interface'
interface :: Interface SsplHlToSvc SsplHlFromSvc
interface = Interface
  { ifVersion = 0
  , ifServiceName = "sspl-hl"
  , ifEncodeToSvc = \_v -> Just . safeEncode interface
  , ifDecodeToSvc = safeDecode
  , ifEncodeFromSvc = \_v -> Just . safeEncode interface
  , ifDecodeFromSvc = safeDecode
  }

-- | Splice @'ifServiceName' 'interface'@ of the service into the
-- format string. Useful for consistent naming.
spliceName :: String -> String
spliceName fmt = printf fmt (ifServiceName interface)

-- | Messages that are always logged.
saySSPL :: String -> Process ()
saySSPL msg = say $ spliceName "[Service:%s] " ++ msg

-- | Trace messages, output only in case if debug mode is set.
traceSSPL :: String -> Process ()
traceSSPL = mkHalonTracer (spliceName "service:%s")

-- | Messages that are always logged.
logSSPL :: String -> IO ()
logSSPL msg = putStrLn $ spliceName "[Service:%s] " ++ msg

-- | Time when at least one keepalive message should be delivered
ssplHlTimeout :: Int
ssplHlTimeout = 5*1000000*60 -- 5m

-- | Tell 'ssplProcess' that it's time to stop and that it should
-- disconnect.
data StopServiceInternal = StopServiceInternal
  deriving (Eq, Typeable, Generic)
instance Binary StopServiceInternal

-- | Main service process.
ssplProcess :: SSPLHLConf -> Process ()
ssplProcess (conf@SSPLHLConf{..}) = 
  Rabbit.openConnectionRetry scConnectionConf 10 5000000 >>= \case
    Left e -> do
      saySSPL $ "Failed to connect to RabbitMQ: " ++ show e
    Right conn -> do
      saySSPL $ "Connection to RabbitMQ opened."
      chan <- startRmqChannel conn
      (statusChan, runTeardown) <- startRmqCustomers chan conn

      fix $ \loop -> receiveWait
        [ match $ \case
            -- Shut down all current processes, restart sspl-ll and
            -- rabbitmq-server and connect fresh.
            Reset -> do
              saySSPL "restarting RabbitMQ and sspl-ll."
              runTeardown
              liftIO $ do
                void $ SystemD.restartService "rabbitmq-server.service"
              ssplProcess conf
            SResponse crm -> do
              liftIO . atomically $ writeTChan statusChan crm
              loop
        , match $ \StopServiceInternal -> do
            saySSPL $ "tearing server down"
            runTeardown
        ]

  where
    -- Open RMQ channel and register exception handlers.
    startRmqChannel :: Network.AMQP.Connection -> Process Network.AMQP.Channel
    startRmqChannel conn = do
      chan <- liftIO $ openChannel conn
      liftIO . addReturnListener chan $ \(_msg, err) ->
        logSSPL $ unlines [ "Error during publishing message (" ++ show (errReplyCode err) ++ ")"
                          , "  " ++ maybe ("No exchange") (\x -> "Exchange: " ++ T.unpack x) (errExchange err)
                          , "  Routing key: " ++ T.unpack (errRoutingKey err)
                          ]

      -- Spin up a process that waits for AMQ exception var to be
      -- filled and lets the main process know if it ever does. Note
      -- that it only listens for one exception then quits.
      amqExceptionVar <- liftIO $ newTVarIO Nothing
      mainPid <- getSelfPid
      _ <- spawnLocal $ do
        link mainPid
        exc :: AMQPException <- liftIO . atomically $
          readTVar amqExceptionVar >>= maybe retry return
        saySSPL $ "RabbitMQ exception on the channel: " ++ show exc
        usend mainPid Reset

      -- Register exception handler that fills the AMQ exception var.
      liftIO . addChannelExceptionHandler chan $
        atomically . writeTVar amqExceptionVar . C.fromException

      return chan

    -- Start all the workers and provide a blocking teardown call.
    startRmqCustomers :: Network.AMQP.Channel
                      -> Network.AMQP.Connection
                      -> Process (TChan CommandResponseMessage, Process ())
    startRmqCustomers chan conn = do
      self <- getSelfPid

      responseDone <- liftIO $ newTVarIO Rabbit.Running
      statusDone <- liftIO $ newTVarIO Rabbit.Running
      cmdDone <- liftIO $ newTVarIO Rabbit.Running
      
      let tvars = [responseDone, statusDone, cmdDone]

      -- Spawn keepalive sending process
      keepAlive <- spawnLocal $ do
        link self
        fix $ \loop -> do
          ka <- expectTimeout ssplHlTimeout
          case ka of
            Just KeepAlive -> do
              -- Wait for half the period
              _ <- receiveTimeout (ssplHlTimeout `div` 2) []
              -- Send new keepalive ping
              _ <- liftIO $ publishMsg chan
                (T.pack $ fromDefault $ Rabbit.bcExchangeName scCommandConf)
                (T.pack $ fromDefault $ Rabbit.bcRoutingKey scCommandConf)
                newMsg{msgBody="keepalive"}
              loop
            Nothing -> usend self Reset

      -- Get a channel on which replies can be sent.
      responseChan <- liftIO newTChanIO
      responseHandler chan scResponseConf responseDone responseChan

      -- Spawn the actual command handler.
      cmdHandler responseChan keepAlive cmdDone chan 
                 (T.pack . fromDefault $ Rabbit.bcQueueName scCommandConf)

      let runTeardown = do
            liftIO $ do
              -- Signal to all processes that they should stop.
              mapM_ (\t -> atomically $ writeTVar t Rabbit.Dying) tvars
              -- Wait until they have all signalled that they are
              -- finished by putting True back into their vars.
              atomically $ do
                allDone <- all (== Rabbit.Dead) <$> mapM readTVar tvars
                unless allDone retry

              -- Close RMQ resources.
              closeChannel chan
              closeConnection conn

            -- Stop the monitoring process too though we don't really
            -- care when it dies as long as it's soon-ish.
            kill keepAlive "restart"
            saySSPL "Connection to RabbitMQ closed."
      return (responseChan, runTeardown)

    -- Process responsible for sending responses to commands sent by SSPL-HL.
    responseHandler chan bc desiredState tchan = 
      Rabbit.consumeChanOrDie tchan desiredState $ \crm -> do
        let foo = CommandResponse {
            commandResponseSignature = ""
          , commandResponseTime = ""
          , commandResponseExpires = Nothing
          , commandResponseUsername = "halon/sspl-hl"
          , commandResponseMessage = crm
        }
        liftIO $ publishMsg
          chan
          (T.pack . fromDefault $ Rabbit.bcExchangeName bc)
          (T.pack . fromDefault $ Rabbit.bcRoutingKey bc)
          (newMsg { msgBody = encode foo
                  , msgDeliveryMode = Just Persistent
                  }
          )

    -- Receives commands from SSPL-HL and dispatches them accordingly.
    -- Some comamnds are handled directly inside this function, where
    -- they do not require a response from the RC. Others are dispatched
    -- to separate processes (e.g. status handler)
    cmdHandler :: TChan CommandResponseMessage -- Response handler
               -> ProcessId -- Keep alive handler
               -> TVar Rabbit.DesiredWorkerState
               -> Network.AMQP.Channel -- Channel to listen on
               -> T.Text -- Queue name
               -> Process ()
    cmdHandler responseChan ka desiredState amqpChan qName = 
      Rabbit.receive amqpChan qName desiredState NoAck $ \msg -> 
        case decode (msgBody msg) of
          Just cr
            | isJust . commandRequestMessageServiceRequest
                     . commandRequestMessage $ cr -> do
              traceSSPL $ "Received: " ++ show cr
              sendRC interface $ CRequest cr
              let (CommandRequestMessage _ _ _ msgId) = commandRequestMessage cr
              uuid <- liftIO nextRandom
              liftIO . atomically . writeTChan responseChan $ CommandResponseMessage
                { commandResponseMessageStatusResponse = Nothing
                , commandResponseMessageResponseId = msgId
                , commandResponseMessageMessageId = Just . T.pack . toString $ uuid
                }
            | isJust . commandRequestMessageStatusRequest
                     . commandRequestMessage $ cr -> do
              traceSSPL $ "Received: " ++ show cr
              let (CommandRequestMessage _ _ msr msgId) = commandRequestMessage cr
              forM_ msr $ \req -> do
                nid <- getSelfNode
                sendRC interface $! SRequest req msgId nid
            | otherwise -> do
              say $ "[sspl-hl] Unknown message " ++ show cr
          Nothing
            | msgBody msg == "keepalive" -> usend ka KeepAlive
            | otherwise -> say $ "Unable to decode command request: "
                              ++ (BL.unpack $ msgBody msg)


remotableDecl [ [d|

  ssplFunctions :: ServiceFunctions SSPLHLConf
  ssplFunctions = ServiceFunctions bootstrap mainloop teardown confirm where
    bootstrap conf = do
      self <- getSelfPid
      pid <- spawnLocalName (spliceName "service::%s::process") $ do
        link self
        () <- expect
        ssplProcess conf
      return (Right pid)
    mainloop _ pid = return
      [ receiveSvc interface $ \msg -> do
          usend pid msg
          return (Continue, pid) ]
    teardown _ pid = do
      mref <- monitor pid
      usend pid StopServiceInternal
      receiveWait [ matchIf (\(ProcessMonitorNotification m _ _) -> mref == m)
                            (\_ -> return ())
                  ]
    confirm  _ pid = usend pid ()

  sspl :: Service SSPLHLConf
  sspl = Service (ifServiceName interface)
          $(mkStaticClosure 'ssplFunctions)
          ($(mkStatic 'someConfigDict)
              `staticApply` $(mkStatic 'configDictSSPLHLConf))
  |] ]

instance HasInterface SSPLHLConf  where
  type ToSvc SSPLHLConf = SsplHlToSvc
  type FromSvc SSPLHLConf = SsplHlFromSvc
  getInterface _ = interface

deriveSafeCopy 0 'base ''SsplHlFromSvc
deriveSafeCopy 0 'base ''SsplHlToSvc
