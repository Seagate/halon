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
  , CommandSSPLSmartCheck(..)
  , CommandSSPLSmartCheckResult(..)
  ) where

import           Data.Binary
import           Data.Typeable
import           Control.Distributed.Process
import           GHC.Generics
import           HA.Resources.Castor
import           HA.SafeCopy

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
      , csdpSlot   :: Slot
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

data CommandSSPLSmartCheck = CommandSSPLSmartCheck
       { csscEnabled :: Bool
       } deriving (Eq, Show, Generic, Ord)

data CommandSSPLSmartCheckResult = CommandSSPLSmartCheckResult
       deriving (Eq, Show, Generic, Ord)

deriveSafeCopy 0 'base ''CommandStorageDeviceCreate
deriveSafeCopy 0 'base ''CommandStorageDevicePresence
