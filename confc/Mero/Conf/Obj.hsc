{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}

-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Bindings to the confc client library. confc allows programs to
-- get data from the Mero confd service.
--
-- This file provides bindings to the various object types defined in
-- @conf/obj.h@
--
module Mero.Conf.Obj
  ( Obj
  , Root(..)
  , getRoot
  , Profile(..)
  , getProfile
  , Filesystem(..)
  , getFilesystem
  , Pool(..)
  , getPool
  , PVer(..)
  , PVerType(..)
  , getPVer
  , ObjV(..)
  , getObjV
  , RackV(..)
  , EnclV(..)
  , CtrlV(..)
  , DiskV(..)
  , Node(..)
  , getNode
  , Process(..)
  , getProcess
  , Service(..)
  , ServiceParams(..)
  , ServiceType(..)
  , getService
  , Rack(..)
  , getRack
  , Enclosure(..)
  , getEnclosure
  , Controller(..)
  , getController
  , Sdev(..)
  , getSdev
  , Disk(..)
  , getDisk
  , confPVerLvlDisks
  ) where

#include "confc_helpers.h"
#if __GLASGOW_HASKELL__ < 800
#let alignment t = "%lu", (unsigned long)offsetof(struct {char x__; t (y__); }, y__)
#endif

import Mero.Conf.Context
import Mero.Conf.Fid

import Data.Aeson (FromJSON, ToJSON)
import Data.Binary ( Binary )
import Data.Data ( Data )
import Data.Hashable ( Hashable )
import Data.Word ( Word32, Word64 )
import Data.SafeCopy (deriveSafeCopy, base)
import Data.Typeable ( Typeable )
import Foreign.C.String ( CString, peekCString )
import Foreign.C.Types ( CInt(..) )
import Foreign.Marshal.Array ( advancePtr, peekArray )
import Foreign.Ptr ( Ptr, nullPtr, plusPtr )
import Foreign.Storable ( Storable(..) )
import GHC.Generics (Generic)
import System.IO.Unsafe ( unsafePerformIO )

--------------------------------------------------------------------------------
-- Generic Configuration
--------------------------------------------------------------------------------

