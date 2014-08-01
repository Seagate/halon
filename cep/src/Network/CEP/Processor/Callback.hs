-- |
-- Copyright: (C) 2014 Tweag I/O Limited
-- 
-- A basic callback-based interface to CEP.
-- 

module Network.CEP.Processor.Callback
  ( module Network.CEP.Types
  , publish
  , subscribe ) where

import Network.CEP.Types
import Network.CEP.Processor.Internal (publish, subscribe)
