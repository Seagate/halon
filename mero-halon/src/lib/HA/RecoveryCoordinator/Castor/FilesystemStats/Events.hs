-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Module events for FilesystemStats entity.

module HA.RecoveryCoordinator.Castor.FilesystemStats.Events
  ( StatsUpdated(..) )
  where

import qualified HA.Resources.Mero as M0

import Data.Binary (Binary)
import Data.Typeable (Typeable)

import GHC.Generics

-- | Sent whenever Mero filesystem statistics are updated.
data StatsUpdated = StatsUpdated M0.FilesystemStats
  deriving (Eq, Show, Generic, Typeable)

instance Binary StatsUpdated
