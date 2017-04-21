{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StrictData            #-}
{-# LANGUAGE TemplateHaskell       #-}
-- |
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Castor specific resources.
module HA.Resources.Castor.Old
  ( StorageDevice(..)
  , DeviceIdentifier(..)
  , StorageDeviceAttr(..)
  , __resourcesTable
  , __remoteTable
  ) where

import           HA.Aeson
import           Data.Hashable (Hashable)
import           Data.Typeable (Typeable)
import           Data.UUID (UUID)
import           GHC.Generics (Generic)
import qualified HA.Resources as R
import qualified HA.Resources.Mero as M0
import qualified HA.Services.SSPL.LL.Resources as SSPL
import qualified HA.Resources.Castor as C
import           HA.Resources.TH
import           HA.SafeCopy

newtype StorageDevice = StorageDevice
    UUID -- ^ Internal UUID used to refer to the disk
  deriving (Eq, Show, Ord, Generic, Typeable, Hashable)
storageIndex ''StorageDevice "54843dda-3326-4efc-9409-b124a4e89316"
deriveSafeCopy 0 'base ''StorageDevice
instance ToJSON StorageDevice

data StorageDeviceAttr
    = SDResetAttempts !Int
    | SDPowered Bool
    | SDOnGoingReset
    | SDRemovedAt
    | SDReplaced
    | SDRemovedFromRAID
    deriving (Eq, Ord, Show, Generic)
storageIndex ''StorageDeviceAttr "0707116d-57d6-474f-9866-567c255d072d"
deriveSafeCopy 0 'base ''StorageDeviceAttr
instance ToJSON StorageDeviceAttr
instance Hashable StorageDeviceAttr

-- | Arbitrary identifier for a logical or storage device
data DeviceIdentifier =
      DIPath String
    | DIIndexInEnclosure Int
    | DIWWN String
    | DIUUID String
    | DISerialNumber String
    | DIRaidIdx Int -- Index in RAID array
    | DIRaidDevice String -- Device name of RAID device containing this
  deriving (Eq, Show, Ord, Generic, Typeable)
storageIndex ''DeviceIdentifier "1982ab3c-4779-4f5c-a070-03fa0427da66"
deriveSafeCopy 0 'base ''DeviceIdentifier
instance ToJSON DeviceIdentifier
instance Hashable DeviceIdentifier

mkStorageDicts [''StorageDevice , ''DeviceIdentifier, ''StorageDeviceAttr]
  [ (''C.Enclosure, ''R.Has, ''StorageDevice)
  , (''C.Host, ''R.Has, ''StorageDevice)
  , (''M0.Disk, ''M0.At, ''StorageDevice)
  , (''StorageDevice, ''C.Is, ''C.StorageDeviceStatus)
  , (''StorageDevice, ''R.Has, ''C.StorageDeviceStatus)
  , (''StorageDevice, ''C.Is, ''DeviceIdentifier)
  , (''StorageDevice, ''R.Has, ''StorageDeviceAttr)
  , (''StorageDevice, ''R.Has, ''DeviceIdentifier)
  , (''StorageDevice, ''R.Has, ''SSPL.LedControlState)
  ]

mkOldRels [''StorageDevice , ''DeviceIdentifier, ''StorageDeviceAttr]
  [ (''C.Enclosure, ''R.Has, ''StorageDevice)
  , (''C.Host, ''R.Has, ''StorageDevice)
  , (''M0.Disk, ''M0.At, ''StorageDevice)
  , (''StorageDevice, ''C.Is, ''C.StorageDeviceStatus)
  , (''StorageDevice, ''R.Has, ''C.StorageDeviceStatus)
  , (''StorageDevice, ''C.Is, ''DeviceIdentifier)
  , (''StorageDevice, ''R.Has, ''StorageDeviceAttr)
  , (''StorageDevice, ''R.Has, ''DeviceIdentifier)
  , (''StorageDevice, ''R.Has, ''SSPL.LedControlState)
  ]
