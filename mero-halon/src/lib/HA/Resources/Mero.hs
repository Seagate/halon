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
#ifdef USE_MERO
import qualified HA.Resources.Mero.Initial as MI
#endif
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
  deriving (Eq, Show, Generic, Typeable)

instance Binary HostAttr
instance Hashable HostAttr

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
  [ ''Host, ''HostAttr, ''DeviceIdentifier
  , ''Enclosure, ''Interface, ''StorageDevice
  , ''StorageDeviceStatus
  ]
  [ (''Cluster, ''Has, ''Host)
  , (''Host, ''Has, ''Interface)
  , (''Host, ''Has, ''HostAttr)
  , (''Cluster, ''Has, ''Enclosure)
  , (''Enclosure, ''Has, ''StorageDevice)
  , (''Enclosure, ''Has, ''Host)
  , (''Host, ''Runs, ''Node)
  , (''StorageDevice, ''Is, ''StorageDeviceStatus)
  , (''Host, ''Has, ''StorageDevice)
  , (''StorageDevice, ''Has, ''StorageDeviceStatus)
  , (''StorageDevice, ''Has, ''DeviceIdentifier)
  ]
  )

$(mkResRel
  [ ''Host, ''HostAttr, ''DeviceIdentifier
  , ''Enclosure, ''Interface, ''StorageDevice
  , ''StorageDeviceStatus
  ]
  [ (''Cluster, ''Has, ''Host)
  , (''Host, ''Has, ''Interface)
  , (''Host, ''Has, ''HostAttr)
  , (''Cluster, ''Has, ''Enclosure)
  , (''Enclosure, ''Has, ''StorageDevice)
  , (''Enclosure, ''Has, ''Host)
  , (''Host, ''Runs, ''Node)
  , (''StorageDevice, ''Is, ''StorageDeviceStatus)
  , (''Host, ''Has, ''StorageDevice)
  , (''StorageDevice, ''Has, ''StorageDeviceStatus)
  , (''StorageDevice, ''Has, ''DeviceIdentifier)
  ]
  []
  )
