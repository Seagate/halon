{-# LANGUAGE CApiFFI                  #-}
{-# LANGUAGE EmptyDataDecls           #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE QuasiQuotes              #-}
{-# LANGUAGE TemplateHaskell          #-}

-- |
-- Copyright : (C) 2018 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Bindings to the spiel interface.
--

module Mero.Spiel.Internal
  ( SpielTransactionV
  , c_confc_validate_cache_of_tx
  , c_spiel
  , c_spiel_cmd_profile_set
  , c_spiel_profile_add
  , c_spiel_filesystem_add

  , c_spiel_node_add
  , c_spiel_process_add
  , c_spiel_service_add
  , c_spiel_device_add

  , c_spiel_rack_add
  , c_spiel_enclosure_add
  , c_spiel_controller_add
  , c_spiel_disk_add

  , c_spiel_pool_add
  , c_spiel_pver_actual_add
  , c_spiel_pver_formulaic_add
  , c_spiel_rack_v_add
  , c_spiel_enclosure_v_add
  , c_spiel_controller_v_add
  , c_spiel_disk_v_add
  , c_spiel_pool_version_done

  , c_spiel_device_attach
  , c_spiel_device_detach
  , c_spiel_filesystem_stats_fetch
  , c_spiel_rconfc_start
  , c_spiel_rconfc_stop
  , c_spiel_pool_repair_start
  , c_spiel_pool_repair_continue
  , c_spiel_pool_repair_quiesce
  , c_spiel_pool_repair_status
  , c_spiel_pool_repair_abort
  , c_spiel_pool_rebalance_start
  , c_spiel_pool_rebalance_continue
  , c_spiel_pool_rebalance_quiesce
  , c_spiel_pool_rebalance_status
  , c_spiel_pool_rebalance_abort
  , c_spiel_tx_close
  , c_spiel_tx_commit_forced
  , c_spiel_tx_open
  , c_spiel_tx_str_free
  , c_spiel_tx_to_str
  , c_spiel_tx_validate
  , m0_spiel_size
  , m0_spiel_tx_size
  ) where

import Mero.ConfC (Bitmap, Fid, PDClustAttr)
import Mero.Spiel.Context (FSStats, ServiceInfo, SnsStatus)

import Data.Word (Word32, Word64)

import Foreign.C.String (CString)
import Foreign.C.Types (CChar, CInt(..), CUInt(..), CSize(..))
import Foreign.Ptr (Ptr)

#include "confc_helpers.h"
#include "spiel/spiel.h"

-- | m0_spiel
data {-# CTYPE "spiel/spiel.h" "struct m0_spiel" #-} SpielContextV

-- | Size of m0_spiel struct for allocation
m0_spiel_size :: Int
m0_spiel_size = #{size struct m0_spiel}

-- Start spiel instance
foreign import ccall "spiel/spiel.h m0_spiel_rconfc_start"
  c_spiel_rconfc_start :: Ptr SpielContextV
                       -> Ptr () -- XXX: really this should be pointer to function
                                 -- that will have configuration client info
                       -> IO CInt

-- Stop spiel instance
foreign import capi "spiel/spiel.h m0_spiel_rconfc_stop"
  c_spiel_rconfc_stop :: Ptr SpielContextV
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

foreign import capi "spiel/spiel.h m0_spiel_tx_commit_forced"
  c_spiel_tx_commit_forced :: Ptr SpielTransactionV
                           -> Bool       -- ^ forced
                           -> Word64     -- ^ ver_forced
                           -> Ptr Word32 -- ^ rquorum
                           -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_tx_validate"
  c_spiel_tx_validate :: Ptr SpielTransactionV
                      -> IO CInt

foreign import ccall "spiel/spiel.h m0_spiel_tx_to_str"
  c_spiel_tx_to_str :: Ptr SpielTransactionV
                    -> Word64
                    -> Ptr CString
                    -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_tx_str_free"
  c_spiel_tx_str_free :: CString -> IO ()

foreign import capi "spiel/spiel.h m0_spiel_cmd_profile_set"
  c_spiel_cmd_profile_set :: Ptr SpielContextV
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
                         -> Ptr Fid -- ^ imeta pver
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
                     -> Word32 -- ^ Device index
                     -> CInt -- ^ StorageDeviceInterfaceType
                     -> CInt -- ^ StorageDeviceMediaType
                     -> Word32
                     -> Word64
                     -> Word64
                     -> Word64
                     -> CString
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

foreign import capi "spiel/spiel.h m0_spiel_pool_add"
  c_spiel_pool_add :: Ptr SpielTransactionV
                   -> Ptr Fid -- ^ fid of the pool
                   -> Ptr Fid -- ^ fid of the parent filesystem
                   -> Word32  -- ^ pool order
                   -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_pver_actual_add"
  c_spiel_pver_actual_add :: Ptr SpielTransactionV
                          -> Ptr Fid -- ^ fid of the pver
                          -> Ptr Fid -- ^ fid of the parent pool
                          -> Ptr PDClustAttr
                          -> Ptr Word32 -- ^ failures vec
                          -> Word32     -- ^ failures vec length
                          -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_pver_formulaic_add"
  c_spiel_pver_formulaic_add :: Ptr SpielTransactionV
                             -> Ptr Fid -- ^ fid of the pver
                             -> Ptr Fid -- ^ fid of the parent pool
                             -> Word32  -- ^ index
                             -> Ptr Fid -- ^ fid of the base pver
                             -> Ptr Word32 -- ^ allowance vector
                             -> Word32     -- ^ allowance vector length
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

---------------------------------------------------------------
-- Command interface                                         --
---------------------------------------------------------------

foreign import capi "spiel/spiel.h m0_spiel_device_attach"
  c_spiel_device_attach :: Ptr SpielContextV
                        -> Ptr Fid
                        -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_device_detach"
  c_spiel_device_detach :: Ptr SpielContextV
                        -> Ptr Fid
                        -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_pool_repair_start"
  c_spiel_pool_repair_start :: Ptr SpielContextV
                            -> Ptr Fid
                            -> IO CInt


foreign import capi "spiel/spiel.h m0_spiel_pool_repair_continue"
  c_spiel_pool_repair_continue :: Ptr SpielContextV
                               -> Ptr Fid
                               -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_pool_repair_quiesce"
  c_spiel_pool_repair_quiesce :: Ptr SpielContextV
                              -> Ptr Fid
                              -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_pool_repair_status"
  c_spiel_pool_repair_status :: Ptr SpielContextV
                             -> Ptr Fid
                             -> Ptr (Ptr SnsStatus)
                             -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_pool_repair_abort"
  c_spiel_pool_repair_abort :: Ptr SpielContextV
                            -> Ptr Fid
                            -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_pool_rebalance_start"
  c_spiel_pool_rebalance_start :: Ptr SpielContextV
                               -> Ptr Fid
                               -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_pool_rebalance_continue"
  c_spiel_pool_rebalance_continue :: Ptr SpielContextV
                                  -> Ptr Fid
                                  -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_pool_rebalance_quiesce"
  c_spiel_pool_rebalance_quiesce :: Ptr SpielContextV
                                 -> Ptr Fid
                                 -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_pool_rebalance_status"
  c_spiel_pool_rebalance_status :: Ptr SpielContextV
                                -> Ptr Fid
                                -> Ptr (Ptr SnsStatus)
                                -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_pool_rebalance_abort"
  c_spiel_pool_rebalance_abort :: Ptr SpielContextV
                               -> Ptr Fid
                               -> IO CInt

foreign import capi "confc_helpers.h halon_interface_spiel"
  c_spiel :: IO (Ptr SpielContextV)

foreign import capi "spiel/spiel.h m0_spiel_filesystem_stats_fetch"
  c_spiel_filesystem_stats_fetch :: Ptr SpielContextV
                                 -> Ptr Fid
                                 -> Ptr FSStats
                                 -> IO CInt

---------------------------------------------------------------
-- Cache validation                                          --
---------------------------------------------------------------

foreign import capi "confc_helpers.h confc_validate_cache_of_tx"
  c_confc_validate_cache_of_tx :: Ptr SpielTransactionV
                               -> CSize
                               -> IO CString
