{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE MultiWayIf #-}
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
  , getPVer
  , PVerState(..)
  , pvs_online
  , pvs_failed
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
  ) where

#include "confc_helpers.h"
#let alignment t = "%lu", (unsigned long)offsetof(struct {char x__; t (y__);}, y__)

import Mero.Conf.Fid

import Data.Word ( Word32, Word64 )
import Foreign.C.String ( CString, peekCString )
import Foreign.C.Types ( CInt(..) )
import Foreign.Marshal.Array ( advancePtr, peekArray )
import Foreign.Ptr ( Ptr, nullPtr, plusPtr )
import Foreign.Storable ( Storable(..) )
import System.IO.Unsafe ( unsafePerformIO )

--------------------------------------------------------------------------------
-- Generic Configuration
--------------------------------------------------------------------------------

data Obj

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
    , cf_redundancy :: Word32
    , cf_params   :: [String]
    } deriving (Show)

getFilesystem :: Ptr Obj -> IO Filesystem
getFilesystem po = do
  pfs <- confc_cast_filesystem po
  fid <- #{peek struct m0_conf_obj, co_id} po
  rfid <- #{peek struct m0_conf_filesystem, cf_rootfid} pfs
  redundancy <- #{peek struct m0_conf_filesystem, cf_redundancy} pfs
  params <- #{peek struct m0_conf_filesystem, cf_params} pfs >>= peekStringArray
  return Filesystem
           { cf_ptr = po
           , cf_fid = fid
           , cf_rootfid = rfid
           , cf_redundancy = redundancy
           , cf_params = params
           }

data Pool = Pool {
    pl_ptr   :: Ptr Obj
  , pl_fid   :: Fid
  , pl_order :: Word32
} deriving (Show)

getPool :: Ptr Obj -> IO Pool
getPool po = do
  pl <- confc_cast_pool po
  fid <- #{peek struct m0_conf_obj, co_id} po
  o <- #{peek struct m0_conf_pool, pl_order} pl
  return Pool
    { pl_ptr = po
    , pl_fid = fid
    , pl_order = o
  }

-- | Stub implementation of pool version object

-- | m0_service_health
newtype PVerState = PVerState CInt
  deriving (Show)
#{enum PVerState, PVerState,
    pvs_online = M0_CONF_PVER_ONLINE
  , pvs_failed = M0_CONF_PVER_FAILED
 }

-- @m0_conf_pver@
data PVer = PVer {
    pv_ptr :: Ptr Obj
  , pv_fid :: Fid
  , pv_ver :: Word32
  , pv_state :: PVerState
  , pv_permutations :: [Word32]
  , pv_failures :: [Word32]
} deriving (Show)

getPVer :: Ptr Obj -> IO PVer
getPVer po = do
  pv <- confc_cast_pver po
  fid <- #{peek struct m0_conf_obj, co_id} po
  ver <- #{peek struct m0_conf_pver, pv_ver} pv
  state <- fmap PVerState $ #{peek struct m0_conf_pver, pv_state} pv
  permutations_ptr <- #{peek struct m0_conf_pver, pv_permutations} pv
  permutations_nr <- #{peek struct m0_conf_pver, pv_permutations_nr} pv
  permutations <- peekArray permutations_nr permutations_ptr
  failures_ptr <- #{peek struct m0_conf_pver, pv_nr_failures} pv
  failures_nr <- #{peek struct m0_conf_pver, pv_nr_failures_nr} pv
  failures <- peekArray failures_nr failures_ptr
  return PVer
    { pv_ptr = po
    , pv_fid = fid
    , pv_ver = ver
    , pv_state = state
    , pv_permutations = permutations
    , pv_failures = failures
    }

-- @m0_conf_objv@
data ObjV = ObjV
  { cv_ptr :: Ptr Obj
  , cv_fid :: Fid
  , cv_real :: Ptr Obj
  } deriving (Show)

getObjV :: Ptr Obj -> IO ObjV
getObjV po = do
  pv <- confc_cast_objv po
  fid <- #{peek struct m0_conf_obj, co_id} po
  return ObjV {
      cv_ptr = po
    , cv_fid = fid
    , cv_real = #{ptr struct m0_conf_objv, cv_real} pv
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
  } deriving (Show)

getNode :: Ptr Obj -> IO Node
getNode po = do
  pn <- confc_cast_node po
  fid <- #{peek struct m0_conf_obj, co_id} po
  memsize <- #{peek struct m0_conf_node, cn_memsize} pn
  nr_cpu <- #{peek struct m0_conf_node, cn_nr_cpu} pn
  last_state <- #{peek struct m0_conf_node, cn_last_state} pn
  flags <- #{peek struct m0_conf_node, cn_flags} pn
  return Node
           { cn_ptr = po
           , cn_fid = fid
           , cn_memsize = memsize
           , cn_nr_cpu = nr_cpu
           , cn_last_state = last_state
           , cn_flags = flags
           }

data Process = Process
  { pc_ptr :: Ptr Obj
  , pc_fid :: Fid
  , pc_memlimit_as :: Word64
  , pc_memlimit_rss :: Word64
  , pc_memlimit_stack :: Word64
  , pc_memlimit_memlock :: Word64
  } deriving Show

