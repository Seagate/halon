{-# LANGUAGE TypeFamilies #-}
-- |
-- Copyright : (C) 2016 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Defines the CEP Application for the recovery co-ordinator.

module HA.RecoveryCoordinator.RC.Application where

import HA.Multimap (StoreChan)
import qualified HA.RecoveryCoordinator.RC.Internal.Storage as Storage
import qualified HA.ResourceGraph as G

import Control.Distributed.Process (ProcessId)

import qualified Data.Map.Strict as Map
import Data.UUID (UUID)

import Network.CEP (Application(..))
import qualified HA.RecoveryCoordinator.Log as Log

-- | 'Phantom' type used to define CEP 'Application'.
data RC

instance Application RC where
  type GlobalState RC = LoopState
  type LogType RC = Log.Event

data LoopState = LoopState {
    lsGraph    :: G.Graph -- ^ Graph
  , lsMMChan   :: StoreChan -- ^ Replicated Multimap channel
  , lsEQPid    :: ProcessId -- ^ EQ pid
  , lsRefCount :: Map.Map UUID Int
    -- ^ Set of HAEvent uuid we've already handled.
  , lsStorage :: !Storage.Storage -- ^ Global ephimeral storage.
}
