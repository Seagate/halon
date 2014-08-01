-- |
-- Copyright: (C) 2014 Tweag I/O Limited
-- 
-- A Sodium interface to CEP.
-- 

module Network.CEP.Processor.Sodium
  ( module Network.CEP.Types
  , Processor
  , P.runProcessor
  , P.Config (..)
  , liftReactive
  , P.liftProcess
  , P.getProcessorPid
  , publish
  , subscribe
  , dieOn ) where


import           Network.CEP.Types
import           Network.CEP.Processor (Processor, actionRunner, onExit)
import qualified Network.CEP.Processor as P
import qualified Network.CEP.Processor.Callback as CB

import           Control.Distributed.Process.Serializable (Serializable)
import           FRP.Sodium

import           Control.Applicative ((<$))
import           Control.Monad.State (liftIO, void)

-- | Lift a 'Reactive' action into the 'Processor' monad.
-- This is just a shortcut for `liftIO . sync`.
liftReactive :: Reactive a -> Processor s a
liftReactive = liftIO . sync

-- | Advertise with the broker as providing a source of an event of a
-- certain type.  All firings of the provided event will be forwarded
-- to interested subscribers.
publish :: Serializable a => Event a -> Processor s ()
publish ev = do
    h <- CB.publish
    r <- actionRunner
    (>>= onExit . liftIO) . liftReactive . listen ev $ r . (True <$) . h

-- | Request that the broker direct any providers of an event of a
-- certain type to notify this node.  Occurrences of the event on
-- those providers will then be forwarded to this node, causing the
-- returned Sodium 'Event' to fire.
subscribe :: Serializable a => Processor s (Event (NetworkMessage a))
subscribe = do
    (ev, push) <- liftReactive newEvent
    CB.subscribe $ liftReactive . push
    return ev

-- | Kill the process on the first occurrence of an event.
dieOn :: Event a -> Processor s ()
dieOn ev = do
    r <- actionRunner
    void . liftReactive . listen ev . const . r $ return False
