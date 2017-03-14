{-# LANGUAGE TemplateHaskell #-}
-- |
-- Module    : HA.Services.Mero.RC.Events
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
module HA.Services.Mero.RC.Events
  ( Notified(..)
  ) where

import Data.Hashable (Hashable)
import Data.Typeable (Typeable)
import Data.Word
import GHC.Generics
import HA.RecoveryCoordinator.Mero.Events
import HA.Resources.Mero as M0
import HA.SafeCopy

-- | Notification that happens when diff of the state change
-- was announced cluster-wide.
data Notified = Notified !Word64 !InternalObjectStateChangeMsg [M0.Process] [M0.Process]
  deriving (Eq, Show, Ord, Generic, Typeable)
instance Hashable Notified
deriveSafeCopy 0 'base ''Notified
