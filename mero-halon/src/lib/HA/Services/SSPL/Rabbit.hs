{-# LANGUAGE ImplicitParams    #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData        #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE ViewPatterns      #-}
-- |
-- Module    : HA.Services.SSPL.Rabbit
-- Copyright : (C) 2015-2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Service interacting with @rabbitmq@. Please import this qualified.
module HA.Services.SSPL.Rabbit where

import Control.Applicative ((<$))
import Control.Concurrent (forkIO)
import Control.Concurrent.Chan
import Control.Concurrent.MVar
import Control.Concurrent.STM
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
import Control.Monad (forever, void, when)
import Control.Monad.Catch
  ( finally
  , bracket
  , mask_
  , try
  , SomeException(..)
  )
import Data.Function (fix)
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

-- | Desired state of consumer/producer processes. When a worker
-- process dies, it should either restart when in 'Running' or stay
-- dead (and mark 'Dead').
data DesiredWorkerState = Running | Dying | Dead
  deriving (Show, Eq, Ord, Generic, Typeable)

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

-- | Repeatedly attempt to connect to a RabbitMQ process.
openConnectionRetry :: ConnectionConf -- ^ Connection configuration
                    -> Int -- ^ Number of attempts to make
                    -> Int -- ^ Time between attempts (µs)
                    -> Process (Either SomeException Network.AMQP.Connection)
openConnectionRetry conf attempts sleep =
  flip fix (attempts :: Int) $ \tryAgain n -> case n of
    _ | n <= 0 -> error "Rabbit.openConnectionRetry underflow"
      | n == 1 -> try (liftIO $ HA.Services.SSPL.Rabbit.openConnection conf)
      | otherwise -> try (liftIO $ HA.Services.SSPL.Rabbit.openConnection conf) >>= \case
          Right x -> return $! Right x
          Left (_ :: SomeException) -> do
            _ <- DP.receiveTimeout sleep []
            tryAgain $! n - 1

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
    declareQueue chan newQueue { queueName = queueName, queueDurable = False }
  ignoreException $ bindQueue chan queueName exchangeName routingKey
  where
    exchangeName = T.pack $ fromDefault bcExchangeName
    queueName = T.pack $ fromDefault bcQueueName
    routingKey = T.pack $ fromDefault bcRoutingKey

-- | Read the given channel until we're signalled to stop. If process
-- dies without being signalled, it's restarted.
--
-- Channel-biased.
consumeChanOrDieBracket :: TChan a
                        -> TVar DesiredWorkerState -- ^ Keep running?
                        -> Process b -- ^ Init
                        -> (b -> Process ()) -- ^ Teardown
                        -> (a -> Process c) -- ^ Act
                        -> Process ()
consumeChanOrDieBracket stmChan wstate init' teardown' act = do
  self <- getSelfPid

  -- Do work until signalled to die.
  let spawnWorker spawner = spawnLocal . bracket init' teardown' $ \_ -> do
        link self
        link spawner
        fix $ \go -> do
          r <- liftIO . atomically $
            (Just <$> readTChan stmChan) `orElse` (Nothing <$ terminate)
          for_ r $ \v -> void (act v) >> go

  -- Spawn the worker process and wait until it dies. When it dies,
  -- restart it if it wasn't supposed to die. If it was supposed to
  -- die, mark it as dead and quit.
  void . spawnLocal . bracket (return ()) (\() -> markDead) $ \() -> do
    link self
    respawner <- getSelfPid
    fix $ \restartWorker -> do
      workerPid <- spawnWorker respawner
      mref <- DP.monitor workerPid
      receiveWait
        [ DP.matchIf (\(DP.ProcessMonitorNotification m _ _ ) -> m == mref)
                     (\_ -> liftIO (atomically $ readTVar wstate) >>= \case
                         Running -> restartWorker
                         _ -> return ())
        ]
  where
    terminate = readTVar wstate >>= check . (/= Running)
    markDead = liftIO . atomically $ writeTVar wstate Dead

-- | 'consumeChanOrDieBracket' without init/teardown.
consumeChanOrDie :: TChan a
                 -> TVar DesiredWorkerState
                 -> (a -> Process c)
                 -> Process ()
consumeChanOrDie stmChan keepRunning act =
  consumeChanOrDieBracket stmChan keepRunning (return ()) (\() -> return ()) act

receive :: (?loc :: CallStack)
           => Network.AMQP.Channel
           -> T.Text -- ^ Queue
           -> TVar DesiredWorkerState -- ^ Keep running?
           -> Ack -- ^ Ack messages?
           -> (Network.AMQP.Message -> Process ())
           -> Process ()
receive chan queue keepRunning doAck handle = do
  c <- liftIO newTChanIO
  _ <- consumeChanOrDieBracket c keepRunning (initRmq c) teardown $ \(msg, env) -> do
    handle msg
    liftIO . when (doAck == Ack) $ ackEnv env
  return ()
  where
    initRmq lChan = liftIO $ do
      mask_ . ignoreException . void $
        declareQueue chan newQueue{ queueName = queue, queueDurable = False  }
      tag <- consumeMsgs chan queue doAck $
        atomically . writeTChan lChan
      return tag

    teardown tag = liftIO $ cancelConsumer chan tag

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
                _ <- liftIO $ declareQueue chan newQueue
                  { queueName = name, queueDurable = False }
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
