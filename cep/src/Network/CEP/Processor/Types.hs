-- |
-- Copyright: (C) 2014 Tweag I/O Limited
-- 
-- Types used for writing CEP processors.
-- 

{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TemplateHaskell            #-}

module Network.CEP.Processor.Types where

import Network.CEP.Types

import Control.Distributed.Process (Process, ProcessId, Message)
import Control.Lens
import Data.MultiMap (MultiMap)

import Control.Applicative (Applicative)
import Control.Concurrent (Chan)
import Control.Monad.State (StateT, MonadIO, MonadState, lift)
import Data.Typeable (Typeable)

type Handler s = Message -> Processor s ()

-- | Process monad.  The session variable s guarantees that actions
--   cannot be executed outside the expected session (although
--   unfortunately actions can be *sent* to be executed using
--   'Network.CEP.Processor.actionRunner'; this is sadly necessary to
--   be able to round-trip through IO callbacks).
newtype Processor s a = Processor
  { unProcessor :: StateT (ProcessorState s) Process a
  } deriving (Typeable, Monad, Functor, Applicative, MonadIO,
              MonadState (ProcessorState s))

-- | Initial configuration for a CEP processor.
newtype Config = Config
  { _brokers :: [Broker]
  } deriving (Typeable)

-- | Type of internal CEP state.
data ProcessorState s = ProcessorState
  { _currentBrokers :: ![Broker]
  , _subscribers    :: !(MultiMap EventType ProcessId)
  , _handlers       :: ![Handler s]
  , _actionQueue    :: !(Chan (Processor s Bool))
  , _listener       :: !ProcessId
  , _cleanup        :: !(Processor s ())
  }

makeClassy ''Config
makeClassy ''ProcessorState

liftProcess :: Process a -> Processor s a
liftProcess = Processor . lift
