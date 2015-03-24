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
  , HA.Services.SSPL.Resources.Channel(..)
  , HA.Services.SSPL.Resources.__remoteTable
  , HA.Services.SSPL.__remoteTableDecl
  ) where

import HA.NodeAgent.Messages
import HA.EventQueue.Producer (promulgate)
import HA.Service
import HA.Services.SSPL.CEP
import HA.Services.SSPL.Resources

import SSPL.Bindings

import Control.Concurrent.Chan
import Control.Concurrent.MVar
import Control.Distributed.Process
  ( Process
  , ProcessId
  , catch
  , catchExit
  , expect
  , expectTimeout
  , getSelfPid
  , getSelfNode
  , receiveChan
  , say
  , spawnChannelLocal
  , spawnLocal
  )
import Control.Distributed.Process.Closure
import Control.Distributed.Static
  ( staticApply )
import Control.Monad.State.Strict hiding (mapM_)

import Data.Aeson (decode)

import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Defaultable
import Data.Foldable (mapM_)
import qualified Data.Text as T

import Network.AMQP

import Prelude hiding (id, mapM_)

-- | Internal 'listen' handler. This is needed because AMQP runs in the
--   IO monad, so we cannot directly handle messages using `Process` actions.
msgHandler :: Chan Network.AMQP.Message
           -> Process ()
msgHandler chan = forever $ do
  msg <- liftIO $ readChan chan
  nid <- getSelfNode
  case decode (msgBody msg) :: Maybe MonitorResponse of
    Just mr -> do
      say $ show mr
      mapM_ promulgate
            $ fmap (nid,)
            . monitorResponseMonitor_msg_typeHost_update
            . monitorResponseMonitor_msg_type
            $ mr
      mapM_ promulgate
            $ fmap (nid,)
            . monitorResponseMonitor_msg_typeDisk_status_drivemanager
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
               -> ProcessId -- ^ ProcessID of SSPL main process.
               -> Process ()
startActuators chan ac pid = do
    iemChan <- spawnChannelLocal (iemProcess $ acIEM ac)
    systemdChan <- spawnChannelLocal (systemdProcess $ acSystemd ac)
    informRC (ServiceProcess pid) (ActuatorChannels iemChan systemdChan)
  where
    informRC sp chans = do
      mypid <- getSelfPid
      _ <- promulgate $ DeclareChannels mypid sp chans
      msg <- expectTimeout (fromDefault . acDeclareChanTimeout $ ac)
      case msg of
        Nothing -> informRC sp chans
        Just () -> return ()
    iemProcess ChannelConf{..} rp = forever $ do
      InterestingEventMessage foo <- receiveChan rp
      liftIO $ publishMsg
        chan
        (T.pack . fromDefault $ ccExchangeName)
        (T.pack . fromDefault $ ccRoutingKey)
        (newMsg { msgBody = foo
                , msgDeliveryMode = Just Persistent
                }
        )
    systemdProcess ChannelConf{..} rp = forever $ do
      SystemdRequest foo <- receiveChan rp
      liftIO $ publishMsg
        chan
        (T.pack . fromDefault $ ccExchangeName)
        (T.pack . fromDefault $ ccRoutingKey)
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

    connectRetry lChan lock pid = catch
      (connectSSPL lChan lock pid)
      (\e -> let _ = (e :: AMQPException) in
        connectRetry lChan lock pid
      )
    connectSSPL lChan lock pid = do
      conn <- liftIO $ openConnection host vhost un pw
      chan <- liftIO $ openChannel conn
      startSensors chan lChan scSensorConf
      startActuators chan scActuatorConf pid
      () <- liftIO $ takeMVar lock
      liftIO $ closeConnection conn
      say "Connection closed."
    in (`catchExit` onExit) $ do
      say $ "Starting service sspl"
      pid <- getSelfPid
      lChan <- liftIO newChan
      lock <- liftIO newEmptyMVar
      _ <- spawnLocal $ msgHandler lChan
      _ <- spawnLocal $ connectRetry lChan lock pid
      () <- expect
      liftIO $ putMVar lock ()
      return ()

  sspl :: Service SSPLConf
  sspl = Service
          (ServiceName "sspl")
          $(mkStaticClosure 'ssplProcess)
          ($(mkStatic 'someConfigDict)
              `staticApply` $(mkStatic 'configDictSSPLConf))

  |] ]
