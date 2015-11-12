{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Bindings to the spiel interface.
--

module Mero.Spiel.Internal
  ( module Mero.Spiel.Internal
  , RunningService
  ) where

import Mero.Conf.Fid ( Fid )
import Mero.Conf.Context
import Mero.Spiel.Context

import Network.RPC.RPCLite
  ( RPCMachine(..) )

import Data.Word ( Word32, Word64 )

import Foreign.C.String
  ( CString )
import Foreign.C.Types
import Foreign.Marshal.Error
  ( throwIf_ )
import Foreign.Ptr
  ( Ptr )
import Foreign.Storable

-- import qualified Language.C.Inline as C

import System.IO.Unsafe (unsafePerformIO)

#include "spiel/spiel.h"
#include "rpc/rpc_machine.h"

#let alignment t = "%lu", (unsigned long)offsetof(struct {char x__; t (y__);}, y__)

-- | m0_reqh
data {-# CTYPE "rpc/rpc_machine.h" "struct m0_reqh" #-} ReqHV

-- | Extract the request handler from RPC machine
rm_reqh :: RPCMachine -> Ptr ReqHV
rm_reqh (RPCMachine rpcmach) = unsafePerformIO $
  #{peek struct m0_rpc_machine, rm_reqh} rpcmach

-- | m0_spiel
data {-# CTYPE "spiel/spiel.h" "struct m0_spiel" #-} SpielContextV

-- | Size of m0_spiel struct for allocation
m0_spiel_size :: Int
m0_spiel_size = #{size struct m0_spiel}

-- XXX FIXME: ccall/capi const
foreign import ccall "spiel/spiel.h m0_spiel_start"
  c_spiel_start :: Ptr SpielContextV
                -> Ptr ReqHV
                -> Ptr CString
                -> CString
                -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_stop"
  c_spiel_stop :: Ptr SpielContextV
               -> IO ()

---------------------------------------------------------------
-- Transactions                                              --
---------------------------------------------------------------

-- | m0_spiel_tx
data {-# CTYPE "spiel/spiel.h" "struct m0_spiel_tx" #-} SpielTransactionV

-- | Size of m0_spiel_tx struct for allocation
m0_spiel_tx_size :: Int
m0_spiel_tx_size = #{size struct m0_spiel_tx}

foreign import capi "spiel/spiel.h m0_spiel_tx_open"
  c_spiel_tx_open :: Ptr SpielContextV
                  -> Ptr SpielTransactionV
                  -> IO ()

foreign import capi "spiel/spiel.h m0_spiel_tx_close"
  c_spiel_tx_close :: Ptr SpielTransactionV
                   -> IO ()

foreign import capi "spiel/spiel.h m0_spiel_tx_commit"
  c_spiel_tx_commit :: Ptr SpielTransactionV
                    -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_tx_commit_forced"
  c_spiel_tx_commit_forced :: Ptr SpielTransactionV
                           -> Bool -- ^ Forced - used as bool
                           -> Word64 -- ^ ver_forced
                           -> Ptr Word32 -- ^ Quorum
                           -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_tx_validate"
  c_spiel_tx_validate :: Ptr SpielTransactionV
                      -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_tx_dump"
  c_spiel_tx_dump :: Ptr SpielTransactionV
                  -> CString
                  -> IO CInt

---------------------------------------------------------------
-- Configuration management                                  --
---------------------------------------------------------------

foreign import capi "spiel/spiel.h m0_spiel_profile_add"
  c_spiel_profile_add :: Ptr SpielTransactionV
                      -> Ptr Fid
                      -> IO CInt

-- XXX FIXME: ccall/capi const
foreign import ccall "spiel/spiel.h m0_spiel_filesystem_add"
  c_spiel_filesystem_add :: Ptr SpielTransactionV
                         -> Ptr Fid -- ^ fid of the filesystem
                         -> Ptr Fid -- ^ fid of the parent profile
                         -> CUInt   -- ^ metadata redundancy count
                         -> Ptr Fid -- ^ root's fid of filesystem
                         -> Ptr Fid -- ^ metadata pool
                         -> Ptr (Ptr CChar) -- ^ NULL-terminated array of command-line like parameters
                         -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_node_add"
  c_spiel_node_add :: Ptr SpielTransactionV
                   -> Ptr Fid -- ^ fid of the filesystem
                   -> Ptr Fid -- ^ fid of the parent profile
                   -> Word32
                   -> Word32
                   -> Word64
                   -> Word64
                   -> Ptr Fid -- ^ Pool fid
                   -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_process_add"
  c_spiel_process_add :: Ptr SpielTransactionV
                      -> Ptr Fid -- ^ fid of the filesystem
                      -> Ptr Fid -- ^ fid of the parent profile
                      -> Ptr Bitmap
                      -> Word64
                      -> Word64
                      -> Word64
                      -> Word64
                      -> CString -- ^ Process endpoint
                      -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_service_add"
  c_spiel_service_add :: Ptr SpielTransactionV
                      -> Ptr Fid -- ^ fid of the filesystem
                      -> Ptr Fid -- ^ fid of the parent profile
                      -> Ptr ServiceInfo
                      -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_device_add"
  c_spiel_device_add :: Ptr SpielTransactionV
                     -> Ptr Fid -- ^ fid of the filesystem
                     -> Ptr Fid -- ^ fid of the parent service
                     -> Ptr Fid -- ^ fid of the parent disk
                     -> CInt -- ^ StorageDeviceInterfaceType
                     -> CInt -- ^ StorageDeviceMediaType
                     -> Word32
                     -> Word64
                     -> Word64
                     -> Word64
                     -> CString
                     -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_pool_add"
  c_spiel_pool_add :: Ptr SpielTransactionV
                   -> Ptr Fid -- ^ fid of the pool
                   -> Ptr Fid -- ^ fid of the parent filesystem
                   -> Word32  -- ^ pool order
                   -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_rack_add"
  c_spiel_rack_add :: Ptr SpielTransactionV
                   -> Ptr Fid -- ^ fid of the rack
                   -> Ptr Fid -- ^ fid of the parent filesystem
                   -> IO CInt


foreign import capi "spiel/spiel.h m0_spiel_enclosure_add"
  c_spiel_enclosure_add :: Ptr SpielTransactionV
                        -> Ptr Fid -- ^ fid of the enclosure
                        -> Ptr Fid -- ^ fid of the parent rack
                        -> IO CInt


foreign import capi "spiel/spiel.h m0_spiel_pool_version_add"
  c_spiel_pool_version_add :: Ptr SpielTransactionV
                           -> Ptr Fid -- ^ fid of the pver
                           -> Ptr Fid -- ^ fid of the parent pool
                           -> Ptr Word32 -- ^ nr_failures
                           -> Word32 -- ^ nr_failures_cnt
                           -> Ptr PDClustAttr
                           -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_rack_v_add"
  c_spiel_rack_v_add :: Ptr SpielTransactionV
                     -> Ptr Fid -- ^ fid of the filesystem
                     -> Ptr Fid -- ^ fid of the parent profile
                     -> Ptr Fid -- ^ Node
                     -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_enclosure_v_add"
  c_spiel_enclosure_v_add :: Ptr SpielTransactionV
                          -> Ptr Fid -- ^ fid of the filesystem
                          -> Ptr Fid -- ^ fid of the parent profile
                          -> Ptr Fid -- ^ Node
                          -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_controller_v_add"
  c_spiel_controller_v_add :: Ptr SpielTransactionV
                           -> Ptr Fid -- ^ fid of the filesystem
                           -> Ptr Fid -- ^ fid of the parent profile
                           -> Ptr Fid -- ^ Node
                           -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_disk_v_add"
  c_spiel_disk_v_add :: Ptr SpielTransactionV
                     -> Ptr Fid -- ^ fid of the disk_v
                     -> Ptr Fid -- ^ fid of the parent controller_v
                     -> Ptr Fid -- ^ Real
                     -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_pool_version_done"
  c_spiel_pool_version_done :: Ptr SpielTransactionV
                            -> Ptr Fid -- ^ fid of the filesystem
                            -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_controller_add"
  c_spiel_controller_add :: Ptr SpielTransactionV
                         -> Ptr Fid -- ^ fid of the filesystem
                         -> Ptr Fid -- ^ fid of the parent profile
                         -> Ptr Fid -- ^ Node
                         -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_disk_add"
  c_spiel_disk_add :: Ptr SpielTransactionV
                   -> Ptr Fid -- ^ fid of the filesystem
                   -> Ptr Fid -- ^ fid of the parent profile
                   -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_element_del"
  c_spiel_element_del :: Ptr SpielTransactionV
                      -> Ptr Fid -- ^ fid of the filesystem
                      -> IO CInt

---------------------------------------------------------------
-- Command interface                                         --
---------------------------------------------------------------

-- | m0_service_health
newtype ServiceHealth = ServiceHealth CInt
#{enum ServiceHealth, ServiceHealth,
    _sh_good = M0_HEALTH_GOOD
  , _sh_bad = M0_HEALTH_BAD
  , _sh_inactive = M0_HEALTH_INACTIVE
  , _sh_unknown = M0_HEALTH_UNKNOWN
 }

foreign import capi "spiel/spiel.h m0_spiel_service_init"
  c_spiel_service_init :: Ptr SpielContextV
                       -> Ptr Fid
                       -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_service_start"
  c_spiel_service_start :: Ptr SpielContextV
                        -> Ptr Fid
                        -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_service_stop"
  c_spiel_service_stop :: Ptr SpielContextV
                       -> Ptr Fid
                       -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_service_health"
  c_spiel_service_health :: Ptr SpielContextV
                         -> Ptr Fid
                         -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_service_quiesce"
  c_spiel_service_quiesce :: Ptr SpielContextV
                          -> Ptr Fid
                          -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_device_attach"
  c_spiel_device_attach :: Ptr SpielContextV
                        -> Ptr Fid
                        -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_device_detach"
  c_spiel_device_detach :: Ptr SpielContextV
                        -> Ptr Fid
                        -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_device_format"
  c_spiel_device_format :: Ptr SpielContextV
                        -> Ptr Fid
                        -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_process_stop"
  c_spiel_process_stop :: Ptr SpielContextV
                       -> Ptr Fid
                       -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_process_reconfig"
  c_spiel_process_reconfig :: Ptr SpielContextV
                           -> Ptr Fid
                           -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_process_health"
  c_spiel_process_health :: Ptr SpielContextV
                         -> Ptr Fid
                         -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_process_quiesce"
  c_spiel_process_quiesce :: Ptr SpielContextV
                          -> Ptr Fid
                          -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_process_list_services"
  c_spiel_process_list_services :: Ptr SpielContextV
                                -> Ptr Fid
                                -> Ptr (Ptr RunningService)
                                -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_pool_repair_start"
  c_spiel_pool_repair_start :: Ptr SpielContextV
                            -> Ptr Fid
                            -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_pool_repair_quiesce"
  c_spiel_pool_repair_quiesce :: Ptr SpielContextV
                              -> Ptr Fid
                              -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_pool_rebalance_start"
  c_spiel_pool_rebalance_start :: Ptr SpielContextV
                               -> Ptr Fid
                               -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_pool_rebalance_quiesce"
  c_spiel_pool_rebalance_quiesce :: Ptr SpielContextV
                                 -> Ptr Fid
                                 -> IO CInt

---------------------------------------------------------------
-- Utility                                                   --
---------------------------------------------------------------

-- C.context $ C.baseCtx <> confCtx <> spielCtx

-- C.include "lib/memory.h"
-- C.include "spiel/spiel.h"

-- freeRunningServices :: Ptr RunningService -- ^ Pointer to head of array
--                     -> IO CInt
-- freeRunningServices arr = [C.block| int {
--     struct m0_spiel_running_svc *arr = $(struct m0_spiel_running_svc *arr);
--     m0_free(arr);
--   }
-- |]

throwIfNonZero_ :: (Eq a, Num a) => (a -> String) -> IO a -> IO ()
throwIfNonZero_ = throwIf_ (/= 0)
