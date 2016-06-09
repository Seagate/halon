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
  , DrivePowerChange(..)
  , ExpanderReset(..)
  , ResetAttempt(..)
  , ResetSuccess(..)
  , ResetFailure(..)
  ) where

import HA.Resources
import HA.Resources.Castor

import Data.UUID (UUID)

import Data.Binary   (Binary)
import Data.Hashable (Hashable)
import qualified Data.Text as T
import Data.Typeable (Typeable)
import GHC.Generics

-- | Event sent when to many failures has been sent for a 'Disk'.
data ResetAttempt = ResetAttempt StorageDevice
  deriving (Eq, Generic, Show, Typeable)

instance Binary ResetAttempt

-- | Event sent when a ResetAttempt were successful.
newtype ResetSuccess =
    ResetSuccess StorageDevice
    deriving (Eq, Show, Binary)

-- | Event sent when a ResetAttempt failed.
newtype ResetFailure =
    ResetFailure StorageDevice
    deriving (Eq, Show, Binary)

-- | DrivePowerChange event is sent when the power status of a
--   drive changes.
data DrivePowerChange = DrivePowerChange
  { dpcUUID :: UUID
  , dpcNode :: Node
  , dpcEnclosure :: Enclosure
  , dpcDevice :: StorageDevice
  , dpcDiskNum :: Int
  , dpcSerial :: T.Text
  , dpcPowered :: Bool -- Is device now powered?
  } deriving (Eq, Show, Typeable, Generic)
instance Hashable DrivePowerChange
instance Binary DrivePowerChange

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
       , diDevice :: StorageDevice -- ^ Inserted device.
       , diEnclosure :: Enclosure -- ^ Enclosure where event happened.
       , diDiskNum :: Int -- ^ Unique location of device in enclosure.
       , diSerial :: DeviceIdentifier -- ^ Serial drive of device.
       } deriving (Eq, Show, Typeable, Generic)

instance Hashable DriveInserted
instance Binary DriveInserted

-- | 'DriveFailed' event emitted in order to trigger drive failure rule.
data DriveFailed = DriveFailed UUID Node Enclosure StorageDevice
  deriving (Eq, Show, Typeable, Generic)

instance Hashable DriveFailed
instance Binary DriveFailed

-- | Sent when an expander reset attempt happens in the enclosure. In such
--   a case, we expect to see (or have seen) multiple drive failures
data ExpanderReset = ExpanderReset Enclosure
  deriving (Eq, Show, Typeable, Generic)

instance Hashable ExpanderReset
instance Binary ExpanderReset
