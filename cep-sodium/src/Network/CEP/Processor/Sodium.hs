-- |
-- Copyright: (C) 2014 Tweag I/O Limited
--
-- A Sodium interface to CEP.
--

{-# LANGUAGE FlexibleContexts #-}

module Network.CEP.Processor.Sodium
  ( module Network.CEP.Types
  , Processor
  , runProcessor
  , Config (..)
  , liftReactive
  , liftProcess
  , getProcessorPid
  , publish
  , publishAck
  , subscribe
  , listenProcessor
  , dieOn ) where

import           Network.CEP.Types
import           Network.CEP.Processor
import qualified Network.CEP as Callback

import           Control.Distributed.Process.Serializable (Serializable)
import           FRP.Sodium

import           Control.Applicative ((<$))
import           Control.Monad.State (liftIO, void)

-- | Lift a 'Reactive' action into the 'Processor' monad.
-- This is just a shortcut for `liftIO . sync`.
liftReactive :: Reactive a -> Processor s a
liftReactive = liftIO . sync

publish' :: Serializable a => Event a -> (a -> Processor s ()) -> Processor s ()
publish' ev h = do
    r <- actionRunner
    (>>= onExit . liftIO) . liftReactive . listen ev $ r . (True <$) . h

-- | Advertise with the broker as providing a source of an event of a
-- certain type.  All firings of the provided event will be forwarded
-- to interested subscribers.
publish :: Statically Emittable a => Event a -> Processor s ()
publish ev = Callback.publish >>= publish' ev

-- | Publish, but request an acknowledgement response.
publishAck :: Statically Emittable a => Event a -> Processor s (Event (Ack a))
publishAck ev = do
    (ackEv, pushAck) <- liftReactive newEvent
    Callback.publishAck (liftReactive . pushAck) >>= publish' ev
    return ackEv

-- | Request that the broker direct any providers of an event of a
-- certain type to notify this node.  Occurrences of the event on
-- those providers will then be forwarded to this node, causing the
-- returned Sodium 'Event' to fire.
subscribe :: Statically Emittable a => Processor s (Event (NetworkMessage a))
subscribe = do
    (ev, push) <- liftReactive newEvent
    Callback.subscribe $ liftReactive . push
    return ev

-- | As 'listen', but executing a `Processor s Bool` action.
listenProcessor :: Event a -> (a -> Processor s Bool) -> Processor s ()
listenProcessor ev act = do
  r <- actionRunner
  (>>= onExit . liftIO) . liftReactive . listen ev $ r . act

-- | Kill the process on the first occurrence of an event.
dieOn :: Event a -> Processor s ()
dieOn ev = do
    r <- actionRunner
    void . liftReactive . listen ev . const . r $ return False
