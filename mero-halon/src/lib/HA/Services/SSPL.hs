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
  ) where

import HA.NodeAgent.Messages
import HA.EventQueue.Producer (promulgate)
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
  , catchExit
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
  )
import Control.Distributed.Process.Closure
import Control.Distributed.Static
  ( staticApply )
import Control.Monad.State.Strict hiding (mapM_)

import Data.Aeson (decode, encode, toJSON)

import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Defaultable
import Data.Foldable (mapM_)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

import Network.AMQP

import Prelude hiding (id, mapM_)

-- | Internal 'listen' handler. This is needed because AMQP runs in the
--   IO monad, so we cannot directly handle messages using `Process` actions.
msgHandler :: Network.AMQP.Message
           -> Process ()
msgHandler msg = do
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
    iemProcess Rabbit.BindConf{..} rp = forever $ do
      InterestingEventMessage foo <- receiveChan rp
      liftIO $ publishMsg
        chan
        (T.pack . fromDefault $ bcExchangeName)
        (T.pack . fromDefault $ bcRoutingKey)
        (newMsg { msgBody = foo
                , msgDeliveryMode = Just Persistent
                }
        )
    systemdProcess Rabbit.BindConf{..} rp = forever $ do
      SystemdRequest srv cmd <- receiveChan rp
      let msg = encode $ ActuatorRequest {
          actuatorRequestSspl_ll_debug = Nothing
        , actuatorRequestActuator_request_type = ActuatorRequestActuator_request_type {
            actuatorRequestActuator_request_typeSystemd_service = Just
              ActuatorRequestActuator_request_typeSystemd_service {
                actuatorRequestActuator_request_typeSystemd_serviceSystemd_request =
                  T.decodeUtf8 . BL.toStrict $ cmd
              , actuatorRequestActuator_request_typeSystemd_serviceService_name =
                  T.decodeUtf8 . BL.toStrict $ srv
              }
          , actuatorRequestActuator_request_typeThread_controller = Nothing
          , actuatorRequestActuator_request_typeLogging = Nothing
          }
        , actuatorRequestSspl_ll_msg_header = toJSON (Nothing :: Maybe ())
        }
      liftIO $ publishMsg
        chan
        (T.pack . fromDefault $ bcExchangeName)
        (T.pack . fromDefault $ bcRoutingKey)
        (newMsg { msgBody = msg
                , msgDeliveryMode = Just Persistent
                }
        )

remotableDecl [ [d|

  ssplProcess :: SSPLConf -> Process ()
  ssplProcess (SSPLConf{..}) = let

    onExit _ Shutdown = say $ "SSPLService stopped."
    onExit _ Reconfigure = say $ "SSPLService stopping for reconfiguration."

    connectRetry lock = do
      me <- getSelfPid
      pid <- spawnLocal $ connectSSPL lock me
      mref <- monitor pid
      receiveWait [
          match $ \(ProcessMonitorNotification _ _ _) -> connectRetry lock
        , match $ \() -> unmonitor mref >> (liftIO $ putMVar lock ())
        ]
    connectSSPL lock pid = do
      conn <- liftIO $ Rabbit.openConnection scConnectionConf
      chan <- liftIO $ openChannel conn
      startSensors chan scSensorConf
      startActuators chan scActuatorConf pid
      () <- liftIO $ takeMVar lock
      liftIO $ closeConnection conn
      say "Connection closed."
    in (`catchExit` onExit) $ do
      say $ "Starting service sspl"
      lock <- liftIO newEmptyMVar
      connectRetry lock

  sspl :: Service SSPLConf
  sspl = Service
          (ServiceName "sspl")
          $(mkStaticClosure 'ssplProcess)
          ($(mkStatic 'someConfigDict)
              `staticApply` $(mkStatic 'configDictSSPLConf))

  |] ]
