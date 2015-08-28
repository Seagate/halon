-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Mero specific resources.

{-# LANGUAGE CPP                        #-}
{-# LANGUAGE MagicHash                  #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

{-# OPTIONS_GHC -fno-warn-orphans       #-}

module HA.Resources.Mero where

import HA.Resources
import HA.Resources.TH

import Data.Hashable (Hashable)
import Data.Binary (Binary)
import Data.Bits
import Data.Typeable (Typeable)
import Data.UUID (UUID)
import Data.Word (Word32)
import GHC.Generics (Generic)

--------------------------------------------------------------------------------
-- Resources                                                                  --
--------------------------------------------------------------------------------

-- | Generic 'identifier' type
data Identifier =
    IdentString String
  | IdentInt Integer
  deriving (Eq, Show, Generic, Typeable)

instance Binary Identifier
instance Hashable Identifier

-- | Representation of a physical host.
newtype Host = Host
    String -- ^ Hostname
  deriving (Eq, Show, Generic, Typeable, Binary, Hashable)

-- | Representation of host device status.
newtype HostStatus = HostStatus Word32
  deriving (Eq, Show, Generic, Typeable, Binary, Hashable)

instance Monoid HostStatus where
  mempty = HostStatus zeroBits
  mappend (HostStatus x) (HostStatus y) = HostStatus $ x .|. y

-- | Possible flags which may be set in the host status.
data HostStatusFlag =
      HS_POWERED
  deriving (Eq, Show, Bounded, Enum)

-- | Test if a host has the given status flag.
hasStatusFlag :: HostStatusFlag -- ^ Query for this status...
              -> HostStatus -- ^ ...in this one.
              -> Bool
hasStatusFlag flag (HostStatus y) = testBit y (fromEnum flag)

-- | Set a status flag.
setStatusFlag :: HostStatusFlag -- ^ Flag to set
              -> HostStatus
              -> HostStatus
setStatusFlag flag (HostStatus y) = HostStatus $ setBit y (fromEnum flag)

-- | Unset a status flag.
unsetStatusFlag :: HostStatusFlag -- ^ Flag to set
                -> HostStatus
                -> HostStatus
unsetStatusFlag flag (HostStatus y) = HostStatus $ clearBit y (fromEnum flag)

-- | Representation of a physical enclosure.
newtype Enclosure = Enclosure
    String -- ^ Enclosure UUID.
  deriving (Eq, Show, Generic, Typeable, Binary, Hashable)

-- | Representation of a network interface.
newtype Interface = Interface
    String -- ^ Interface ID.
  deriving (Eq, Show, Generic, Typeable, Binary, Hashable)

-- | Representation of a storage device
newtype StorageDevice = StorageDevice
    UUID -- ^ Internal UUID used to refer to the disk
  deriving (Eq, Show, Generic, Typeable, Binary, Hashable)

-- | Arbitrary identifier for a logical or storage device
data DeviceIdentifier = DeviceIdentifier String Identifier
  deriving (Eq, Show, Generic, Typeable)

instance Binary DeviceIdentifier
instance Hashable DeviceIdentifier

-- | Labels used to identify what kind of 'Host' we are looking at.
data Label = MeroClient | MeroServer | TrackingStation
           deriving (Eq, Show, Generic, Typeable)

instance Binary Label
instance Hashable Label

-- | Representation of storage device status. Currently this just mirrors
--   the status we get from OpenHPI.
newtype StorageDeviceStatus = StorageDeviceStatus String
  deriving (Eq, Show, Generic, Typeable, Binary, Hashable)

--------------------------------------------------------------------------------
-- Relations                                                                  --
--------------------------------------------------------------------------------

-- | The relation between a configuration object and the runtime resource
-- representing it.
data At = At
    deriving (Eq, Show, Generic, Typeable)

instance Binary At
instance Hashable At

-- | The relation between a configuration object and its state marker.
data Is = Is
    deriving (Eq, Show, Generic, Typeable)

instance Binary Is
instance Hashable Is

--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

-- XXX Only nodes and services have runtime information attached to them, for now.

$(mkDicts
  [ ''Host, ''HostStatus, ''DeviceIdentifier
  , ''Enclosure, ''Interface, ''StorageDevice
  , ''StorageDeviceStatus, ''Label
  ]
  [ (''Cluster, ''Has, ''Host)
  , (''Host, ''Has, ''Interface)
  , (''Host, ''Is, ''HostStatus)
  , (''Cluster, ''Has, ''Enclosure)
  , (''Enclosure, ''Has, ''StorageDevice)
  , (''Enclosure, ''Has, ''Host)
  , (''Host, ''Runs, ''Node)
  , (''StorageDevice, ''Is, ''StorageDeviceStatus)
  , (''Host, ''Has, ''StorageDevice)
  , (''Host, ''Has, ''Label)
  , (''StorageDevice, ''Has, ''StorageDeviceStatus)
  , (''StorageDevice, ''Has, ''DeviceIdentifier)
  ]
  )

$(mkResRel
  [ ''Host, ''HostStatus, ''DeviceIdentifier
  , ''Enclosure, ''Interface, ''StorageDevice
  , ''StorageDeviceStatus, ''Label
  ]
  [ (''Cluster, ''Has, ''Host)
  , (''Host, ''Has, ''Interface)
  , (''Host, ''Is, ''HostStatus)
  , (''Cluster, ''Has, ''Enclosure)
  , (''Enclosure, ''Has, ''StorageDevice)
  , (''Enclosure, ''Has, ''Host)
  , (''Host, ''Runs, ''Node)
  , (''StorageDevice, ''Is, ''StorageDeviceStatus)
  , (''Host, ''Has, ''StorageDevice)
  , (''Host, ''Has, ''Label)
  , (''StorageDevice, ''Has, ''StorageDeviceStatus)
  , (''StorageDevice, ''Has, ''DeviceIdentifier)
  ]
  []
  )
