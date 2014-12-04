-- |
-- Copyright: (C) 2014 Tweag I/O Limited
--
-- Types and utility functions for writing a CEP processor, regardless
-- of interface.
--

module Network.CEP.Processor
       ( Processor ()
       , Config (..)
       , ProcessorState ()
       , brokers
       , runProcessor
       , actionRunner
       , liftProcess
       , onExit
       , getProcessorPid
       , say
       , toProcess ) where

import Network.CEP.Processor.Types
  ( Processor ()
  , Config (..)
  , ProcessorState ()
  , liftProcess
  , brokers )

import Network.CEP.Processor.Internal
  ( runProcessor
  , actionRunner
  , onExit
  , getProcessorPid
  , say
  , toProcess )
