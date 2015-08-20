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

resdict_Host :: Dict (Resource Host)
resdict_HostStatus :: Dict (Resource HostStatus)
resdict_DeviceIdentifier :: Dict (Resource DeviceIdentifier)
resdict_Enclosure :: Dict (Resource Enclosure)
resdict_Interface :: Dict (Resource Interface)
resdict_StorageDevice :: Dict (Resource StorageDevice)
resdict_StorageDeviceStatus :: Dict (Resource StorageDeviceStatus)
resdict_Label :: Dict (Resource Label)

resdict_Host = Dict
resdict_HostStatus = Dict
resdict_DeviceIdentifier = Dict
resdict_Enclosure = Dict
resdict_Interface = Dict
resdict_StorageDevice = Dict
resdict_StorageDeviceStatus = Dict
resdict_Label = Dict

reldict_Has_Cluster_Host :: Dict (Relation Has Cluster Host)
reldict_Has_Host_Interface :: Dict (Relation Has Host Interface)
reldict_Is_Host_HostStatus :: Dict (Relation Is Host HostStatus)
reldict_Has_Cluster_Enclosure :: Dict (Relation Has Cluster Enclosure)
reldict_Has_Enclosure_StorageDevice :: Dict (Relation Has Enclosure StorageDevice)
reldict_Has_Enclosure_Host :: Dict (Relation Has Enclosure Host)
reldict_Runs_Host_Node :: Dict (Relation Runs Host Node)
reldict_Is_StorageDevice_StorageDeviceStatus :: Dict (Relation Is StorageDevice StorageDeviceStatus)
reldict_Has_Host_StorageDevice :: Dict (Relation Has Host StorageDevice)
reldict_Has_Host_Label :: Dict (Relation Has Host Label)
reldict_Has_StorageDevice_DeviceIdentifier :: Dict (Relation Has StorageDevice DeviceIdentifier)

reldict_Has_Cluster_Host = Dict
reldict_Has_Host_Interface = Dict
reldict_Is_Host_HostStatus = Dict
reldict_Has_Cluster_Enclosure = Dict
reldict_Has_Enclosure_StorageDevice = Dict
reldict_Has_Enclosure_Host = Dict
reldict_Runs_Host_Node = Dict
reldict_Is_StorageDevice_StorageDeviceStatus = Dict
reldict_Has_Host_StorageDevice = Dict
reldict_Has_Host_Label = Dict
reldict_Has_StorageDevice_DeviceIdentifier = Dict

remotable [ 'resdict_Host
          , 'resdict_HostStatus
          , 'resdict_DeviceIdentifier
          , 'resdict_Enclosure
          , 'resdict_Interface
          , 'resdict_StorageDevice
          , 'resdict_StorageDeviceStatus
          , 'resdict_Label
          , 'reldict_Has_Cluster_Host
          , 'reldict_Has_Host_Interface
          , 'reldict_Is_Host_HostStatus
          , 'reldict_Has_Cluster_Enclosure
          , 'reldict_Has_Enclosure_StorageDevice
          , 'reldict_Has_Enclosure_Host
          , 'reldict_Runs_Host_Node
          , 'reldict_Is_StorageDevice_StorageDeviceStatus
          , 'reldict_Has_Host_StorageDevice
          , 'reldict_Has_Host_Label
          , 'reldict_Has_StorageDevice_DeviceIdentifier
          ]


instance Resource Host where
    resourceDict = $(mkStatic 'resdict_Host)

instance Resource HostStatus where
    resourceDict = $(mkStatic 'resdict_HostStatus)

instance Resource Enclosure where
    resourceDict = $(mkStatic 'resdict_Enclosure)

instance Resource Interface where
    resourceDict = $(mkStatic 'resdict_Interface)

instance Resource StorageDevice where
    resourceDict = $(mkStatic 'resdict_StorageDevice)

instance Resource StorageDeviceStatus where
    resourceDict = $(mkStatic 'resdict_StorageDeviceStatus)

instance Resource DeviceIdentifier where
    resourceDict = $(mkStatic 'resdict_DeviceIdentifier)

instance Resource Label where
    resourceDict = $(mkStatic 'resdict_Label)

instance Relation Has Cluster Host where
    relationDict = $(mkStatic 'reldict_Has_Cluster_Host)

instance Relation Has Host Interface where
    relationDict = $(mkStatic 'reldict_Has_Host_Interface)

instance Relation Is Host HostStatus where
    relationDict = $(mkStatic 'reldict_Is_Host_HostStatus)

instance Relation Has Host Label where
    relationDict = $(mkStatic 'reldict_Has_Host_Label)

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

instance Relation Has Host StorageDevice where
    relationDict = $(mkStatic 'reldict_Has_Host_StorageDevice)

instance Relation Has StorageDevice DeviceIdentifier where
    relationDict = $(mkStatic 'reldict_Has_StorageDevice_DeviceIdentifier)
