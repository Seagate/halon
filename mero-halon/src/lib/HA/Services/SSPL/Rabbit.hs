-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Please import this qualified.

{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}

module HA.Services.SSPL.Rabbit where

import Prelude hiding ((<$>), (<*>))
import Control.Applicative ((<$>), (<*>))
import Control.Concurrent.Chan
import Control.Concurrent.MVar
import Control.Distributed.Process
  ( Process
  , ProcessId
  , getSelfPid
  , liftIO
  , link
  , spawnLocal
  , finally
  , bracket
  , sendChan
  , receiveWait
  , match
  , matchChan
  , usend
  )
import qualified Control.Distributed.Process as DP
import Control.Monad (forever)

import Data.Maybe
import Data.Binary (Binary)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as LBS
import Data.Defaultable
import Data.Hashable (Hashable)
import Data.Monoid ((<>))
import Data.Foldable
import qualified Data.Set as Set
import qualified Data.Map as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
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
    tag <- rabbitHandler lChan
    hpid <- spawnLocal $ finally
              (link me >> handler lChan)
              (liftIO $ cancelConsumer chan tag)
    link hpid
  where
    handler lChan = forever $ do
      (msg, _env) <- liftIO $ readChan lChan
      handle msg

    rabbitHandler lChan = liftIO $ do
      declareExchange chan newExchange
        { exchangeName = exchangeName
        , exchangeType = "topic"
        , exchangeDurable = False
        }
      _ <- declareQueue chan newQueue { queueName = queueName }
      bindQueue chan queueName exchangeName routingKey

      consumeMsgs chan queueName NoAck $ writeChan lChan

    exchangeName = T.pack . fromDefault $ bcExchangeName
    queueName = T.pack . fromDefault $ bcQueueName
    routingKey = T.pack . fromDefault $ bcRoutingKey

receiveAck :: Network.AMQP.Channel
           -> T.Text -- ^ Exchange
           -> T.Text -- ^ Queue
           -> T.Text -- ^ Routing key
           -> (Network.AMQP.Message -> Process ())
           -> Process ()
receiveAck chan exchange queue routingKey handle = bracket
  (liftIO $ do
     declareExchange chan newExchange
       { exchangeName = exchange
       , exchangeType = "topic"
       , exchangeDurable = False
       }
     _  <- declareQueue chan newQueue{ queueName = queue }
     bindQueue chan queue exchange routingKey
     mbox  <- newEmptyMVar
     mdone <- newEmptyMVar
     tag   <- consumeMsgs chan queue Ack $ \(msg,env) -> do
       putMVar mbox msg
       takeMVar mdone
       ackEnv env
     return (tag,(mbox,mdone)))
  (liftIO . cancelConsumer chan . fst)
  (\(_,(mbox,mdone)) -> forever $ do
     handle =<< liftIO (takeMVar mbox)
     liftIO $ putMVar mdone ())

-- | Publish message
data MQPublish = MQPublish
       { publishExchange :: ByteString
       , publishKey      :: ByteString
       , publishBody     :: ByteString
       } deriving (Generic)

instance Binary MQPublish

-- | Subscribe to the queue
data MQSubscribe = MQSubscribe
      { subQueue   :: ByteString
      , subProcess :: ProcessId
      } deriving (Generic)

instance Binary MQSubscribe

data MQMessage = MQMessage
      { mqQueue :: ByteString
      , mqMessage :: ByteString
      } deriving (Generic)

instance Binary MQMessage

data MQBind = MQBind
      { mqBindExchange :: ByteString
      , mqBindQueue    :: ByteString
      , mqBindKey      :: ByteString
      } deriving (Generic)

instance Binary MQBind

-- | Creates Mock RabbitMQ Proxy.
rabbitMQProxy :: ConnectionConf -> Process ()
rabbitMQProxy conf = run
  where
    run = bracket (liftIO $ HA.Services.SSPL.Rabbit.openConnection conf)
                  (liftIO . closeConnection) $ \connection ->
            bracket (liftIO $ openChannel connection)
                    (liftIO . closeChannel) go
    go chan = do
      tags <- liftIO $ newMVar []
      self <- getSelfPid
      iochan <- liftIO newChan
      (sendPort, receivePort) <- DP.newChan
      _ <- spawnLocal $ do
        link self
        forever $ sendChan sendPort =<< liftIO (readChan iochan)
      let exchangesIfMissing exchanges name
            | Set.notMember name exchanges = do
                liftIO $ declareExchange chan newExchange
                           { exchangeName = name
                           , exchangeType = "topic"
                           , exchangeDurable = False
                           }
                return (Set.insert name exchanges)
            | otherwise = return exchanges
          queuesIfMissing queues name
            | Set.notMember name queues = do
                _ <- liftIO $ declareQueue chan newQueue{queueName = name}
                return (Set.insert name queues)
            | otherwise = return queues
          loop queues subscribers exchanges = receiveWait
            [ match $ \(MQSubscribe k@(T.decodeUtf8 -> key) pid) -> do
                queues' <- queuesIfMissing queues key
                tag <- liftIO $ consumeMsgs chan key NoAck $ \(msg, _env) -> do
                   writeChan iochan (T.encodeUtf8 key, msgBody msg)
                liftIO $ modifyMVar_ tags (return .(tag:))
                let subscribers' = Map.insertWith (<>) k [pid] subscribers
                loop queues' subscribers' exchanges
            , match $ \(MQBind (T.decodeUtf8 -> exch) (T.decodeUtf8 -> que) (T.decodeUtf8 -> key)) -> do
                exchanges' <- exchangesIfMissing exchanges exch
                queues'    <- queuesIfMissing queues que
                liftIO $ bindQueue chan que exch key
                loop queues' subscribers exchanges'
            , match $ \(MQPublish (T.decodeUtf8 -> exch) (T.decodeUtf8 -> key) (LBS.fromStrict -> msg)) -> do
                exchanges' <- exchangesIfMissing exchanges exch
                liftIO $ publishMsg chan exch key newMsg{msgBody = msg}
                loop queues subscribers exchanges'
            , matchChan receivePort $ \(key, msg) -> do
                let msg' = LBS.toStrict msg
                for_ (fromMaybe [] $ Map.lookup key subscribers) $ \p ->
                  usend p $ MQMessage key msg'
                loop queues subscribers exchanges
            ]
      (loop Set.empty Map.empty Set.empty)
          `DP.finally` (liftIO $ takeMVar tags >>= mapM (cancelConsumer chan))
