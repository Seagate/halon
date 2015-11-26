-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
module HA.RecoveryCoordinator.Events.Drive
  ( DriveRemoved(..)
  , DriveInserted(..)
  , DriveFailed(..)
  ) where

import HA.Resources
import HA.Resources.Castor

import Data.UUID (UUID)

import Data.Binary   (Binary)
import Data.Hashable (Hashable)
import Data.Typeable (Typeable)
import GHC.Generics

-- | DriveRemoved event is emmited when somebody need to trigger
-- event that should happen when any drive have failed.
data DriveRemoved = DriveRemoved UUID Node Enclosure StorageDevice
       deriving (Eq, Show, Typeable, Generic)
instance Hashable DriveRemoved
instance Binary DriveRemoved

-- | 'DriveInsted' event should be emitted in order to trigger
-- drive insertion rule.
data DriveInserted = DriveInserted UUID StorageDevice
       deriving (Eq, Show, Typeable, Generic)

instance Hashable DriveInserted
instance Binary DriveInserted

data DriveFailed = DriveFailed UUID Node Enclosure StorageDevice
       deriving (Eq, Show, Typeable, Generic)

instance Hashable DriveFailed
instance Binary DriveFailed
