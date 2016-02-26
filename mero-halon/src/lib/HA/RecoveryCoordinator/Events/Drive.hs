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
data DriveRemoved = DriveRemoved
       { drUUID :: UUID -- ^ Event UUID.
       , drNode :: Node -- ^ Node where event happens.
       , drEnclosure :: Enclosure -- ^ Enclosure there event happened.
       , drDevice    :: StorageDevice -- ^ Removed device
       , drDiskNum   :: Int -- ^ Unique location of device in enclosure
       } deriving (Eq, Show, Typeable, Generic)
instance Hashable DriveRemoved
instance Binary DriveRemoved

-- | 'DriveInserted' event should be emitted in order to trigger
-- drive insertion rule.
data DriveInserted = DriveInserted
       { diUUID :: UUID -- ^ Event UUID.
       , diDevice :: StorageDevice -- ^ Inserted device
       , diSerial :: DeviceIdentifier -- ^ Serial drive of device
       , diDiskNum :: Int -- ^ Unique location of device in enclosure
       } deriving (Eq, Show, Typeable, Generic)

instance Hashable DriveInserted
instance Binary DriveInserted

-- | 'DriveFailed' event emitted in order to trigger drive failure rule.
data DriveFailed = DriveFailed UUID Node Enclosure StorageDevice
  deriving (Eq, Show, Typeable, Generic)

instance Hashable DriveFailed
instance Binary DriveFailed
