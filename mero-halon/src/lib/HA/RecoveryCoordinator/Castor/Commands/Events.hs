{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Events related to castor commands.
module HA.RecoveryCoordinator.Castor.Commands.Events
  ( CommandStorageDeviceCreate(..)
  , CommandStorageDeviceCreateResult(..)
  , CommandStorageDevicePresence(..)
  , CommandStorageDevicePresenceResult(..)
  , CommandStorageDeviceStatus(..)
  , CommandStorageDeviceStatusResult(..)
  ) where

import Data.Binary
import Data.Typeable
import GHC.Generics

import Control.Distributed.Process

import HA.Resources.Castor (Slot_XXX1)
import HA.SafeCopy

-- | Request to create new storage device.
data CommandStorageDeviceCreate = CommandStorageDeviceCreate
      { csdcSerial :: String
      , csdcPath   :: String
      , csscReplyTo :: SendPort CommandStorageDeviceCreateResult
      } deriving (Eq, Show, Generic, Ord)

-- | Result of the 'CommandStorageDeviceCreate'.
data CommandStorageDeviceCreateResult
      = StorageDeviceErrorAlreadyExists
      | StorageDeviceCreated
      deriving (Eq, Show, Generic, Typeable)

instance Binary CommandStorageDeviceCreateResult

-- | Update  information about known drive.
data CommandStorageDevicePresence = CommandStorageDevicePresence
      { csdpSerial :: String
      , csdpSlot   :: Slot_XXX1
      , csdpIsInstalled :: Bool
      , csdpIsPowered   :: Bool
      , csdpReplyTo :: SendPort CommandStorageDevicePresenceResult
      } deriving (Eq, Show, Generic, Ord)

-- | Result of the 'CommandStorageDevicePresence'.
data CommandStorageDevicePresenceResult
       = StorageDevicePresenceUpdated
       | StorageDevicePresenceErrorNoSuchDevice
       | StorageDevicePresenceErrorNoSuchEnclosure
       deriving (Eq, Show, Generic, Ord)

instance Binary CommandStorageDevicePresenceResult

-- | Update status of the known drive.
data CommandStorageDeviceStatus = CommandStorageDeviceStatus
      { csdsSerial :: String
      , csdsSlot :: Slot_XXX1
      , csdsStatus :: String
      , csdsReason :: String
      , csdsReplyTo :: SendPort CommandStorageDeviceStatusResult
      } deriving (Eq, Show, Generic, Ord)

-- | Result of the 'CommandStorageDeviceStatus'.
data CommandStorageDeviceStatusResult
       = StorageDeviceStatusUpdated
       | StorageDeviceStatusErrorNoSuchDevice
       | StorageDeviceStatusErrorNoSuchEnclosure
       deriving (Eq, Show, Generic, Ord)
instance Binary CommandStorageDeviceStatusResult

deriveSafeCopy 0 'base ''CommandStorageDeviceCreate
deriveSafeCopy 0 'base ''CommandStorageDevicePresence
deriveSafeCopy 0 'base ''CommandStorageDeviceStatus
