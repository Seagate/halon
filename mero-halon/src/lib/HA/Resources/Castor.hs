-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Castor specific resources.

{-# LANGUAGE CPP                        #-}
{-# LANGUAGE MagicHash                  #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

{-# OPTIONS_GHC -fno-warn-orphans       #-}

module HA.Resources.Castor (
    module HA.Resources.Castor
  , MI.BMC(..)
  , MI.Interface(..)
) where

import HA.Resources
import qualified HA.Resources.Castor.Initial as MI
import HA.Resources.TH

import Data.Hashable (Hashable)
import Data.Binary (Binary)
import Data.Typeable (Typeable)
import Data.UUID (UUID)
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

newtype Rack = Rack
  Int -- ^ Rack index
  deriving (Eq, Show, Generic, Typeable, Binary, Hashable)

-- | Representation of a physical enclosure.
newtype Enclosure = Enclosure
    String -- ^ Enclosure UUID.
  deriving (Eq, Show, Generic, Typeable, Binary, Hashable)

-- | Representation of a physical host.
newtype Host = Host
    String -- ^ Hostname
  deriving (Eq, Show, Generic, Typeable, Binary, Hashable)

-- | Generic 'host attribute'.
data HostAttr =
    HA_POWERED
  | HA_TSNODE
  | HA_M0CLIENT
  | HA_M0SERVER
  | HA_MEMSIZE_MB Int
  | HA_CPU_COUNT Int
  deriving (Eq, Ord, Show, Generic, Typeable)

instance Binary HostAttr
instance Hashable HostAttr

-- | Representation of a storage device
newtype StorageDevice = StorageDevice
    UUID -- ^ Internal UUID used to refer to the disk
  deriving (Eq, Show, Generic, Typeable, Binary, Hashable)

-- | Arbitrary identifier for a logical or storage device
data DeviceIdentifier = DeviceIdentifier String Identifier
  deriving (Eq, Show, Generic, Typeable)

instance Binary DeviceIdentifier
instance Hashable DeviceIdentifier

-- | Representation of storage device status. Currently this just mirrors
--   the status we get from OpenHPI.
newtype StorageDeviceStatus = StorageDeviceStatus String
  deriving (Eq, Show, Generic, Typeable, Binary, Hashable)

--------------------------------------------------------------------------------
-- Relations                                                                  --
--------------------------------------------------------------------------------

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
  [ ''Rack, ''Host, ''HostAttr, ''DeviceIdentifier
  , ''Enclosure, ''MI.Interface, ''StorageDevice
  , ''StorageDeviceStatus, ''MI.BMC
  ]
  [ (''Cluster, ''Has, ''Rack)
  , (''Cluster, ''Has, ''Host)
  , (''Rack, ''Has, ''Enclosure)
  , (''Host, ''Has, ''MI.Interface)
  , (''Host, ''Has, ''HostAttr)
  , (''Cluster, ''Has, ''Enclosure)
  , (''Enclosure, ''Has, ''StorageDevice)
  , (''Enclosure, ''Has, ''Host)
  , (''Enclosure, ''Has, ''MI.BMC)
  , (''Host, ''Runs, ''Node)
  , (''StorageDevice, ''Is, ''StorageDeviceStatus)
  , (''Host, ''Has, ''StorageDevice)
  , (''StorageDevice, ''Has, ''StorageDeviceStatus)
  , (''StorageDevice, ''Has, ''DeviceIdentifier)
  ]
  )

$(mkResRel
  [ ''Rack, ''Host, ''HostAttr, ''DeviceIdentifier
  , ''Enclosure, ''MI.Interface, ''StorageDevice
  , ''StorageDeviceStatus, ''MI.BMC
  ]
  [ (''Cluster, ''Has, ''Rack)
  , (''Cluster, ''Has, ''Host)
  , (''Rack, ''Has, ''Enclosure)
  , (''Host, ''Has, ''MI.Interface)
  , (''Host, ''Has, ''HostAttr)
  , (''Cluster, ''Has, ''Enclosure)
  , (''Enclosure, ''Has, ''StorageDevice)
  , (''Enclosure, ''Has, ''Host)
  , (''Enclosure, ''Has, ''MI.BMC)
  , (''Host, ''Runs, ''Node)
  , (''StorageDevice, ''Is, ''StorageDeviceStatus)
  , (''Host, ''Has, ''StorageDevice)
  , (''StorageDevice, ''Has, ''StorageDeviceStatus)
  , (''StorageDevice, ''Has, ''DeviceIdentifier)
  ]
  []
  )
