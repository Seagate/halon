-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Module events for Filesystem entity.

module HA.RecoveryCoordinator.Castor.Filesystem.Events
  ( StatsUpdated(..) )
  where

import qualified HA.Resources.Mero as M0

import Data.Binary   (Binary)
import Data.Typeable (Typeable)

import GHC.Generics

-- | Sent whenever the stats for a given filesystem are updated.
data StatsUpdated = StatsUpdated M0.Filesystem_XXX3 M0.FilesystemStats
  deriving (Eq, Show, Generic, Typeable)

instance Binary StatsUpdated