data {-# CTYPE "conf/obj.h" "struct m0_conf_obj" #-} Obj

--------------------------------------------------------------------------------
-- Conf objects
--------------------------------------------------------------------------------

-- | Representation of @m0_conf_root@.
data Root = Root
  { rt_ptr :: Ptr Obj
  , rt_fid :: Fid
  , rt_verno :: Word64
  } deriving (Show)

getRoot :: Ptr Obj -> IO Root
getRoot po = do
  pr <- confc_cast_root po
  fid <- #{peek struct m0_conf_obj, co_id} po
  vn <- #{peek struct m0_conf_root, rt_verno} pr
  return Root {
    rt_ptr = po
  , rt_fid = fid
  , rt_verno = vn
  }

-- | Representation of @m0_conf_profile@.
data Profile = Profile
    { cp_ptr :: Ptr Obj
    , cp_fid :: Fid
    } deriving (Show)

getProfile :: Ptr Obj -> IO Profile
getProfile po = do
  fid <- #{peek struct m0_conf_obj, co_id} po
  return Profile
    { cp_ptr = po
    , cp_fid = fid
    }

-- | Representation of @m0_conf_filesystem@.
data Filesystem = Filesystem
    { cf_ptr :: Ptr Obj
    , cf_fid      :: Fid
    , cf_rootfid  :: Fid
    , cf_mdpool   :: Fid
    , cf_imeta_pver :: Fid
    , cf_redundancy :: Word32
    , cf_params   :: [String]
    } deriving (Show)

getFilesystem :: Ptr Obj -> IO Filesystem
getFilesystem po = do
  pfs <- confc_cast_filesystem po
  fid <- #{peek struct m0_conf_obj, co_id} po
  rfid <- #{peek struct m0_conf_filesystem, cf_rootfid} pfs
  mdfid <- #{peek struct m0_conf_filesystem, cf_mdpool} pfs
  imetafid <- #{peek struct m0_conf_filesystem, cf_imeta_pver} pfs
  redundancy <- #{peek struct m0_conf_filesystem, cf_redundancy} pfs
  params <- #{peek struct m0_conf_filesystem, cf_params} pfs >>= peekStringArray
  return Filesystem
           { cf_ptr = po
           , cf_fid = fid
           , cf_rootfid = rfid
           , cf_mdpool = mdfid
           , cf_imeta_pver = imetafid
           , cf_redundancy = redundancy
           , cf_params = params
           }

data Pool = Pool {
    pl_ptr   :: Ptr Obj
  , pl_fid   :: Fid
  , pl_pver_policy :: Word32
} deriving (Show)

getPool :: Ptr Obj -> IO Pool
getPool po = do
  pl <- confc_cast_pool po
  fid <- #{peek struct m0_conf_obj, co_id} po
  o <- #{peek struct m0_conf_pool, pl_pver_policy} pl
  return Pool
    { pl_ptr = po
    , pl_fid = fid
    , pl_pver_policy = o
  }

data PVerKind = PVerKindActual
              | PVerKindFormulaic
              | PVerKindVirtual
              deriving (Eq, Show)

instance Enum PVerKind where
  toEnum #{const M0_CONF_PVER_ACTUAL} = PVerKindActual
  toEnum #{const M0_CONF_PVER_FORMULAIC} = PVerKindFormulaic
  toEnum #{const M0_CONF_PVER_VIRTUAL} = PVerKindVirtual
  toEnum i = error $ "PVerKind: unknown kind: " ++ show i

  fromEnum PVerKindActual = #{const M0_CONF_PVER_ACTUAL}
  fromEnum PVerKindFormulaic = #{const M0_CONF_PVER_FORMULAIC}
  fromEnum PVerKindVirtual = #{const M0_CONF_PVER_VIRTUAL}

-- | Stub implementation of pool version object

-- @m0_conf_pver@
data PVer = PVer {
    pv_ptr :: Ptr Obj
  , pv_fid :: Fid
  , pv_type :: PVerType
} deriving (Show)

data PVerType
  = PVerSubtree
    { pvs_attr :: PDClustAttr   -- ^ Layout attributes.
    , pvs_tolerance :: [Word32] -- ^ Allowed failures.
    }
  | PVerFormulaic
    { pvf_id :: Word32          -- ^ Cluster wide unique identifier.
    , pvf_base :: Fid           -- ^ Fid of the base pool version.
    , pvf_allowance :: [Word32] -- ^ Objects failed in this version.
    }
  deriving (Show)

confPVerHeight :: Int
confPVerHeight = #{const M0_CONF_PVER_HEIGHT}

confPVerLvlDisks :: Int
confPVerLvlDisks = #{const M0_CONF_PVER_LVL_DISKS}

getPVer :: Ptr Obj -> IO PVer
getPVer po = do
  pv <- confc_cast_pver po
  fid <- #{peek struct m0_conf_obj, co_id} po
  kind <- #{peek struct m0_conf_pver, pv_kind} pv :: IO CInt
  tp <- if toEnum (fromIntegral kind) == PVerKindFormulaic
        then do
          let formulaic = #{ptr struct m0_conf_pver, pv_u.formulaic} pv
          pvfid <- #{peek struct m0_conf_pver_formulaic, pvf_id} formulaic
          pvfbase <- #{peek struct m0_conf_pver_formulaic, pvf_base} formulaic
          failures <- peekArray confPVerHeight (#{ptr struct m0_conf_pver_formulaic, pvf_allowance} formulaic)
          return PVerFormulaic{pvf_id = pvfid, pvf_base = pvfbase, pvf_allowance = failures}
        else do
          let subtree = #{ptr struct m0_conf_pver, pv_u.subtree} pv
          attr <- #{peek struct m0_conf_pver_subtree, pvs_attr} subtree
          failures <- peekArray confPVerHeight (#{ptr struct m0_conf_pver_subtree, pvs_tolerance} subtree)
          return PVerSubtree{pvs_attr  = attr, pvs_tolerance = failures }
  return PVer { pv_ptr = po, pv_fid = fid, pv_type = tp }

-- @m0_conf_objv@
data ObjV = ObjV
  { cv_ptr :: Ptr Obj
  , cv_fid :: Fid
  , cv_real :: Fid
  } deriving (Show)

-- | Temporary workaround for MERO-1088
foreign import capi "confc_helpers.h cv_real_fid"
  c_cv_real_fid :: Ptr ObjV
                -> IO (Ptr Fid)

getObjV :: Ptr Obj -> IO ObjV
getObjV po = do
  pv <- confc_cast_objv po
  fid <- #{peek struct m0_conf_obj, co_id} po
  real <- c_cv_real_fid pv >>= peek
  return ObjV {
      cv_ptr = po
    , cv_fid = fid
    , cv_real = real
  }

newtype RackV = RackV ObjV
  deriving (Show)
newtype EnclV = EnclV ObjV
  deriving (Show)
newtype CtrlV = CtrlV ObjV
  deriving (Show)
newtype DiskV = DiskV ObjV
  deriving (Show)

-- | Represetation of `m0_conf_node`.
data Node = Node
  { cn_ptr        :: Ptr Obj
  , cn_fid        :: Fid
  , cn_memsize    :: Word32
  , cn_nr_cpu     :: Word32
  , cn_last_state :: Word64
  , cn_flags      :: Word64
  , cn_pool_fid   :: Fid
  } deriving (Show)

-- | Temporary workaround for MERO-1088
foreign import capi "confc_helpers.h cn_pool_fid"
  c_cn_pool_fid :: Ptr Node
                -> IO (Ptr Fid)

getNode :: Ptr Obj -> IO Node
getNode po = do
  pn <- confc_cast_node po
  fid <- #{peek struct m0_conf_obj, co_id} po
  memsize <- #{peek struct m0_conf_node, cn_memsize} pn
  nr_cpu <- #{peek struct m0_conf_node, cn_nr_cpu} pn
  last_state <- #{peek struct m0_conf_node, cn_last_state} pn
  flags <- #{peek struct m0_conf_node, cn_flags} pn
  pool_fid <- c_cn_pool_fid pn >>= peek
  return Node
           { cn_ptr = po
           , cn_fid = fid
           , cn_memsize = memsize
           , cn_nr_cpu = nr_cpu
           , cn_last_state = last_state
           , cn_flags = flags
           , cn_pool_fid = pool_fid
           }

data Process = Process
  { pc_ptr :: Ptr Obj
  , pc_fid :: Fid
  , pc_cores :: Bitmap
  , pc_memlimit_as :: Word64
  , pc_memlimit_rss :: Word64
  , pc_memlimit_stack :: Word64
  , pc_memlimit_memlock :: Word64
  , pc_endpoint :: String
  } deriving Show

getProcess :: Ptr Obj -> IO Process
getProcess po = do
  pp <- confc_cast_process po
  Process <$> (return po)
          <*> (#{peek struct m0_conf_obj, co_id} po)
          <*> (#{peek struct m0_conf_process, pc_cores} pp)
          <*> (#{peek struct m0_conf_process, pc_memlimit_as} pp)
          <*> (#{peek struct m0_conf_process, pc_memlimit_rss} pp)
          <*> (#{peek struct m0_conf_process, pc_memlimit_stack} pp)
          <*> (#{peek struct m0_conf_process, pc_memlimit_memlock} pp)
          <*> (#{peek struct m0_conf_process, pc_endpoint} pp >>= peekCString)

data {-# CTYPE "conf/schema.h" "struct m0_conf_service_type" #-} ServiceType
    = CST_MDS
    | CST_IOS
    | CST_MGS
    | CST_RMS
    | CST_STS
    | CST_HA
    | CST_SSS
    | CST_SNS_REP -- ^ Repair
    | CST_SNS_REB -- ^ Rebalance
    | CST_ADDB2
    | CST_DS1 -- ^ Dummy service 1
    | CST_DS2 -- ^ Dummy service 2
    | CST_CAS -- ^ Catalog service
    | CST_UNKNOWN Int
  deriving (Data, Eq, Generic, Ord, Read, Show )

instance Binary ServiceType
instance Hashable ServiceType
instance FromJSON ServiceType
instance ToJSON ServiceType

instance Enum ServiceType where
  toEnum #{const M0_CST_MDS}      = CST_MDS
  toEnum #{const M0_CST_IOS}      = CST_IOS
  toEnum #{const M0_CST_MGS}      = CST_MGS
  toEnum #{const M0_CST_RMS}      = CST_RMS
  toEnum #{const M0_CST_STS}      = CST_STS
  toEnum #{const M0_CST_HA}       = CST_HA
  toEnum #{const M0_CST_SSS}      = CST_SSS
  toEnum #{const M0_CST_SNS_REP}  = CST_SNS_REP
  toEnum #{const M0_CST_SNS_REB}  = CST_SNS_REB
  toEnum #{const M0_CST_ADDB2}    = CST_ADDB2
  toEnum #{const M0_CST_DS1}      = CST_DS1
  toEnum #{const M0_CST_DS2}      = CST_DS2
  toEnum #{const M0_CST_CAS}      = CST_CAS
  toEnum i                        = CST_UNKNOWN i

  fromEnum CST_MDS          = #{const M0_CST_MDS}
  fromEnum CST_IOS          = #{const M0_CST_IOS}
  fromEnum CST_MGS          = #{const M0_CST_MGS}
  fromEnum CST_RMS          = #{const M0_CST_RMS}
  fromEnum CST_STS          = #{const M0_CST_STS}
  fromEnum CST_HA           = #{const M0_CST_HA}
  fromEnum CST_SSS          = #{const M0_CST_SSS}
  fromEnum CST_SNS_REP      = #{const M0_CST_SNS_REP}
  fromEnum CST_SNS_REB      = #{const M0_CST_SNS_REB}
  fromEnum CST_ADDB2        = #{const M0_CST_ADDB2}
  fromEnum CST_DS1          = #{const M0_CST_DS1}
  fromEnum CST_DS2          = #{const M0_CST_DS2}
  fromEnum CST_CAS          = #{const M0_CST_CAS}
  fromEnum (CST_UNKNOWN i)  = i

data ServiceParams =
      SPRepairLimits !Word32
    | SPADDBStobFid !Fid
    | SPConfDBPath String
    | SPUnused
  deriving (Eq, Show, Generic, Data, Typeable)

instance Binary ServiceParams
instance Hashable ServiceParams
instance FromJSON ServiceParams
instance ToJSON ServiceParams

-- | Representation of `m0_conf_service`.
data Service = Service
  { cs_ptr :: Ptr Obj
  , cs_fid :: Fid
  , cs_type      :: ServiceType
  , cs_endpoints :: [String]
  } deriving Show

getService :: Ptr Obj -> IO Service
getService po = do
  ps <- confc_cast_service po
  fid <- #{peek struct m0_conf_obj, co_id} po
  stype <- fmap (toEnum . fromIntegral)
            $ (#{peek struct m0_conf_service, cs_type} ps :: IO CInt)
  endpoints <- #{peek struct m0_conf_service, cs_endpoints} ps
                    >>= peekStringArray
  return Service
           { cs_ptr = po
           , cs_fid = fid
           , cs_type = stype
           , cs_endpoints = endpoints
           }

data Rack = Rack
  { cr_ptr :: Ptr Obj
  , cr_fid :: Fid
  } deriving Show

getRack :: Ptr Obj -> IO Rack
getRack po =
  Rack <$> (return po)
       <*> (#{peek struct m0_conf_obj, co_id} po)

data Enclosure = Enclosure
  { ce_ptr :: Ptr Obj
  , ce_fid :: Fid
  } deriving Show

getEnclosure :: Ptr Obj -> IO Enclosure
getEnclosure po =
  Enclosure <$> (return po)
            <*> (#{peek struct m0_conf_obj, co_id} po)

data Controller = Controller
  { cc_ptr :: Ptr Obj
  , cc_fid :: Fid
  , cc_node_fid :: Fid
  } deriving Show

-- | Temporary workaround for MERO-1088
foreign import capi "confc_helpers.h cc_node_fid"
  c_cc_node_fid :: Ptr Controller
                -> IO (Ptr Fid)

getController :: Ptr Obj -> IO Controller
getController po =
  Controller <$> (return po)
             <*> (#{peek struct m0_conf_obj, co_id} po)
             <*> (confc_cast_controller po >>= c_cc_node_fid >>= peek)

-- | Representation of `m0_conf_sdev`.
data Sdev = Sdev
  { sd_ptr        :: Ptr Obj
  , sd_fid        :: Fid
  , sd_disk       :: Ptr Fid
  , sd_dev_idx    :: Word32
  , sd_iface      :: Word32
  , sd_media      :: Word32
  , sd_bsize      :: Word32
  , sd_size       :: Word64
  , sd_last_state :: Word64
  , sd_flags      :: Word64
  , sd_filename   :: String
  } deriving Show

getSdev :: Ptr Obj -> IO Sdev
getSdev po = do
  ps <- confc_cast_sdev po
  fid   <- #{peek struct m0_conf_obj, co_id} po
  devidx <- #{peek struct m0_conf_sdev, sd_dev_idx} ps
  mdisk <- #{peek struct m0_conf_sdev, sd_disk} ps
  iface <- #{peek struct m0_conf_sdev, sd_iface} ps
  media <- #{peek struct m0_conf_sdev, sd_media} ps
  bsize <- #{peek struct m0_conf_sdev, sd_bsize} ps
  size <- #{peek struct m0_conf_sdev, sd_size} ps
  last_state <- #{peek struct m0_conf_sdev, sd_last_state} ps
  flags <- #{peek struct m0_conf_sdev, sd_flags} ps
  filename <- #{peek struct m0_conf_sdev, sd_filename} ps >>= peekCString
  return Sdev
           { sd_ptr = po
           , sd_fid = fid
           , sd_dev_idx = devidx
           , sd_disk = mdisk
           , sd_iface = iface
           , sd_media = media
           , sd_bsize = bsize
           , sd_size = size
           , sd_last_state = last_state
           , sd_flags = flags
           , sd_filename = filename
           }

-- | Temporary workaround for MERO-1094
foreign import capi "confc_helpers.h ck_sdev_fid"
  c_ck_sdev_fid :: Ptr Disk
                -> IO (Ptr Fid)

data Disk = Disk
  { ck_ptr :: Ptr Obj
  , ck_fid :: Fid
  , ck_dev :: Fid
  } deriving Show

getDisk :: Ptr Obj -> IO Disk
getDisk po =
  Disk <$> (return po)
       <*> (#{peek struct m0_conf_obj, co_id} po)
       <*> (confc_cast_disk po >>= c_ck_sdev_fid >>= peek)

--------------------------------------------------------------------------------
-- Casting helpers
--------------------------------------------------------------------------------

foreign import capi unsafe "confc_helpers.h confc_cast_root"
  confc_cast_root :: Ptr Obj -> IO (Ptr Root)
-- foreign import capi unsafe confc_cast_profile :: Ptr Obj
--                                                -> IO (Ptr Profile)
foreign import capi unsafe "confc_helpers.h confc_cast_sdev"
  confc_cast_sdev :: Ptr Obj -> IO (Ptr Service)

foreign import capi unsafe "confc_helpers.h confc_cast_service"
  confc_cast_service :: Ptr Obj -> IO (Ptr Service)

foreign import capi unsafe "confc_helpers.h confc_cast_node"
  confc_cast_node :: Ptr Obj -> IO (Ptr Node)

foreign import capi unsafe "confc_helpers.h confc_cast_pool"
  confc_cast_pool :: Ptr Obj -> IO (Ptr Pool)

foreign import capi unsafe "confc_helpers.h confc_cast_pver"
  confc_cast_pver :: Ptr Obj -> IO (Ptr PVer)

foreign import capi unsafe "confc_helpers.h confc_cast_objv"
  confc_cast_objv :: Ptr Obj -> IO (Ptr ObjV)

foreign import capi unsafe "confc_helpers.h confc_cast_filesystem"
  confc_cast_filesystem :: Ptr Obj -> IO (Ptr Filesystem)

foreign import capi unsafe "confc_helpers.h confc_cast_disk"
  confc_cast_disk :: Ptr Obj -> IO (Ptr Disk)

foreign import capi unsafe "confc_helpers.h confc_cast_process"
  confc_cast_process :: Ptr Obj -> IO (Ptr Process)
-- foreign import capi unsafe confc_cast_rack :: Ptr Obj
--                                             -> IO (Ptr Rack)
-- foreign import capi unsafe confc_cast_enclosure :: Ptr Obj
--                                                  -> IO (Ptr Enclosure)
foreign import capi unsafe "confc_helpers.h confc_cast_controller"
  confc_cast_controller :: Ptr Obj -> IO (Ptr Controller)

--------------------------------------------------------------------------------
-- Utility
--------------------------------------------------------------------------------

peekStringArray :: Ptr CString -> IO [String]
peekStringArray p = mapM peekCString
                  $ takeWhile (/=nullPtr)
                  $ map (unsafePerformIO . peek)
                  $ iterate (`advancePtr` 1) p

deriveSafeCopy 0 'base ''ServiceType
deriveSafeCopy 0 'base ''ServiceParams
