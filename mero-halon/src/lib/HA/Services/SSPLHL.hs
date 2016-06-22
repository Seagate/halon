-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module HA.Services.SSPLHL where

import Prelude hiding ((<$>), (<*>), id, mapM_)
import HA.EventQueue.Producer (promulgate)
import HA.Logger
import HA.Service
import HA.Service.TH
import qualified HA.Services.SSPL.HL.StatusHandler as StatusHandler
import qualified HA.Services.SSPL.Rabbit as Rabbit

import SSPL.Bindings

import Control.Applicative ((<$>), (<*>))

import Control.Concurrent.MVar
import Control.Distributed.Process
  ( Process
  , ProcessId
  , ProcessMonitorNotification(..)
  , SendPort
  , match
  , monitor
  , receiveChan
  , receiveWait
  , say
  , usend
  , sendChan
  , spawnChannelLocal
  , spawnLocal
  , unmonitor
  )
import Control.Distributed.Process.Closure
import Control.Distributed.Static
  ( staticApply )
import Control.Monad.State.Strict hiding (mapM_)

import Data.Aeson (ToJSON, decode, encode)
import Data.Binary (Binary)
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Defaultable
import Data.Hashable (Hashable)
import Data.Maybe (isJust)
import Data.Monoid ((<>))
import qualified Data.Text as T
import Data.Typeable (Typeable)
import Data.UUID (toString)
import Data.UUID.V4 (nextRandom)

import GHC.Generics (Generic)

import Network.AMQP

import Options.Schema (Schema)
import Options.Schema.Builder hiding (name, desc)

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

instance Binary SSPLHLConf
instance Hashable SSPLHLConf
instance ToJSON SSPLHLConf

ssplhlSchema :: Schema SSPLHLConf
ssplhlSchema = SSPLHLConf <$> Rabbit.connectionSchema
                          <*> commandSchema
                          <*> responseSchema

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

$(generateDicts ''SSPLHLConf)
$(deriveService ''SSPLHLConf 'ssplhlSchema [])

--------------------------------------------------------------------------------
-- End Dictionaries                                                           --
--------------------------------------------------------------------------------

traceSSPLHL :: String -> Process ()
traceSSPLHL = mkHalonTracer "ssplhl-service"

cmdHandler :: ProcessId -- ^ Status handler
           -> SendPort CommandResponseMessage -- ^ Response channel
           -> Network.AMQP.Message
           -> Process ()
cmdHandler statusHandler responseChan msg = case decode (msgBody msg) of
  Just cr
    | isJust . commandRequestMessageServiceRequest
             . commandRequestMessage $ cr -> do
      traceSSPLHL $ "Received: " ++ show cr
      _ <- promulgate cr
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

  Nothing -> say $ "Unable to decode command request: "
                      ++ (BL.unpack $ msgBody msg)

remotableDecl [ [d|

  ssplProcess :: SSPLHLConf -> Process ()
  ssplProcess (SSPLHLConf{..}) = let

      connectRetry lock = do
        pid <- spawnLocal $ connectSSPL lock
        mref <- monitor pid
        receiveWait [
            match $ \(ProcessMonitorNotification _ _ r) -> do
              say $ "SSPL Process died:\n\t" ++ show r
              connectRetry lock
          , match $ \() -> unmonitor mref >> (liftIO $ putMVar lock ())
          ]
      connectSSPL lock = do
        conn <- liftIO $ Rabbit.openConnection scConnectionConf
        chan <- liftIO $ openChannel conn
        responseChan <- spawnChannelLocal (responseProcess chan scResponseConf)
        statusHandler <- StatusHandler.start responseChan
        Rabbit.receive chan scCommandConf (cmdHandler statusHandler responseChan)
        () <- liftIO $ takeMVar lock
        liftIO $ closeConnection conn
        say "Connection closed."

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
      say $ "Starting service sspl-hl"
      lock <- liftIO newEmptyMVar
      connectRetry lock

  sspl :: Service SSPLHLConf
  sspl = Service
          (ServiceName "sspl-hl")
          $(mkStaticClosure 'ssplProcess)
          ($(mkStatic 'someConfigDict)
              `staticApply` $(mkStatic 'configDictSSPLHLConf))

  |] ]
