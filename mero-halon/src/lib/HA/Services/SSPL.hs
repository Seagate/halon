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
  , SSPLConf(..)
  , HA.Services.SSPL.__remoteTable
  , HA.Services.SSPL.__remoteTableDecl
  ) where

import HA.NodeAgent.Messages
import HA.Service hiding (configDict)
import HA.ResourceGraph
import HA.Resources (Cluster, Node)

import Control.Applicative ((<$>), (<*>))
import Control.Concurrent.Chan
import Control.Concurrent.MVar
import Control.Distributed.Process
  ( Process
  , catchExit
  , expect
  , liftIO
  , say
  , spawnLocal
  )
import Control.Distributed.Process.Closure
import Control.Distributed.Static
  ( staticApply )
import Control.Exception (catch)

import Data.Binary (Binary)
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Defaultable
import Data.Hashable (Hashable)
import Data.Monoid ((<>))
import qualified Data.Text as T
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Network.AMQP

import Options.Schema (Schema)
import Options.Schema.Builder hiding (name, desc)

import System.IO.Unsafe (unsafePerformIO)
import System.Process (readProcess)

data SSPLConf = SSPLConf {
    scHostname :: Defaultable String
  , scVirtualHost :: Defaultable String
  , scLoginName :: String
  , scPassword :: String
  , scExchangeName :: Defaultable String
  , scQueueName :: Defaultable String
  , scRoutingKey :: Defaultable String
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
    en = defaultable "sspl_bcast" . strOption
          $ long "exchange"
          <> metavar "EXCHANGE_NAME"
    qn = defaultable shortHostName . strOption
          $ long "queue"
          <> metavar "QUEUE_NAME"
          where
            shortHostName = unsafePerformIO $ readProcess "hostname" ["-s"] ""
    rk = defaultable "sspl_ll" . strOption
          $ long "routingKey"
          <> metavar "ROUTING_KEY"
  in SSPLConf <$> hn <*> vh <*> un <*> pw <*> en <*> qn <*> rk

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
resourceDictService = Dict
resourceDictServiceProcess = Dict
resourceDictConfigItem = Dict

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
relationDictSupportsClusterService = Dict
relationDictHasNodeServiceProcess = Dict
relationDictWantsServiceProcessConfigItem = Dict
relationDictHasServiceProcessConfigItem = Dict
relationDictInstanceOfServiceServiceProcess = Dict
relationDictOwnsServiceProcessServiceName = Dict

remotable
  [ 'configDict
  , 'serializableDict
  , 'resourceDictService
  , 'resourceDictServiceProcess
  , 'resourceDictConfigItem
  , 'relationDictSupportsClusterService
  , 'relationDictHasNodeServiceProcess
  , 'relationDictWantsServiceProcessConfigItem
  , 'relationDictHasServiceProcessConfigItem
  , 'relationDictInstanceOfServiceServiceProcess
  , 'relationDictOwnsServiceProcessServiceName
  ]

instance Resource (Service SSPLConf) where
  resourceDict = $(mkStatic 'resourceDictService)

instance Resource (ServiceProcess SSPLConf) where
  resourceDict = $(mkStatic 'resourceDictServiceProcess)

instance Resource SSPLConf where
  resourceDict = $(mkStatic 'resourceDictConfigItem)

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

--------------------------------------------------------------------------------
-- End Dictionaries                                                           --
--------------------------------------------------------------------------------

instance Configuration SSPLConf where
  schema = ssplSchema
  sDict = $(mkStatic 'serializableDict)

msgHandler :: Chan Network.AMQP.Message
           -> Process ()
msgHandler chan = do
  msg <- liftIO $ readChan chan
  say $ BL.unpack $ msgBody msg

remotableDecl [ [d|

  ssplProcess :: SSPLConf -> Process ()
  ssplProcess (SSPLConf{..}) = let
    host = fromDefault $ scHostname
    vhost = T.pack . fromDefault $ scVirtualHost
    exchangeName = T.pack . fromDefault $ scExchangeName
    queueName = T.pack . fromDefault $ scQueueName
    routingKey = T.pack . fromDefault $ scRoutingKey
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
      conn <- openConnection host vhost un pw
      chan <- openChannel conn

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

      () <- takeMVar lock
      closeConnection conn
      putStrLn "Connection closed."
    in (`catchExit` onExit) $ do
      say $ "Starting service sspl"
      lChan <- liftIO newChan
      lock <- liftIO newEmptyMVar
      _ <- spawnLocal $ msgHandler lChan
      _ <- spawnLocal . liftIO $ connectRetry lChan lock
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
