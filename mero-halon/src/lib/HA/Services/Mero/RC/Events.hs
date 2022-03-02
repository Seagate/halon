{-# LANGUAGE TemplateHaskell #-}
-- |
-- Module    : HA.Services.Mero.RC.Events
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
module HA.Services.Mero.RC.Events
  ( Notified(..)
  , EpochTimeout(..)
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
data Notified = Notified !Word64 -- Epoch
                         !InternalObjectStateChangeMsg 
                         [M0.Process] -- Successfully notified
                         [M0.Process] -- Failed notification
                         [M0.Process] -- Notification timed out
  deriving (Eq, Show, Ord, Generic, Typeable)
instance Hashable Notified
deriveSafeCopy 0 'base ''Notified

-- | Message sent when the maximum time alloted for all
--   notifications in an epoch to have been acknowledged has
--   expired. Most of the time, this will be harmless, since
--   it should arrive after all acks have been received, and
--   be discarded.
newtype EpochTimeout = EpochTimeout Word64
  deriving (Eq, Hashable, Show, Ord, Generic, Typeable)

deriveSafeCopy 0 'base ''EpochTimeout
