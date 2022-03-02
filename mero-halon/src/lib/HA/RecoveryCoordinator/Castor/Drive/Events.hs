{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE TemplateHaskell    #-}
-- |
-- Module    : HA.RecoveryCoordinator.Castor.Drive.Events
-- Copyright : (C) 2015-2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Castor drive events
module HA.RecoveryCoordinator.Castor.Drive.Events
  ( DriveRemoved(..)
  , DriveInserted(..)
  , DriveFailed(..)
  , DrivePowerChange(..)
  , DriveTransient(..)
  , DriveOK(..)
  , DriveReady(..)
  , ExpanderReset(..)
  , ResetAttempt(..)
  , ResetAttemptResult(..)
    -- * Metadata drive events
  , RaidUpdate(..)
  , RaidAddToArray(..)
  , RaidAddResult(..)
    -- * SMART test EventsΩ
  , SMARTRequest(..)
  , SMARTResponse(..)
  , SMARTResponseStatus(..)
  ) where

import HA.Resources
import HA.Resources.Castor
import HA.SafeCopy

import Data.UUID (UUID)
import Data.Binary   (Binary)
import Data.Hashable (Hashable)
import qualified Data.Text as T
import Data.Typeable (Typeable)
import GHC.Generics

-- | Event sent when to many failures has been sent for a 'Disk'.
newtype ResetAttempt = ResetAttempt StorageDevice
  deriving (Eq, Generic, Show, Typeable, Ord)
deriveSafeCopy 0 'base ''ResetAttempt

-- | Result for 'ResetAttempt'
data ResetAttemptResult = ResetFailure StorageDevice
                        | ResetSuccess StorageDevice
                        -- | Reset attempt was aborted for some reason.
                        | ResetAborted StorageDevice
  deriving (Eq, Show, Typeable, Generic)

instance Binary ResetAttemptResult

-- | DrivePowerChange event is sent when the power status of a
--   drive changes.
data DrivePowerChange = DrivePowerChange
  { dpcUUID :: UUID -- ^ Thread UUID
  , dpcNode :: Node
  , dpcLocation :: Slot
  , dpcDevice :: StorageDevice
  , dpcPowered :: Bool -- Is device now powered?
  } deriving (Eq, Show, Typeable, Generic)
instance Hashable DrivePowerChange
instance Binary DrivePowerChange

-- | DriveRemoved event is emmited when HPI indicates that a device has been
--   physically removed from the system.
data DriveRemoved = DriveRemoved
       { drUUID :: UUID -- ^ Threaad UUID.
       , drNode :: Node -- ^ Node where event happens.
       , drLocation :: Slot -- ^ Location where event happened.
       , drDevice    :: StorageDevice -- ^ Removed device
       , drPowered :: Maybe Bool -- Is disk powered?
       } deriving (Eq, Show, Typeable, Generic)
instance Hashable DriveRemoved
instance Binary DriveRemoved

-- | 'DriveInserted' event indicates that a drive is physically present within
--   its slot. It can be emitted in two cases:
--   - As a result of HPI indicating the drive is physically present.
--   - As a result of DM data indicating that the OS can see the drive. In this
--     case we may safely infer that the drive is present and powered.
data DriveInserted = DriveInserted
       { diUUID :: UUID -- ^ Thread UUID.
       , diNode :: Node -- ^ Node where event happens.
       , diLocation :: Slot -- ^ Location where event happened.
       , diDevice :: StorageDevice -- ^ Inserted device.
       , diPowered :: Maybe Bool -- Is disk powered?
       } deriving (Eq, Show, Typeable, Generic)

instance Hashable DriveInserted
instance Binary DriveInserted

-- | 'DriveFailed' event indicates that an underlying system has identified a
--   failed drive. Currently this is sent when a SMART test fails on a drive.
data DriveFailed = DriveFailed UUID Node Slot StorageDevice
  deriving (Eq, Show, Typeable, Generic)

instance Hashable DriveFailed
instance Binary DriveFailed

-- | Event emitted when drive manager indicates that a device is no longer
--   visible to the system.
data DriveTransient = DriveTransient UUID Node Slot StorageDevice
  deriving (Eq, Show, Typeable, Generic)

instance Hashable DriveTransient
instance Binary DriveTransient

-- | Event emitted when we get OK indication for the drive
--   from drive manager.
data DriveOK = DriveOK UUID Node Slot StorageDevice
  deriving (Eq, Show, Typeable, Generic)

instance Hashable DriveOK
instance Binary DriveOK

-- | Event sent when a drive is ready and available to be used by the system.
--   This is presently only consumed by the metatada drive rules.
newtype DriveReady = DriveReady StorageDevice
  deriving (Eq, Show, Typeable, Generic)

instance Hashable DriveReady
deriveSafeCopy 0 'base ''DriveReady

-- | Sent when an expander reset attempt happens in the enclosure. In such
--   a case, we expect to see (or have seen) multiple drive transient events.
newtype ExpanderReset = ExpanderReset Enclosure
  deriving (Eq, Show, Typeable, Generic)

instance Hashable ExpanderReset
deriveSafeCopy 0 'base ''ExpanderReset

-- | Sent when RAID controller reports that part of a RAID array has failed.
data RaidUpdate = RaidUpdate
  { ruNode :: Node
  , ruRaidDevice :: T.Text -- ^ RAID device path
  , ruFailedComponents :: [(StorageDevice, T.Text)] -- ^ sd, path
  } deriving (Eq, Show, Typeable, Generic)

instance Hashable RaidUpdate
deriveSafeCopy 0 'base ''RaidUpdate

-- | Request that the given storage device is added to a RAID array.
-- The array is determined by looking at 'StorageDevice' identifiers.
newtype RaidAddToArray = RaidAddToArray StorageDevice
  deriving (Eq, Show, Typeable, Generic, Ord)
instance Hashable RaidAddToArray
deriveSafeCopy 0 'base ''RaidAddToArray

-- | Result part of 'RaidAddToArray'
data RaidAddResult = RaidAddOK StorageDevice
                   | RaidAddFailed StorageDevice
  deriving (Eq, Show, Typeable, Generic, Ord)

instance Binary RaidAddResult
instance Hashable RaidAddResult

-- | Sent to request a SMART test is run on the system.
data SMARTRequest = SMARTRequest {
    srqNode :: Node
  , srqDevice :: StorageDevice
} deriving (Eq, Show, Ord, Typeable, Generic)

instance Hashable SMARTRequest
deriveSafeCopy 0 'base ''SMARTRequest

-- | Possible response from SMART testing.
data SMARTResponseStatus
  = SRSSuccess
  | SRSFailed
  | SRSTimeout
  | SRSNotAvailable -- ^ Sent when SMART functionality is not available.
  | SRSNotPossible -- ^ Sent when it is not possible to run a SMART test.
  deriving (Eq, Show, Typeable, Generic)

instance Hashable SMARTResponseStatus
deriveSafeCopy 0 'base ''SMARTResponseStatus

-- | Response from SMART test job.
data SMARTResponse = SMARTResponse {
    srpDevice :: StorageDevice
  , srpStatus :: SMARTResponseStatus
} deriving (Eq, Show, Typeable, Generic)

instance Hashable SMARTResponse
deriveSafeCopy 0 'base ''SMARTResponse
