-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Please import this qualified.

{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module HA.Services.SSPL.Rabbit where

import Prelude hiding ((<$>), (<*>))
import Control.Applicative ((<$>), (<*>))
import Control.Concurrent.Chan
import Control.Distributed.Process
  ( Process
  , getSelfPid
  , liftIO
  , link
  , spawnLocal
  )
import Control.Monad (forever)

import Data.Binary (Binary)
import Data.Defaultable
import Data.Hashable (Hashable)
import Data.Monoid ((<>))
import qualified Data.Text as T
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Network.AMQP

import Options.Schema (Schema)
import Options.Schema.Builder hiding (name, desc)

--------------------------------------------------------------------------------
-- Configuration                                                              --
--------------------------------------------------------------------------------

-- | Configuration to connect to RabbitMQ
data ConnectionConf = ConnectionConf {
    ccHostname :: Defaultable String
  , ccVirtualHost :: Defaultable String
  , ccLoginName :: String
  , ccPassword :: String
  } deriving (Eq, Generic, Show, Typeable)

instance Binary ConnectionConf
instance Hashable ConnectionConf

-- | Configuration to bind an exchange to a queue. This is slightly weird - on
--   receipt side, we care only about the queue, and on the send side we care
--   only about the exchange. We record all of this stuff because we might have
--   to be the side carrying out the binding in either case.
data BindConf = BindConf {
    bcExchangeName :: Defaultable String
  , bcRoutingKey :: Defaultable String
  , bcQueueName :: Defaultable String
  } deriving (Eq, Generic, Show, Typeable)

instance Binary BindConf
instance Hashable BindConf

--------------------------------------------------------------------------------
-- Schemata                                                                   --
--------------------------------------------------------------------------------

connectionSchema :: Schema ConnectionConf
connectionSchema = let
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
  in ConnectionConf <$> hn <*> vh <*> un <*> pw

--------------------------------------------------------------------------------
-- Functionality                                                              --
--------------------------------------------------------------------------------

-- | openConnection operating directly over a `ConnectionConf`.
openConnection :: ConnectionConf
               -> IO Network.AMQP.Connection
openConnection ConnectionConf{..} =
    Network.AMQP.openConnection host vhost un pw
  where
    host = fromDefault $ ccHostname
    vhost = T.pack . fromDefault $ ccVirtualHost
    un = T.pack ccLoginName
    pw = T.pack ccPassword

-- | Distributed-process variant of 'consumeMsgs'
receive :: Network.AMQP.Channel
        -> BindConf
        -> (Network.AMQP.Message -> Process ())
        -> Process ()
receive chan BindConf{..} handle = do
    me <- getSelfPid
    lChan <- liftIO newChan
    hpid <- spawnLocal $ handler me lChan
    link hpid
    rabbitHandler lChan
  where
    handler me lChan = link me >> (forever $ do
      (msg, env) <- liftIO $ readChan lChan
      handle msg
      liftIO $ ackEnv env
      )

    rabbitHandler lChan = liftIO $ do
      declareExchange chan newExchange
        { exchangeName = exchangeName
        , exchangeType = "topic"
        , exchangeDurable = False
        }
      _ <- declareQueue chan newQueue { queueName = queueName }
      bindQueue chan queueName exchangeName routingKey

      _ <- consumeMsgs chan queueName Ack $ \a -> do
        writeChan lChan a
      return ()

    exchangeName = T.pack . fromDefault $ bcExchangeName
    queueName = T.pack . fromDefault $ bcQueueName
    routingKey = T.pack . fromDefault $ bcRoutingKey

