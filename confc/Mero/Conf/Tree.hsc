{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ViewPatterns #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Bindings to the confc client library. confc allows programs to
-- get data from the Mero confd service.
--
-- The configuration data are organized in a tree. Fetching the children
-- of a node involve IO operations which consume resources that must be
-- released explicitly. Whenever an operation requires subsequently
-- releasing resources the close operation is provided together with the
-- result of the operation (see 'WithClose').
--
module Mero.Conf.Tree
  ( children
  , withRoot
  ) where

#include "confc_helpers.h"

import Mero.Conf.Obj
import Mero.Conf.Internal

import Network.RPC.RPCLite
  ( RPCAddress(..)
  , RPCMachine(..)
  )

import Foreign.Ptr ( Ptr )
import Foreign.Storable ( Storable(..) )

class Children a b where
  -- | Find children objects in the configuration tree.
  children :: a -> IO [b]

instance Children Root Profile where
  children rt = walkChildren (rt_ptr rt) m0_ROOT_PROFILES_FID $ \case
    CPf a -> Just a
    _ -> Nothing

instance Children Profile Filesystem where
  children prof = walkChildren (cp_ptr prof) m0_PROFILE_FS_FID $ \case
    CF a -> Just a
    _ -> Nothing

instance Children Filesystem Node where
  children obj = walkChildren (cf_ptr obj) m0_FS_NODES_FID $ \case
    CN a -> Just a
    _ -> Nothing

instance Children Filesystem Pool where
  children obj = walkChildren (cf_ptr obj) m0_FS_POOLS_FID $ \case
    CPl a -> Just a
    _ -> Nothing

instance Children Filesystem Rack where
  children obj = walkChildren (cf_ptr obj) m0_FS_RACKS_FID $ \case
    CRa a -> Just a
    _ -> Nothing

instance Children Pool PVer where
  children obj = walkChildren (pl_ptr obj) m0_POOL_PVERS_FID $ \case
    CPv a -> Just a
    _ -> Nothing

instance Children PVer RackV where
  children obj = walkChildren (pv_ptr obj) m0_PVER_RACKVS_FID $ \case
    CO a -> Just (RackV a)
    _ -> Nothing

instance Children RackV EnclV where
  children (RackV obj) = walkChildren (cv_ptr obj) m0_RACKV_ENCLVS_FID $ \case
    CO a -> Just (EnclV a)
    _ -> Nothing

instance Children EnclV CtrlV where
  children (EnclV obj) = walkChildren (cv_ptr obj) m0_ENCLV_CTRLVS_FID $ \case
    CO a -> Just (CtrlV a)
    _ -> Nothing

instance Children CtrlV DiskV where
  children (CtrlV obj) = walkChildren (cv_ptr obj) m0_CTRLV_DISKVS_FID $ \case
    CO a -> Just (DiskV a)
    _ -> Nothing

instance Children Node Process where
  children obj = walkChildren (cn_ptr obj) m0_NODE_PROCESSES_FID $ \case
    CPr a -> Just a
    _ -> Nothing

instance Children Process Service where
  children obj = walkChildren (pc_ptr obj) m0_PROCESS_SERVICES_FID $ \case
    CS a -> Just a
    _ -> Nothing

instance Children Service Sdev where
  children obj = walkChildren (cs_ptr obj) m0_SERVICE_SDEVS_FID $ \case
    CSd a -> Just a
    _ -> Nothing

instance Children Rack Enclosure where
  children obj = walkChildren (cr_ptr obj) m0_RACK_ENCLS_FID $ \case
    CE a -> Just a
    _ -> Nothing

instance Children Enclosure Controller where
  children obj = walkChildren (ce_ptr obj) m0_ENCLOSURE_CTRLS_FID $ \case
    CC a -> Just a
    _ -> Nothing

instance Children Controller Disk where
  children obj = walkChildren (cc_ptr obj) m0_CONTROLLER_DISKS_FID $ \case
    CDsk a -> Just a
    _ -> Nothing

instance Children Disk Sdev where
  children obj = walkChildren (ck_ptr obj) m0_DISK_SDEV_FID $ \case
    CSd a -> Just a
    _ -> Nothing

-- | Open a root configuration object. When this root is closed,
--   it is no longer valid to explore confc.
withRoot :: RPCMachine
         -> RPCAddress
         -> (Root -> IO a)
         -> IO a
withRoot rpcmach rpcaddr f = do
  appendFile "/tmp/log" "withRoot 1\n"
  fid <- peek rootFid
  appendFile "/tmp/log" "withRoot 2\n"
  withClose (openRoot rpcmach rpcaddr fid) $ \co -> case co_union co of
    CRo r -> appendFile "/tmp/log" "withRoot 3 CRo\n" >> f r
    _ -> appendFile "/tmp/log" "withRoot 3 _\n" >> error "Cannot open root element at root FID."

walkChildren :: Ptr Obj
             -> RelationFid
             -> (ConfObjUnion -> Maybe a)
             -> IO [a]
walkChildren po rfid match = do
    withClose (getChild po rfid) $ \co -> case co_union co of
      CDr dir -> withClose (cd_iterator dir) (go [])
        where
          go acc it = ci_next it >>= \case
            Nothing -> return acc
            Just co' -> case match (co_union co') of
              Just p -> go (p : acc) it
              Nothing -> error $ "Invalid object returned from directory:\n"
                                  ++ show (co_union co')
      o -> case match o of
              Just p -> return [p]
              Nothing -> error $ "Invalid object returned from conf tree:\n"
                                  ++ show o

--------------------------------------------------------------------------------
-- Relation FIDs
--------------------------------------------------------------------------------

foreign import ccall unsafe "&M0_CONF_ROOT_PROFILES_FID"
                            m0_ROOT_PROFILES_FID :: RelationFid
foreign import ccall unsafe "&M0_CONF_PROFILE_FILESYSTEM_FID"
                            m0_PROFILE_FS_FID :: RelationFid
foreign import ccall unsafe "&M0_CONF_FILESYSTEM_NODES_FID"
                            m0_FS_NODES_FID :: RelationFid
foreign import ccall unsafe "&M0_CONF_FILESYSTEM_POOLS_FID"
                            m0_FS_POOLS_FID :: RelationFid
foreign import ccall unsafe "&M0_CONF_FILESYSTEM_RACKS_FID"
                            m0_FS_RACKS_FID :: RelationFid
foreign import ccall unsafe "&M0_CONF_POOL_PVERS_FID"
                            m0_POOL_PVERS_FID :: RelationFid
foreign import ccall unsafe "&M0_CONF_PVER_RACKVS_FID"
                            m0_PVER_RACKVS_FID :: RelationFid
foreign import ccall unsafe "&M0_CONF_RACKV_ENCLVS_FID"
                            m0_RACKV_ENCLVS_FID :: RelationFid
foreign import ccall unsafe "&M0_CONF_ENCLV_CTRLVS_FID"
                            m0_ENCLV_CTRLVS_FID :: RelationFid
foreign import ccall unsafe "&M0_CONF_CTRLV_DISKVS_FID"
                            m0_CTRLV_DISKVS_FID :: RelationFid
foreign import ccall unsafe "&M0_CONF_NODE_PROCESSES_FID"
                            m0_NODE_PROCESSES_FID :: RelationFid
foreign import ccall unsafe "&M0_CONF_PROCESS_SERVICES_FID"
                            m0_PROCESS_SERVICES_FID :: RelationFid
foreign import ccall unsafe "&M0_CONF_SERVICE_SDEVS_FID"
                            m0_SERVICE_SDEVS_FID :: RelationFid
foreign import ccall unsafe "&M0_CONF_RACK_ENCLS_FID"
                            m0_RACK_ENCLS_FID :: RelationFid
foreign import ccall unsafe "&M0_CONF_ENCLOSURE_CTRLS_FID"
                            m0_ENCLOSURE_CTRLS_FID :: RelationFid
foreign import ccall unsafe "&M0_CONF_CONTROLLER_DISKS_FID"
                            m0_CONTROLLER_DISKS_FID :: RelationFid
foreign import ccall unsafe "&M0_CONF_DISK_SDEV_FID"
                            m0_DISK_SDEV_FID :: RelationFid
