{-# LANGUAGE ImplicitParams    #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData        #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE ViewPatterns      #-}
-- |
-- Module    : HA.Services.SSPL.Rabbit
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Service interacting with @rabbitmq@. Please import this qualified.
module HA.Services.SSPL.Rabbit where

import Prelude hiding ((<$>), (<*>))
import Control.Applicative ((<$>), (<*>))
import Control.Concurrent (forkIO)
import Control.Concurrent.Chan
import Control.Concurrent.MVar
import Control.Distributed.Process
  ( Process
  , ProcessId
  , getSelfPid
  , liftIO
  , link
  , spawnLocal
  , sendChan
  , receiveWait
  , match
  , matchChan
  , usend
  )
import qualified Control.Distributed.Process as DP
import Control.Monad (forever, void)
import Control.Monad.Catch
  ( finally
  , bracket
  , mask_
  , try
  , catch
  , SomeException(..)
  )

import Data.Maybe
import Data.Binary (Binary)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as LBS
import Data.Defaultable
import Data.Hashable (Hashable)
import Data.Monoid
import Data.Foldable
import qualified Data.Set as Set
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import GHC.Stack
import HA.Aeson
import HA.SafeCopy

import Network.AMQP

import Options.Schema (Schema)
import Options.Schema.Builder hiding (name, desc)
import Text.Printf (printf)

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

instance Hashable ConnectionConf
instance ToJSON ConnectionConf where
  toJSON (ConnectionConf hn vh login pass) =
    object [ "hostname" .= fromDefault hn
           , "virtual_host" .= fromDefault vh
           , "username" .= login
           , "password" .= pass
           ]
deriveSafeCopy 0 'base ''ConnectionConf

-- | Configuration to bind an exchange to a queue. This is slightly weird - on
--   receipt side, we care only about the queue, and on the send side we care
--   only about the exchange. We record all of this stuff because we might have
--   to be the side carrying out the binding in either case.
data BindConf = BindConf {
    bcExchangeName :: Defaultable String
  , bcRoutingKey :: Defaultable String
  , bcQueueName :: Defaultable String
  } deriving (Eq, Generic, Show, Typeable)

instance Hashable BindConf
instance ToJSON BindConf where
  toJSON (BindConf ex rk qn) =
    object [ "exchange_name" .= fromDefault ex
           , "routing_key" .= fromDefault rk
           , "queue_name" .= fromDefault qn
           ]
deriveSafeCopy 0 'base ''BindConf

--------------------------------------------------------------------------------
-- Schemata                                                                   --
--------------------------------------------------------------------------------

-- | Schema for rabbitmq connection settings.
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

-- | Create a @topic@ exchange, queue and bind the two together with
-- the given routing key. This should be ran before trying to send a
-- message through the exchange.
setupBind :: Network.AMQP.Channel
          -> BindConf -- ^ Exchange, queue and key information to use.
          -> IO ()
setupBind chan BindConf{..} = mask_ $ do
  ignoreException $ declareExchange chan newExchange
    { exchangeName = exchangeName
    , exchangeType = "topic"
    , exchangeDurable = False
    }
  ignoreException $ void $
    declareQueue chan newQueue { queueName = queueName }
  ignoreException $ bindQueue chan queueName exchangeName routingKey
  where
    exchangeName = T.pack $ fromDefault bcExchangeName
    queueName = T.pack $ fromDefault bcQueueName
    routingKey = T.pack $ fromDefault bcRoutingKey

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
      mask_ . ignoreException . void $
        declareQueue chan newQueue { queueName = queueName }
      consumeMsgs chan queueName NoAck $ writeChan lChan
    queueName = T.pack . fromDefault $ bcQueueName


receiveAck :: (?loc :: CallStack)
           => Network.AMQP.Channel
           -> T.Text -- ^ Queue
           -> (Network.AMQP.Message -> Process ())
           -> Process ()
receiveAck chan queue handle = go `catch` (liftIO . logException ?loc) where
  go = bracket
         (liftIO $ do
            mask_ . ignoreException . void $
              declareQueue chan newQueue{ queueName = queue }
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

ignoreException :: (?loc :: CallStack) => IO () -> IO ()
ignoreException io = try io >>= \case
  Right _ -> return ()
  Left e  -> logException ?loc e

-- | Output 'SomeException' with SSPL-HL service header.
logException :: CallStack -> SomeException -> IO ()
logException cs e =
  putStrLn $ printf "[SSPL-HL]: exception %s (%s)" (show e) locInfo
  where
    locInfo = case reverse $ getCallStack cs of
      (_, loc) : _ -> prettySrcLoc loc
      _ -> "no loc"


-- | Publish message
data MQPublish = MQPublish
       { publishExchange :: !T.Text
       , publishKey      :: !T.Text
       , publishBody     :: !ByteString
       } deriving (Generic)

instance Binary MQPublish

-- | Subscribe to the queue
data MQSubscribe = MQSubscribe
      { subQueue   :: !T.Text
      , subProcess :: !ProcessId
      } deriving (Generic)
instance Binary MQSubscribe

data MQMessage = MQMessage
      { mqQueue :: !T.Text
      , mqMessage :: !ByteString
      } deriving (Generic)
instance Binary MQMessage

data MQBind = MQBind
      { mqBindExchange :: !T.Text
      , mqBindQueue    :: !T.Text
      , mqBindKey      :: !T.Text
      } deriving (Generic)
instance Binary MQBind

data MQPurge = MQPurge
  { mqPurgeQueueName :: !T.Text
  , mqPurgeCaller :: !ProcessId
  } deriving (Eq, Generic)
instance Binary MQPurge

-- | Ask RMQ proxy to forward messages from a key to another queue.
--
-- Note that this will result in 'MQMessage's from '_mqForwardToQueue'
-- even if '_mqForwardToExchange' with '_mqForwardToKey' decided not
-- to publish into '_mqForwardToQueue'. You should therefore only use
-- this for exchanges and keys that you *know* will always forward the
-- message (such as @direct@ or @topic@ without @*/#@) otherwise you
-- will see 'MQMessage's for things that haven't actually gone into
-- '_mqForwardToQueue'.
--
-- It is up to the user to ensure that '_mqForwardToExchange' and
-- '_mqForwardToQueue' have been declared and bound through
-- '_mqForwardToKey'.
--
-- You should not 'MQSubscribe' to '_mqForwardToQueue' if you're
-- forwarding out of it: you will register two consumers (forwarder
-- and subscriber). Instead, only 'MQForward' and pass in
-- '_mqMiddleman'.
data MQForward = MQForward
  { _mqForwardFromQueue :: !T.Text
  , _mqForwardToExchange :: !T.Text
  , _mqForwardToQueue :: !T.Text
  , _mqForwardToKey :: !T.Text
    -- | The process that should receive 'MQMessage's for
    -- '_mqForwardToQueue' as if it was listening to it directly. See
    -- 'MQForward' comment.
  , _mqMiddleman :: !ProcessId
  } deriving (Eq, Generic)
instance Binary MQForward

-- | Local state used by 'rabbitMQProxy
data ProxyState = ProxyState
 { exchanges :: !(Set.Set T.Text)
 , queues :: !(Set.Set T.Text)
 , subscribers :: !(Map.Map T.Text (Set.Set ProcessId))
 } deriving (Show, Eq)

instance Monoid ProxyState where
  mempty = ProxyState mempty mempty mempty
  ProxyState e q s `mappend` ProxyState e' q' s' =
    ProxyState (e <> e') (q <> q') (s <> s')

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
          loop state = receiveWait
            [ match $ \msg@(MQPurge queue p) -> do
                queues' <- queuesIfMissing (queues state) queue
                liftIO . void $ purgeQueue chan queue
                usend p msg
                loop $! state { queues = queues' }
            , match $ \(MQSubscribe queue pid) -> do
                queues' <- queuesIfMissing (queues state) queue
                tag <- liftIO $ consumeMsgs chan queue NoAck $ \(msg, _env) ->
                   writeChan iochan (queue, LBS.toStrict $ msgBody msg)
                liftIO $ modifyMVar_ tags (return .(tag:))
                let subscribers' = Map.insertWith (<>) queue (Set.singleton pid) (subscribers state)
                loop $! state { queues = queues', subscribers = subscribers' }
              -- Forwarding from @queue@ also subscribes to messages
              -- for @fqueue@.
            , match $ \(MQForward queue fexchange fqueue fkey pid) -> do
                queues' <- queuesIfMissing (queues state) queue
                let subscribers' = Map.insertWith (<>) fqueue (Set.singleton pid)
                                                              (subscribers state)
                tag <- liftIO $ consumeMsgs chan queue NoAck $ \(msg, _) -> do
                  -- Fork because consumeMsgs warnings sound scary.
                  void . forkIO $ do
                    -- Requires fexchange and fqueue are already bound.
                    _ <- publishMsg chan fexchange fkey msg
                    writeChan iochan (fqueue, LBS.toStrict $ msgBody msg)
                liftIO $ modifyMVar_ tags (return . (tag:))
                loop $! state { queues = queues', subscribers = subscribers' }
            , match $ \(MQBind exch queue key) -> do
                exchanges' <- exchangesIfMissing (exchanges state) exch
                queues'    <- queuesIfMissing (queues state) queue
                liftIO $ bindQueue chan queue exch key
                loop $! state { queues = queues', exchanges = exchanges' }
            , match $ \(MQPublish exch key (LBS.fromStrict -> msg)) -> do
                exchanges' <- exchangesIfMissing (exchanges state) exch
                _ <- liftIO $ publishMsg chan exch key newMsg{msgBody = msg}
                loop $! state { exchanges = exchanges' }
            , matchChan receivePort $ \(queue, msg) -> do
                for_ (fromMaybe mempty $ Map.lookup queue (subscribers state)) $ \p ->
                  usend p $ MQMessage queue msg
                loop state
            ]
      loop mempty
        `finally` (liftIO $ takeMVar tags >>= mapM (cancelConsumer chan))
