{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
-- |
-- Copyright : (C) 2015-2017 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- SSPLHL service implementation
module HA.Services.SSPLHL where

import           Control.Applicative ((<$>), (<*>))
import           Control.Concurrent.MVar
import           Control.Distributed.Process
import           Control.Distributed.Process.Closure
import           Control.Distributed.Static ( staticApply )
import           Control.Monad (forever)
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

-- | Values that can be sent from SSPL-HL service to the RC.
data SsplHlToSvc =
  SResponse !CommandResponseMessage
  deriving (Show, Eq, Generic, Typeable)

-- | Values that can be sent from RC to the SSPL-HL service.
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

traceSSPLHL :: String -> Process ()
traceSSPLHL = mkHalonTracer "ssplhl-service"

logSSPL :: String -> IO ()
logSSPL s = putStrLn $ "[service:sspl-hl] " ++ s

cmdHandler :: ProcessId -- ^ Status handler
           -> SendPort CommandResponseMessage -- ^ Response channel
           -> ProcessId -- ^ Supervisor handler
           -> Network.AMQP.Message
           -> Process ()
cmdHandler statusHandler responseChan supervisor msg = case decode (msgBody msg) of
  Just cr
    | isJust . commandRequestMessageServiceRequest
             . commandRequestMessage $ cr -> do
      traceSSPLHL $ "Received: " ++ show cr
      sendRC interface $ CRequest cr
      let (CommandRequestMessage _ _ _ msgId) = commandRequestMessage cr
      uuid <- liftIO nextRandom
      sendChan responseChan $ CommandResponseMessage
        { commandResponseMessageStatusResponse = Nothing
        , commandResponseMessageResponseId = msgId
        , commandResponseMessageMessageId = Just . T.pack . toString $ uuid
        }
    | isJust . commandRequestMessageStatusRequest
             . commandRequestMessage $ cr -> do
      traceSSPLHL $ "Received: " ++ show cr
      usend statusHandler cr
    | otherwise -> do
      say $ "[sspl-hl] Unknown message " ++ show cr

  Nothing
    | msgBody msg == "keepalive" -> usend supervisor KeepAlive
    | otherwise -> say $ "Unable to decode command request: "
                      ++ (BL.unpack $ msgBody msg)

-- | Spawn a process waiting for 'CommandRequestMessage's and
-- forwarding their content to RC.
startStatusHandler :: SendPort CommandResponseMessage
                   -> Process ProcessId
startStatusHandler sp = spawnLocal $ forever $ do
  cr <- expect
  let CommandRequestMessage _ _ msr msgId = commandRequestMessage cr
  nid <- getSelfNode
  forM_ msr $ \req -> do
    sendRC interface $! SRequest req msgId nid
    -- We expect the RC to reply to service, and service to forward
    -- the reply to us.
    expect >>= sendChan sp

-- | Time when at least one keepalive message should be delivered
ssplHlTimeout :: Int
ssplHlTimeout = 5*1000000*60 -- 5m

remotableDecl [ [d|

  ssplProcess :: SSPLHLConf -> Process ()
  ssplProcess (SSPLHLConf{..}) = let

      connectRetry lock = do
        self <- getSelfPid
        pid <- spawnLocal $ connectSSPL lock self
        mref <- monitor pid
        flip fix Nothing $ \next msh -> do
          mx <- receiveTimeout ssplHlTimeout [
              match $ \(ProcessMonitorNotification _ _ r) -> do
                say $ "SSPL Process died:\n\t" ++ show r
                connectRetry lock
            , match $ \() -> unmonitor mref >> (liftIO $ void $ tryPutMVar lock ())
            , match $ \KeepAlive -> next msh
            , match $ \(StatusHandlerUp pid') -> do
                next $! Just pid'
            , match $ \case
                SResponse crm -> do
                  maybe (return ()) (\p -> usend p crm) msh
                  next msh
            ]
          case mx of
            Nothing -> unmonitor mref >> (liftIO $ void $ tryPutMVar lock ())
            Just x  -> return x
      connectSSPL lock parent = do
        C.bracket (liftIO $ Rabbit.openConnection scConnectionConf)
                  (\conn -> do liftIO $ closeConnection conn
                               say "Connection closed.")
          $ \conn -> do
          self <- getSelfPid
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
          _ <- spawnLocal $ do
            link self
            forever $ do
              _ <- receiveTimeout (ssplHlTimeout `div` 2) []
              liftIO $ publishMsg chan
                (T.pack $ fromDefault $ Rabbit.bcExchangeName scCommandConf)
                (T.pack $ fromDefault $ Rabbit.bcRoutingKey scCommandConf)
                newMsg{msgBody="keepalive"}
          responseChan <- spawnChannelLocal (responseProcess chan scResponseConf)
          statusHandler <- startStatusHandler responseChan
          Rabbit.receive chan scCommandConf (cmdHandler statusHandler responseChan parent)
          liftIO $ takeMVar lock :: Process ()

      responseProcess chan bc rp = forever $ do
        crm <- receiveChan rp
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

    in do
      lock <- liftIO newEmptyMVar
      connectRetry lock

  ssplFunctions :: ServiceFunctions SSPLHLConf
  ssplFunctions = ServiceFunctions  bootstrap mainloop teardown confirm where
    bootstrap conf = do
      self <- getSelfPid
      pid <- spawnLocalName "service::sspl-hl::process" $ do
        link self
        () <- expect
        ssplProcess conf
      return (Right pid)
    mainloop _ pid = return
      [ receiveSvc interface $ \msg -> do
          usend pid msg
          return (Continue, pid) ]
    teardown _ _ = return ()
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
