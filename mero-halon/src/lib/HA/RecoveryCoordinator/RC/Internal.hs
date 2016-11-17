-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Rules and primitives specific to Mero
{-# LANGUAGE Rank2Types #-}
{-# OPTIONS_GHC -Werror #-}
module HA.RecoveryCoordinator.RC.Internal
  ( RegisteredMonitors(..)
  , RegisteredSpawns(..)
  , AnyLocalState(..)
  , runMonitorCallback
  , runSpawnCallback
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Internal.Types
import Data.ByteString.Lazy (ByteString)
import Data.Binary (encode)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Foldable (for_)
import Network.CEP

import HA.RecoveryCoordinator.Actions.Core
import Data.Typeable

data AnyLocalState g a = AnyLocalState
  { runAnyLocalState :: (forall l . PhaseM g l a) }

newtype RegisteredMonitors = RegisteredMonitors (Map MonitorRef (AnyLocalState RC ()))
  deriving (Typeable)

newtype RegisteredSpawns = RegisteredSpawns (Map ByteString (AnyLocalState RC ()))
  deriving (Typeable)

-- Notify all interested subscribers
runMonitorCallback :: MonitorRef -> PhaseM RC l ()
runMonitorCallback mref = do
  mmons <- getStorageRC
  for_ mmons $ \(RegisteredMonitors mons) -> do
    let (actions, mons') = Map.updateLookupWithKey (\_ _ -> Nothing) mref mons
    putStorageRC (RegisteredMonitors mons')
    for_ actions $ runAnyLocalState

runSpawnCallback :: SpawnRef -> PhaseM RC l ()
runSpawnCallback ref = do
  mmons <- getStorageRC
  for_ mmons $ \(RegisteredSpawns mons) -> do
    let key = encode ref
    let (actions, mons') = Map.updateLookupWithKey (\_ _ -> Nothing) key mons
    putStorageRC (RegisteredSpawns mons')
    for_ actions $ runAnyLocalState
