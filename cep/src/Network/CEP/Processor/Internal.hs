-- |
-- Copyright: (C) 2014 Tweag I/O Limited
--
-- Implementations of both basic processor functions, such as
-- runProcessor, and also the callback processor interface, which
-- depend on one another but are conceptually distinct layers.
--
-- This module is therefore not exported: its definitions are exported
-- from Network.CEP.Processor and Network.CEP.Processor.Callback, as
-- appropriate.
--

{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}

module Network.CEP.Processor.Internal where

import           Network.CEP.Processor.Types
import           Network.CEP.Types
import           Network.CEP.Util

import           Control.Distributed.Process
  hiding (Handler, say, newChan, handleMessage)
import qualified Control.Distributed.Process as Process
import qualified Control.Distributed.Process.Node as Node
import           Control.Distributed.Process.Serializable (Serializable)
import           Control.Lens
import           Control.Monad.State (gets, evalStateT)
import           Data.Binary (Binary)
import qualified Data.MultiMap as MultiMap
import           Network.Transport (Transport)

import           Control.Applicative ((<$), (<$>), liftA2)
import           Control.Concurrent (Chan, newChan, readChan, writeChan)
import           Control.Monad (join, when, void)
import           Data.Proxy (Proxy (..))
import           Data.Typeable (Typeable)

-- | Run a 'Processor' value in a new Cloud Haskell node.
runProcessor :: Transport -> Config -> (forall s. Processor s ()) -> IO ()
runProcessor trans (Config bs) m = do
    node <- Node.newLocalNode trans Node.initRemoteTable
    c    <- newChan
    Node.runProcess node $ do
      l <- spawnLocal $ runListener c
      evalStateT (unProcessor $ m >> executeActions >> executeCleanup)
        . ProcessorState bs MultiMap.empty [] c l $ return ()
    -- TODO we leak memory here, but that's because there is no way to terminate
    -- a node.  At least closeLocalNode means we don't leak file handles.
    Node.closeLocalNode node

toProcess :: Config -> Processor s () -> Process ()
toProcess (Config bs) p = do
    c <- liftIO newChan
    l <- spawnLocal $ runListener c
    evalStateT action $ init_state c l

  where
    action = unProcessor $
             p              >>
             executeActions >>
             executeCleanup

    init_state c l = ProcessorState bs MultiMap.empty [] c l $ return ()

newtype KillListener = KillListener ()
  deriving (Binary, Typeable)

-- | Run a process that listens for incoming Cloud Haskell messages.
runListener :: Chan (Processor s Bool) -> Process ()
runListener c =
    receiveWait [ match    $ return . beKilled
                , match    $ return . Just . andHandle addSubscriber
                , match    $ return . Just . andHandle removeSubscriber
                -- Brokers should be largely transparent to the
                -- processor, so we don't let processors handle broker
                -- reconfiguration events.
                , match    $ return . Just . reconfBrokers
                , matchAny $ return . Just . handleEvent ]
      >>= maybe (return ())
                ((>> runListener c) . liftIO . writeChan c . (True <$))
  where
    beKilled KillListener {} = Nothing
    andHandle f msg = f msg >> handleEvent (wrapMessage msg)

-- | Cloud Haskell's 'say' from the Processor monad.
say :: String -> Processor s ()
say = liftProcess . Process.say

-- | Return an action that will schedule an action to be executed
--   in this process.
--   Returning False from the action will cause the process to terminate.
--   Beware: if the process has ended, the action will never be
--   read or executed, potentially leaking memory.
actionRunner :: Processor s (Processor s Bool -> IO ())
actionRunner = writeChan <$> gets (^. actionQueue)

-- | Register an action to be executed when the processor finishes.
onExit :: Processor s () -> Processor s ()
onExit = (cleanup %=) . flip (>>)

-- | Get the ProcessId to which other processes may send CEP messages.
getProcessorPid :: Processor s ProcessId
getProcessorPid = gets (^. listener)

