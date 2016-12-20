{-# LANGUAGE Rank2Types #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Rules and primitives specific to Mero
module HA.RecoveryCoordinator.RC.Internal
  ( RegisteredMonitors(..)
  , RegisteredSpawns(..)
  , AnyLocalState(..)
  , runMonitorCallback
  , runSpawnCallback
  ) where

import           Control.Distributed.Process
import           Control.Distributed.Process.Internal.Types
import           Data.Binary (encode)
import           Data.ByteString.Lazy (ByteString)
import           Data.Foldable (for_)
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Typeable
import           HA.RecoveryCoordinator.RC.Actions.Core
import           Network.CEP

-- | 'PhaseM' action that doesn't rely on local state.
data AnyLocalState g a = AnyLocalState
  { runAnyLocalState :: (forall l . PhaseM g l a) }

-- | A 'Map' of 'MonitorRef's to 'AnyLocalState' callbacks.
newtype RegisteredMonitors = RegisteredMonitors (Map MonitorRef (AnyLocalState RC ()))
  deriving (Typeable)

-- | A 'Map' of 'encode'd 'SpawnRef's to 'AnyLocalState' callbacks.
--
-- TODO: Once 'SpawnRef' has an 'Ord' instance in
-- @distributed-process@, use it directly instead of encoding
-- (HALON-592).
newtype RegisteredSpawns = RegisteredSpawns (Map ByteString (AnyLocalState RC ()))
  deriving (Typeable)

-- | Run all callbacks for the given 'MonitorRef'. The callbacks are
-- retrieved through 'RegisteredMonitors' in the ephemeral store
-- ('getStorageRC').
runMonitorCallback :: MonitorRef -> PhaseM RC l ()
runMonitorCallback mref = do
  mmons <- getStorageRC
  for_ mmons $ \(RegisteredMonitors mons) -> do
    let (actions, mons') = Map.updateLookupWithKey (\_ _ -> Nothing) mref mons
    putStorageRC (RegisteredMonitors mons')
    for_ actions $ runAnyLocalState

-- | Run all callbacks for the given 'SpawnRef'. The callbacks are
-- retrieved through 'RegisteredSpawns' in the ephemeral store
-- ('getStorageRC').
runSpawnCallback :: SpawnRef -> PhaseM RC l ()
runSpawnCallback ref = do
  mmons <- getStorageRC
  for_ mmons $ \(RegisteredSpawns mons) -> do
    let key = encode ref
    let (actions, mons') = Map.updateLookupWithKey (\_ _ -> Nothing) key mons
    putStorageRC (RegisteredSpawns mons')
    for_ actions $ runAnyLocalState
