-- |
-- Copyright: (C) 2014 Tweag I/O Limited
-- 
-- Brokers are responsible for telling existing publishers about new
-- subscribers and also telling new publishers about existing publishers.
-- 
-- The centralized broker is a single process that keeps track of
-- publishers and subscribers in its local state.
-- 

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell    #-}

module Network.CEP.Broker.Centralized (broker) where

import           Network.CEP.Types
import           Network.CEP.Util

import           Control.Distributed.Process
  (ProcessId, Process, send, match, receiveWait)
import           Control.Lens
import qualified Data.MultiMap as MultiMap

import           Control.Monad (forM_, when)
import           Data.Typeable (Typeable)


-- | The internal state of the broker.
data BrokerMapping = BrokerMapping
  { _publishers  :: !(MultiMap.MultiMap EventType ProcessId)
  , _subscribers :: !(MultiMap.MultiMap EventType ProcessId)
  } deriving Typeable

$(makeLenses ''BrokerMapping)

-- TODO broker needs to support fail-over (i.e. know about other brokers and
-- synchronize state changes with them).

broker :: Process ()
broker = runBroker $ BrokerMapping MultiMap.empty MultiMap.empty

-- | The centralized broker process itself.
runBroker :: BrokerMapping -> Process ()
runBroker m = receiveWait [ match $ subscribe m
                       , match $ publish   m
                       , match $ remove    m ]


-- Subscription

-- | Run a broker with a new subscriber added.
subscribe :: BrokerMapping -> NetworkMessage SubscribeRequest -> Process ()
subscribe m msg = do
    notifySubscribe m msg
    runBroker $ addSubscriber (msg ^. payload . eventType) (msg ^. source) m

-- | Tell all the relevant publishers about a new subscription request.
notifySubscribe :: BrokerMapping
                -> NetworkMessage SubscribeRequest
                -> Process ()
notifySubscribe m msg = mapM_ (flip send msg) $
    MultiMap.lookup (msg ^. payload . eventType) (m ^. publishers)

-- | Update the broker state with a new subscriber.
addSubscriber :: EventType     -- ^ The type of the event in which the
                               --   subscriber is interested.
              -> ProcessId     -- ^ The subscriber's 'ProcessId'.
              -> BrokerMapping -- ^ The original state.
              -> BrokerMapping
addSubscriber t s = subscribers %~ MultiMap.insert t s


-- Publishing

-- | Run a broker with a new publisher added.
publish :: BrokerMapping -> NetworkMessage PublishRequest -> Process ()
publish m (NetworkMessage (PublishRequest t) p) = do
    notifyPublish t p m
    runBroker $ addPublisher t p m

-- | Tell a new publisher about all relevant subscribers.
notifyPublish :: EventType -> ProcessId -> BrokerMapping -> Process ()
notifyPublish t p m = mapM_ (send p . NetworkMessage (SubscribeRequest t)) $
    MultiMap.lookup t $ m ^. subscribers

-- | Update the broker state with a new publisher.
addPublisher :: EventType     -- ^ The type of event that will be published.
             -> ProcessId     -- ^ The 'ProcessId' of the new publisher.
             -> BrokerMapping -- ^ The original state.
             -> BrokerMapping
addPublisher t s = publishers %~ MultiMap.insert t s


-- Removal

-- | Run a broker with a node removed.
remove :: BrokerMapping -> NetworkMessage NodeRemoval -> Process ()
remove m msg@(NetworkMessage (NodeRemoval p) _) = do
    notifyRemove msg m
    runBroker $ removeNode p m

notifyRemove :: NetworkMessage NodeRemoval -> BrokerMapping -> Process ()
notifyRemove msg@(NetworkMessage (NodeRemoval p) _) m = do
    forM_ (joinOnKey (m ^. publishers) (m ^. subscribers)) $ \(pubs, subs) -> do
      when (elem p pubs) $ mapM_ (flip send msg) subs
      when (elem p subs) $ mapM_ (flip send msg) pubs

removeNode :: ProcessId -> BrokerMapping -> BrokerMapping
removeNode p (BrokerMapping ps ss)
  = BrokerMapping (deleteValue p ps) (deleteValue p ss)