-- | Remove one action from the action queue and execute it.
executeAction :: Processor s Bool
executeAction = join $ gets (^. actionQueue) >>= liftIO . readChan

-- | Loop to execute all actions.
executeActions :: Processor s ()
executeActions = executeAction >>= flip when executeActions

-- | Execute all the actions registered for cleanup with 'onExit'.
executeCleanup :: Processor s ()
executeCleanup = do
    gets (^. listener) >>= liftProcess . flip send (KillListener ())
    join $ gets (^. cleanup)

-- | Add a new subscriber from a request.
addSubscriber :: NetworkMessage SubscribeRequest -> Processor s ()
addSubscriber (NetworkMessage (SubscribeRequest t) _ s)
  = subscribers %= MultiMap.insert t s

-- | Remove a subscriber that has died.
removeSubscriber :: NetworkMessage NodeRemoval -> Processor s ()
removeSubscriber (NetworkMessage (NodeRemoval p) _ _)
  = subscribers %= deleteValue p

-- | Update the list of brokers.
reconfBrokers :: NetworkMessage BrokerReconf -> Processor s ()
reconfBrokers (NetworkMessage (BrokerReconf bs) _ _) = currentBrokers .= bs

-- | Send an appropriately 'NetworkMessage'-wrapped message to another
--   process.
sendMessage :: Serializable a
            => Bool
            -- ^ Whether to request acknowledgement.
            -> a -> ProcessId -> Processor s ()
sendMessage ackp msg p
  = gets (^. listener) >>= liftProcess . send p . NetworkMessage msg ackp

-- | Send a (wrapped) message to all brokers.
sendBrokers :: Serializable a => a -> Processor s ()
sendBrokers msg = gets (^. currentBrokers) >>= mapM_ (sendMessage False msg)

-- | Send a (wrapped) message to everyone subscribed to messages of
--   its type.
sendSubscribers :: forall s a. Statically Emittable a
                => Bool
                -- ^ Whether to request acknowledgement.
                -> a -> Processor s ()
sendSubscribers ackp msg = gets (^. subscribers)
    >>= mapM_ (sendMessage ackp msg)
        . MultiMap.lookup (eventTypeOf (Proxy :: Proxy a))

publish' :: forall a s. Statically Emittable a
         => Bool
         -- ^ Whether or not to request acknowledgement.
         -> Processor s (a -> Processor s ())
publish' ackp = do
    sendBrokers . PublishRequest $ eventTypeOf (Proxy :: Proxy a)
    return $ sendSubscribers ackp

-- | Publish a new event.  The returned action emits the event to all
--   subscribers.
publish :: forall a s. Statically Emittable a
        => Processor s (a -> Processor s ())
publish = publish' False

-- | Publish a new event, requesting acknowledgement when it is
--   successfully handled.
publishAck :: forall a s. Statically Emittable a
           => (Ack a -> Processor s ())
           -- ^ Callback to call when acknowledgement is received.
           -> Processor s (a -> Processor s ())
publishAck handleAck = do
    handlers %= (void . flip Process.handleMessage handleAck :)
    publish' True

-- | Subscribe to a new event.
subscribe :: forall a s. Statically Emittable a
          => (NetworkMessage a -> Processor s ())
             -- ^ Callback to call on receiving a message of this type.
          -> Processor s ()
subscribe handle = do
    sendBrokers . SubscribeRequest $ eventTypeOf (Proxy :: Proxy a)
    handlers %= (void . flip Process.handleMessage
                          (liftA2 (>>) handle acknowledge) :)

acknowledge :: forall a s. Serializable a => NetworkMessage a -> Processor s ()
acknowledge m = when (m ^. ack) $
    gets (^. listener) >>= liftProcess . send (m ^. source) . Ack (m ^. payload)

-- | Call all handlers of the correct type with the value of the
--   supplied message.
handleEvent :: Message -> Processor s ()
handleEvent msg = gets (^. handlers) >>= mapM_ ($ msg)
