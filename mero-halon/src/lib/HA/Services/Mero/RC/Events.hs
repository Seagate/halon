-- Copyright: (C) 2016 Seagate LLC
--
module HA.Services.Mero.RC.Events
  ( Notified(..)
  ) where

import HA.RecoveryCoordinator.Events.Mero
import HA.Resources.Mero as M0

import Data.Binary (Binary)
import Data.Hashable (Hashable)
import Data.Typeable (Typeable)
import Data.Word
import GHC.Generics

-- | Notification that happens when diff of the state change
-- was announced cluster-wide.
data Notified = Notified Word64 InternalObjectStateChangeMsg [M0.Process] [M0.Process]
  deriving (Eq, Show, Ord, Generic, Typeable)
instance Binary Notified
instance Hashable Notified