getProcess :: Ptr Obj -> IO Process
getProcess po = do
  pp <- confc_cast_process po
  Process <$> (return po)
          <*> (#{peek struct m0_conf_obj, co_id} po)
          <*> (#{peek struct m0_conf_process, pc_memlimit_as} pp)
          <*> (#{peek struct m0_conf_process, pc_memlimit_rss} pp)
          <*> (#{peek struct m0_conf_process, pc_memlimit_stack} pp)
          <*> (#{peek struct m0_conf_process, pc_memlimit_memlock} pp)

-- | Representation of `m0_conf_service_type`.
data ServiceType
    = CST_MDS
    | CST_IOS
    | CST_MGS
    | CST_RMS
    | CST_STS
    | CST_HA
    | CST_SSS
    | CST_UNKNOWN Int
  deriving (Show,Read,Ord,Eq)

instance Enum ServiceType where

  toEnum #{const M0_CST_MDS} = CST_MDS
  toEnum #{const M0_CST_IOS} = CST_IOS
  toEnum #{const M0_CST_MGS} = CST_MGS
  toEnum #{const M0_CST_RMS} = CST_RMS
  toEnum #{const M0_CST_STS} = CST_STS
  toEnum #{const M0_CST_HA}  = CST_HA
  toEnum #{const M0_CST_SSS} = CST_SSS
  toEnum i                   = CST_UNKNOWN i

  fromEnum CST_MDS         = #{const M0_CST_MDS}
  fromEnum CST_IOS         = #{const M0_CST_IOS}
  fromEnum CST_MGS         = #{const M0_CST_MGS}
  fromEnum CST_RMS         = #{const M0_CST_RMS}
  fromEnum CST_STS         = #{const M0_CST_STS}
  fromEnum CST_HA          = #{const M0_CST_HA}
  fromEnum CST_SSS         = #{const M0_CST_SSS}
  fromEnum (CST_UNKNOWN i) = i

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
  stype <- #{peek struct m0_conf_service, cs_type} ps
  endpoints <- #{peek struct m0_conf_service, cs_endpoints} ps
                    >>= peekStringArray
  return Service
           { cs_ptr = po
           , cs_fid = fid
           , cs_type = toEnum $ fromIntegral (stype :: CInt)
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
  } deriving Show

getController :: Ptr Obj -> IO Controller
getController po =
  Controller <$> (return po)
             <*> (#{peek struct m0_conf_obj, co_id} po)

-- | Representation of `m0_conf_sdev`.
data Sdev = Sdev
  { sd_ptr        :: Ptr Obj
  , sd_fid        :: Fid
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
  fid <- #{peek struct m0_conf_obj, co_id} po
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
           , sd_iface = iface
           , sd_media = media
           , sd_bsize = bsize
           , sd_size = size
           , sd_last_state = last_state
           , sd_flags = flags
           , sd_filename = filename
           }

data Disk = Disk
  { ck_ptr :: Ptr Obj
  , ck_fid :: Fid
  } deriving Show

getDisk :: Ptr Obj -> IO Disk
getDisk po = Disk <$> (return po) <*> (#{peek struct m0_conf_obj, co_id} po)

--------------------------------------------------------------------------------
-- Casting helpers
--------------------------------------------------------------------------------

foreign import ccall unsafe confc_cast_root :: Ptr Obj
                                            -> IO (Ptr Root)
-- foreign import ccall unsafe confc_cast_profile :: Ptr Obj
--                                                -> IO (Ptr Profile)
foreign import ccall unsafe confc_cast_sdev :: Ptr Obj
                                            -> IO (Ptr Service)
foreign import ccall unsafe confc_cast_service :: Ptr Obj
                                               -> IO (Ptr Service)
foreign import ccall unsafe confc_cast_node :: Ptr Obj
                                            -> IO (Ptr Service)
foreign import ccall unsafe confc_cast_pool :: Ptr Obj
                                            -> IO (Ptr Pool)
foreign import ccall unsafe confc_cast_pver :: Ptr Obj
                                            -> IO (Ptr PVer)
foreign import ccall unsafe confc_cast_objv :: Ptr Obj
                                            -> IO (Ptr ObjV)
foreign import ccall unsafe confc_cast_filesystem :: Ptr Obj
                                                  -> IO (Ptr Filesystem)
-- foreign import ccall unsafe confc_cast_disk :: Ptr Obj
--                                             -> IO (Ptr Disk)
foreign import ccall unsafe confc_cast_process :: Ptr Obj
                                               -> IO (Ptr Process)
-- foreign import ccall unsafe confc_cast_rack :: Ptr Obj
--                                             -> IO (Ptr Rack)
-- foreign import ccall unsafe confc_cast_enclosure :: Ptr Obj
--                                                  -> IO (Ptr Enclosure)
-- foreign import ccall unsafe confc_cast_controller :: Ptr Obj
--                                                   -> IO (Ptr Controller)

--------------------------------------------------------------------------------
-- Utility
--------------------------------------------------------------------------------

peekStringArray :: Ptr CString -> IO [String]
peekStringArray p = mapM peekCString
                  $ takeWhile (/=nullPtr)
                  $ map (unsafePerformIO . peek)
                  $ iterate (`advancePtr` 1) p
