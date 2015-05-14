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
import HA.ResourceGraph
  ( Resource(..)
  , Relation(..)
  , Dict(..)
  )
import Control.Distributed.Process.Closure

import Data.Hashable (Hashable)
import Data.Binary (Binary)
import Data.Typeable (Typeable)
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

-- | Representation of a physical enclosure.
newtype Enclosure = Enclosure
    String -- ^ Enclosure UUID.
  deriving (Eq, Show, Generic, Typeable, Binary, Hashable)

-- | Representation of a network interface.
newtype Interface = Interface
    String -- ^ Interface ID.
  deriving (Eq, Show, Generic, Typeable, Binary, Hashable)

-- | Representation of a storage device.
data StorageDevice = StorageDevice
    String -- ^ Enclosure UUID.
    Integer -- ^ Drives identified as position in enclosure.
  deriving (Eq, Show, Generic, Typeable)

instance Binary StorageDevice
instance Hashable StorageDevice

-- | Representation of a logical storage device
newtype LogicalDevice = LogicalDevice
    String -- ^ /dev/disk/...
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

-- | The relation between a logical device and the physical storage device
--   it relates to.
data On = On
    deriving (Eq, Show, Generic, Typeable)

instance Binary On
instance Hashable On
--------------------------------------------------------------------------------
-- Dictionaries                                                               --
--------------------------------------------------------------------------------

-- XXX Only nodes and services have runtime information attached to them, for now.

resdict_Host :: Dict (Resource Host)
resdict_DeviceIdentifier :: Dict (Resource DeviceIdentifier)
resdict_Enclosure :: Dict (Resource Enclosure)
resdict_Interface :: Dict (Resource Interface)
resdict_LogicalDevice :: Dict (Resource LogicalDevice)
resdict_StorageDevice :: Dict (Resource StorageDevice)
resdict_StorageDeviceStatus :: Dict (Resource StorageDeviceStatus)

resdict_Host = Dict
resdict_DeviceIdentifier = Dict
resdict_Enclosure = Dict
resdict_Interface = Dict
resdict_LogicalDevice = Dict
resdict_StorageDevice = Dict
resdict_StorageDeviceStatus = Dict

reldict_Has_Cluster_Host :: Dict (Relation Has Cluster Host)
reldict_Has_Host_Interface :: Dict (Relation Has Host Interface)
reldict_Has_Cluster_Enclosure :: Dict (Relation Has Cluster Enclosure)
reldict_Has_Enclosure_StorageDevice :: Dict (Relation Has Enclosure StorageDevice)
reldict_Has_Enclosure_Host :: Dict (Relation Has Enclosure Host)
reldict_Runs_Host_Node :: Dict (Relation Runs Host Node)
reldict_Is_StorageDevice_StorageDeviceStatus :: Dict (Relation Is StorageDevice StorageDeviceStatus)
reldict_On_LogicalDevice_StorageDevice :: Dict (Relation On LogicalDevice StorageDevice)
reldict_Has_Host_LogicalDevice :: Dict (Relation Has Host LogicalDevice)
reldict_Has_StorageDevice_DeviceIdentifier :: Dict (Relation Has StorageDevice DeviceIdentifier)
reldict_Has_LogicalDevice_DeviceIdentifier :: Dict (Relation Has LogicalDevice DeviceIdentifier)

reldict_Has_Cluster_Host = Dict
reldict_Has_Host_Interface = Dict
reldict_Has_Cluster_Enclosure = Dict
reldict_Has_Enclosure_StorageDevice = Dict
reldict_Has_Enclosure_Host = Dict
reldict_Runs_Host_Node = Dict
reldict_Is_StorageDevice_StorageDeviceStatus = Dict
reldict_On_LogicalDevice_StorageDevice = Dict
reldict_Has_Host_LogicalDevice = Dict
reldict_Has_StorageDevice_DeviceIdentifier = Dict
reldict_Has_LogicalDevice_DeviceIdentifier = Dict

remotable [ 'resdict_Host
          , 'resdict_DeviceIdentifier
          , 'resdict_Enclosure
          , 'resdict_Interface
          , 'resdict_LogicalDevice
          , 'resdict_StorageDevice
          , 'resdict_StorageDeviceStatus
          , 'reldict_Has_Cluster_Host
          , 'reldict_Has_Host_Interface
          , 'reldict_Has_Cluster_Enclosure
          , 'reldict_Has_Enclosure_StorageDevice
          , 'reldict_Has_Enclosure_Host
          , 'reldict_Runs_Host_Node
          , 'reldict_Is_StorageDevice_StorageDeviceStatus
          , 'reldict_On_LogicalDevice_StorageDevice
          , 'reldict_Has_Host_LogicalDevice
          , 'reldict_Has_StorageDevice_DeviceIdentifier
          , 'reldict_Has_LogicalDevice_DeviceIdentifier
          ]


instance Resource Host where
    resourceDict = $(mkStatic 'resdict_Host)

instance Resource Enclosure where
    resourceDict = $(mkStatic 'resdict_Enclosure)

instance Resource Interface where
    resourceDict = $(mkStatic 'resdict_Interface)

instance Resource StorageDevice where
    resourceDict = $(mkStatic 'resdict_StorageDevice)

instance Resource StorageDeviceStatus where
    resourceDict = $(mkStatic 'resdict_StorageDeviceStatus)

instance Resource LogicalDevice where
    resourceDict = $(mkStatic 'resdict_LogicalDevice)

instance Resource DeviceIdentifier where
    resourceDict = $(mkStatic 'resdict_DeviceIdentifier)

instance Relation Has Cluster Host where
    relationDict = $(mkStatic 'reldict_Has_Cluster_Host)

instance Relation Has Host Interface where
    relationDict = $(mkStatic 'reldict_Has_Host_Interface)

instance Relation Has Cluster Enclosure where
    relationDict = $(mkStatic 'reldict_Has_Cluster_Enclosure)

instance Relation Has Enclosure StorageDevice where
    relationDict = $(mkStatic 'reldict_Has_Enclosure_StorageDevice)

instance Relation Has Enclosure Host where
    relationDict = $(mkStatic 'reldict_Has_Enclosure_Host)

instance Relation Runs Host Node where
    relationDict = $(mkStatic 'reldict_Runs_Host_Node)

instance Relation Is StorageDevice StorageDeviceStatus where
    relationDict = $(mkStatic 'reldict_Is_StorageDevice_StorageDeviceStatus)

instance Relation On LogicalDevice StorageDevice where
    relationDict = $(mkStatic 'reldict_On_LogicalDevice_StorageDevice)

instance Relation Has Host LogicalDevice where
    relationDict = $(mkStatic 'reldict_Has_Host_LogicalDevice)

instance Relation Has StorageDevice DeviceIdentifier where
    relationDict = $(mkStatic 'reldict_Has_StorageDevice_DeviceIdentifier)

instance Relation Has LogicalDevice DeviceIdentifier where
    relationDict = $(mkStatic 'reldict_Has_LogicalDevice_DeviceIdentifier)
