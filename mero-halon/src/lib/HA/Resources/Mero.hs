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
newtype StorageDevice = StorageDevice
    Integer -- ^ Drives identified as position in enclosure.
  deriving (Eq, Show, Generic, Typeable, Binary, Hashable)

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
resdict_Enclosure :: Dict (Resource Enclosure)
resdict_Interface :: Dict (Resource Interface)
resdict_StorageDevice :: Dict (Resource StorageDevice)
resdict_StorageDeviceStatus :: Dict (Resource StorageDeviceStatus)

resdict_Host = Dict
resdict_Enclosure = Dict
resdict_Interface = Dict
resdict_StorageDevice = Dict
resdict_StorageDeviceStatus = Dict

reldict_Has_Cluster_Host :: Dict (Relation Has Cluster Host)
reldict_Has_Host_Interface :: Dict (Relation Has Host Interface)
reldict_Has_Cluster_Enclosure :: Dict (Relation Has Cluster Enclosure)
reldict_Has_Enclosure_StorageDevice :: Dict (Relation Has Enclosure StorageDevice)
reldict_Runs_Host_Node :: Dict (Relation Runs Host Node)
reldict_Is_StorageDevice_StorageDeviceStatus :: Dict (Relation Is StorageDevice StorageDeviceStatus)

reldict_Has_Cluster_Host = Dict
reldict_Has_Host_Interface = Dict
reldict_Has_Cluster_Enclosure = Dict
reldict_Has_Enclosure_StorageDevice = Dict
reldict_Runs_Host_Node = Dict
reldict_Is_StorageDevice_StorageDeviceStatus = Dict

remotable [ 'resdict_Host
          , 'resdict_Enclosure
          , 'resdict_Interface
          , 'resdict_StorageDevice
          , 'resdict_StorageDeviceStatus
          , 'reldict_Has_Cluster_Host
          , 'reldict_Has_Host_Interface
          , 'reldict_Has_Cluster_Enclosure
          , 'reldict_Has_Enclosure_StorageDevice
          , 'reldict_Runs_Host_Node
          , 'reldict_Is_StorageDevice_StorageDeviceStatus
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

instance Relation Has Cluster Host where
    relationDict = $(mkStatic 'reldict_Has_Cluster_Host)

instance Relation Has Host Interface where
    relationDict = $(mkStatic 'reldict_Has_Host_Interface)

instance Relation Has Cluster Enclosure where
    relationDict = $(mkStatic 'reldict_Has_Cluster_Enclosure)

instance Relation Has Enclosure StorageDevice where
    relationDict = $(mkStatic 'reldict_Has_Enclosure_StorageDevice)

instance Relation Runs Host Node where
    relationDict = $(mkStatic 'reldict_Runs_Host_Node)

instance Relation Is StorageDevice StorageDeviceStatus where
    relationDict = $(mkStatic 'reldict_Is_StorageDevice_StorageDeviceStatus)
