{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TemplateHaskell            #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Mero specific resources in Halon.
-- Should be imported qualified:
-- import qualified HA.Resources.Mero as M0

module HA.Resources.Mero
  ( module HA.Resources.Mero
  , CI.M0Globals
  ) where

import qualified HA.Resources as R
import HA.Resources.TH
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Castor.Initial as CI

import Mero.ConfC (Bitmap, Fid(..), ServiceParams, ServiceType)

import Data.Binary (Binary)
import Data.Bits
import Data.Char (ord)
import Data.Hashable (Hashable)
import Data.Proxy (Proxy)
import Data.Typeable (Typeable)
import Data.Word ( Word32, Word64 )

import GHC.Generics (Generic)

-- | Fid generation sequence number
newtype FidSeq = FidSeq Word64
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

-- | Couple of utility methods for conf objects. Minimal implementation:
--   fidType and fid
class ConfObj a where

  -- Return the fid type of the conf object.
  fidType :: Proxy a
          -> Word64

  fidInit :: Proxy a
          -> Word64 -- container
          -> Word64 -- key
          -> Fid
  fidInit p cont key = Fid {
        f_container = container
      , f_key = key
      }
    where
      -- The top 8 bits of f_container specify the object type.
      typ = fidType p
      typMask = 0x00ffffffffffffff
      container = (typ `shiftL` (64 - 8)) .|. (cont .&. typMask)

  -- | Return the Mero fid for the given conf object
  fid :: a -> Fid
  {-# MINIMAL fidType, fid #-}

data AnyConfObj = forall a. ConfObj a => AnyConfObj a
--------------------------------------------------------------------------------
-- Conf tree in the resource graph
--------------------------------------------------------------------------------

-- | The relation between a configuration object and the runtime resource
-- representing it.
-- Directed from configuration object to Halon resource
-- (e.g. M0.Controller At Host)
data At = At
    deriving (Eq, Show, Generic, Typeable)

instance Binary At
instance Hashable At

-- | Relationship between parent and child entities in confd
--   Directed from parent to child (e.g. profile IsParentOf filesystem)
data IsParentOf = IsParentOf
   deriving (Eq, Generic, Show, Typeable)

instance Binary IsParentOf
instance Hashable IsParentOf

-- | Relationship between virtual and real entities in confd.
--   Directed from real to virtual (e.g. pool IsRealOf pver)
data IsRealOf = IsRealOf
   deriving (Eq, Generic, Show, Typeable)

instance Binary IsRealOf
instance Hashable IsRealOf

-- | Relationship between conceptual and hardware entities in confd
--   Directed from sdev to disk (e.g. sdev IsOnHardware disk)
--   Directed from node to controller (e.g. node IsOnHardware controller)
data IsOnHardware = IsOnHardware
   deriving (Eq, Generic, Show, Typeable)

instance Binary IsOnHardware
instance Hashable IsOnHardware

newtype Profile = Profile Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

instance ConfObj Profile where
  fidType _ = fromIntegral . ord $ 'p'
  fid (Profile f) = f

data Filesystem = Filesystem {
    f_fid :: Fid
  , f_mdpool_fid :: Fid -- ^ Fid of filesystem metadata pool
} deriving (Eq, Generic, Show, Typeable)

instance Binary Filesystem
instance Hashable Filesystem

instance ConfObj Filesystem where
  fidType _ = fromIntegral . ord $ 'f'
  fid = f_fid

newtype Node = Node Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

instance ConfObj Node where
  fidType _ = fromIntegral . ord $ 'n'
  fid (Node f) = f

newtype Rack = Rack Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

instance ConfObj Rack where
  fidType _ = fromIntegral . ord $ 'a'
  fid (Rack f) = f

newtype Pool = Pool Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

instance ConfObj Pool where
  fidType _ = fromIntegral . ord $ 'o'
  fid (Pool f) = f

data Process = Process {
    r_fid :: Fid
  , r_mem_as :: Word64
  , r_mem_rss :: Word64
  , r_mem_stack :: Word64
  , r_mem_memlock :: Word64
  , r_cores :: Bitmap
} deriving (Eq, Generic, Show, Typeable)

instance Binary Process
instance Hashable Process
instance ConfObj Process where
  fidType _ = fromIntegral . ord $ 'r'
  fid = r_fid

data Service = Service {
    s_fid :: Fid
  , s_type :: ServiceType -- ^ e.g. ioservice, haservice
  , s_endpoints :: [String]
  , s_params :: ServiceParams
} deriving (Eq, Generic, Show, Typeable)

instance Binary Service
instance Hashable Service
instance ConfObj Service where
  fidType _ = fromIntegral . ord $ 's'
  fid = s_fid

data SDev = SDev {
    d_fid :: Fid
  , d_size :: Word64 -- ^ Size in mb
  , d_bsize :: Word32 -- ^ Block size in mb
  , d_path :: String -- ^ Path to logical device
} deriving (Eq, Generic, Show, Typeable)

instance Binary SDev
instance Hashable SDev
instance ConfObj SDev where
  fidType _ = fromIntegral . ord $ 'd'
  fid = d_fid

newtype Enclosure = Enclosure Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

instance ConfObj Enclosure where
  fidType _ = fromIntegral . ord $ 'e'
  fid (Enclosure f) = f

newtype Controller = Controller Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

instance ConfObj Controller where
  fidType _ = fromIntegral . ord $ 'c'
  fid (Controller f) = f

newtype Disk = Disk Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

instance ConfObj Disk where
  fidType _ = fromIntegral . ord $ 'k'
  fid (Disk f) = f

newtype PVer = PVer Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

instance ConfObj PVer where
  fidType _ = fromIntegral . ord $ 'v'
  fid (PVer f) = f

newtype RackV = RackV Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

instance ConfObj RackV where
  fidType _ = fromIntegral . ord $ 'j'
  fid (RackV f) = f

newtype EnclosureV = EnclosureV Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

instance ConfObj EnclosureV where
  fidType _ = fromIntegral . ord $ 'j'
  fid (EnclosureV f) = f

newtype ControllerV = ControllerV Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

instance ConfObj ControllerV where
  fidType _ = fromIntegral . ord $ 'j'
  fid (ControllerV f) = f

newtype DiskV = DiskV Fid
  deriving (Binary, Eq, Generic, Hashable, Show, Typeable)

instance ConfObj DiskV where
  fidType _ = fromIntegral . ord $ 'j'
  fid (DiskV f) = f

$(mkDicts
  [ ''FidSeq, ''Profile, ''Filesystem, ''Node, ''Rack, ''Pool
  , ''Process, ''Service, ''SDev, ''Enclosure, ''Controller
  , ''Disk, ''PVer, ''RackV, ''EnclosureV, ''ControllerV
  , ''DiskV, ''CI.M0Globals
  ]
  [ -- Relationships connecting conf with other resources
    (''R.Cluster, ''R.Has, ''Profile)
  , (''Controller, ''At, ''R.Host)
  , (''Rack, ''At, ''R.Rack)
  , (''Enclosure, ''At, ''R.Enclosure)
  , (''Disk, ''At, ''R.StorageDevice)
    -- Parent/child relationships between conf entities
  , (''Profile, ''IsParentOf, ''Filesystem)
  , (''Filesystem, ''IsParentOf, ''Node)
  , (''Filesystem, ''IsParentOf, ''Rack)
  , (''Filesystem, ''IsParentOf, ''Pool)
  , (''Node, ''IsParentOf, ''Process)
  , (''Process, ''IsParentOf, ''Service)
  , (''Service, ''IsParentOf, ''SDev)
  , (''Rack, ''IsParentOf, ''Enclosure)
  , (''Enclosure, ''IsParentOf, ''Controller)
  , (''Controller, ''IsParentOf, ''Disk)
  , (''PVer, ''IsParentOf, ''RackV)
  , (''RackV, ''IsParentOf, ''EnclosureV)
  , (''EnclosureV, ''IsParentOf, ''ControllerV)
  , (''ControllerV, ''IsParentOf, ''DiskV)
    -- Virtual relationships between conf entities
  , (''Pool, ''IsRealOf, ''PVer)
  , (''Rack, ''IsRealOf, ''RackV)
  , (''Enclosure, ''IsRealOf, ''EnclosureV)
  , (''Controller, ''IsRealOf, ''ControllerV)
  , (''Disk, ''IsRealOf, ''DiskV)
    -- Conceptual/hardware relationships between conf entities
  , (''SDev, ''IsOnHardware, ''Disk)
  , (''Node, ''IsOnHardware, ''Controller)
    -- Other things!
  , (''R.Cluster, ''R.Has, ''FidSeq)
  , (''R.Cluster, ''R.Has, ''CI.M0Globals)
  ]
  )

$(mkResRel
  [ ''FidSeq, ''Profile, ''Filesystem, ''Node, ''Rack, ''Pool
  , ''Process, ''Service, ''SDev, ''Enclosure, ''Controller
  , ''Disk, ''PVer, ''RackV, ''EnclosureV, ''ControllerV
  , ''DiskV, ''CI.M0Globals
  ]
  [ -- Relationships connecting conf with other resources
    (''R.Cluster, ''R.Has, ''Profile)
  , (''Controller, ''At, ''R.Host)
  , (''Rack, ''At, ''R.Rack)
  , (''Enclosure, ''At, ''R.Enclosure)
  , (''Disk, ''At, ''R.StorageDevice)
    -- Parent/child relationships between conf entities
  , (''Profile, ''IsParentOf, ''Filesystem)
  , (''Filesystem, ''IsParentOf, ''Node)
  , (''Filesystem, ''IsParentOf, ''Rack)
  , (''Filesystem, ''IsParentOf, ''Pool)
  , (''Node, ''IsParentOf, ''Process)
  , (''Process, ''IsParentOf, ''Service)
  , (''Service, ''IsParentOf, ''SDev)
  , (''Rack, ''IsParentOf, ''Enclosure)
  , (''Enclosure, ''IsParentOf, ''Controller)
  , (''Controller, ''IsParentOf, ''Disk)
  , (''PVer, ''IsParentOf, ''RackV)
  , (''RackV, ''IsParentOf, ''EnclosureV)
  , (''EnclosureV, ''IsParentOf, ''ControllerV)
  , (''ControllerV, ''IsParentOf, ''DiskV)
    -- Virtual relationships between conf entities
  , (''Pool, ''IsRealOf, ''PVer)
  , (''Rack, ''IsRealOf, ''RackV)
  , (''Enclosure, ''IsRealOf, ''EnclosureV)
  , (''Controller, ''IsRealOf, ''ControllerV)
  , (''Disk, ''IsRealOf, ''DiskV)
    -- Conceptual/hardware relationships between conf entities
  , (''SDev, ''IsOnHardware, ''Disk)
  , (''Node, ''IsOnHardware, ''Controller)
    -- Other things!
  , (''R.Cluster, ''R.Has, ''FidSeq)
  , (''R.Cluster, ''R.Has, ''CI.M0Globals)
  ]
  []
  )
