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

import Data.Hashable (Hashable(..))
import Data.Binary (Binary(..))
import Data.Typeable (Typeable)
import Data.UUID (UUID)
import GHC.Generics (Generic)

--------------------------------------------------------------------------------
-- Resources                                                                  --
--------------------------------------------------------------------------------

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
  | HA_DOWN
    -- ^ The host is marked as down. This is a simple indication that
    -- we should try to reach the node and have it announce itself to
    -- the RC.
  deriving (Eq, Ord, Show, Generic, Typeable)

instance Binary HostAttr
instance Hashable HostAttr

-- | Representation of a storage device
newtype StorageDevice = StorageDevice
    UUID -- ^ Internal UUID used to refer to the disk
  deriving (Eq, Show, Generic, Typeable, Binary, Hashable)

data StorageDeviceAttr
    = SDResetAttempts !Int
    | SDPowerOnAttempts !Int
    | SDPowerOffAttempts !Int
    | SDPowered
    | SDSMARTRunning
    | SDOnGoingReset
    deriving (Eq, Ord, Show, Generic)

instance Binary StorageDeviceAttr
instance Hashable StorageDeviceAttr

-- | Arbitrary identifier for a logical or storage device
data DeviceIdentifier =
      DIPath String
    | DIIndexInEnclosure Int
    | DIWWN String
    | DIUUID String
    | DIOther String
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
  , ''StorageDeviceStatus, ''StorageDeviceAttr
  , ''MI.BMC
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
  , (''StorageDevice, ''Has, ''StorageDeviceAttr)
  ]
  )

$(mkResRel
  [ ''Rack, ''Host, ''HostAttr, ''DeviceIdentifier
  , ''Enclosure, ''MI.Interface, ''StorageDevice
  , ''StorageDeviceStatus, ''StorageDeviceAttr
  , ''MI.BMC
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
  , (''StorageDevice, ''Has, ''StorageDeviceAttr)
  ]
  []
  )
