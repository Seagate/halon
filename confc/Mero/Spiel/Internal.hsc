{-# LANGUAGE CApiFFI                  #-}
{-# LANGUAGE EmptyDataDecls           #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE QuasiQuotes              #-}
{-# LANGUAGE TemplateHaskell          #-}

-- |
-- Copyright : (C) 2015-2018 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Bindings to the spiel interface.
--

module Mero.Spiel.Internal
  ( SpielContextV
  , SpielTransactionV
  , c_confc_validate_cache_of_tx
  , c_spiel
  , c_spiel_cmd_profile_set
  , c_spiel_root_add

  , c_spiel_node_add
  , c_spiel_process_add
  , c_spiel_service_add
  , c_spiel_device_add

  , c_spiel_site_add
  , c_spiel_rack_add
  , c_spiel_enclosure_add
  , c_spiel_controller_add
  , c_spiel_drive_add

  , c_spiel_pool_add
  , c_spiel_pver_actual_add
  , c_spiel_pver_formulaic_add
  , c_spiel_site_v_add
  , c_spiel_rack_v_add
  , c_spiel_enclosure_v_add
  , c_spiel_controller_v_add
  , c_spiel_drive_v_add
  , c_spiel_pool_version_done

  , c_spiel_profile_add
  , c_spiel_profile_pool_add

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
  , c_spiel_node_direct_rebalance_start
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
import Foreign.C.Types (CChar, CInt(..), CSize(..))
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

-- XXX-MULTIPOOLS: DELETEME?
foreign import capi "spiel/spiel.h m0_spiel_cmd_profile_set"
  c_spiel_cmd_profile_set :: Ptr SpielContextV
                          -> CString
                          -> IO CInt

---------------------------------------------------------------
-- Configuration management                                  --
---------------------------------------------------------------

-- XXX ccall/capi const?
foreign import ccall "spiel/spiel.h m0_spiel_root_add"
  c_spiel_root_add :: Ptr SpielTransactionV
                   -> Ptr Fid         -- ^ rootfid
                   -> Ptr Fid         -- ^ mdpool
                   -> Ptr Fid         -- ^ imeta_pver
                   -> Word32          -- ^ mdredundancy
                   -> Ptr (Ptr CChar) -- ^ params (NULL-terminated array)
                   -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_node_add"
  c_spiel_node_add :: Ptr SpielTransactionV
                   -> Ptr Fid
                   -> Word32  -- ^ memsize
                   -> Word32  -- ^ nr_cpu
                   -> Word64  -- ^ last_state
                   -> Word64  -- ^ flags
                   -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_process_add"
  c_spiel_process_add :: Ptr SpielTransactionV
                      -> Ptr Fid
                      -> Ptr Fid    -- ^ parent
                      -> Ptr Bitmap -- ^ cores
                      -> Word64     -- ^ memlimit_as
                      -> Word64     -- ^ memlimit_rss
                      -> Word64     -- ^ memlimit_stack
                      -> Word64     -- ^ memlimit_memlock
                      -> CString    -- ^ endpoint
                      -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_service_add"
  c_spiel_service_add :: Ptr SpielTransactionV
                      -> Ptr Fid
                      -> Ptr Fid -- ^ parent
                      -> Ptr ServiceInfo
                      -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_device_add"
  c_spiel_device_add :: Ptr SpielTransactionV
                     -> Ptr Fid
                     -> Ptr Fid -- ^ parent
                     -> Ptr Fid -- ^ drive
                     -> Word32  -- ^ dev_idx
                     -> CInt    -- ^ iface :: StorageDeviceInterfaceType
                     -> CInt    -- ^ media :: StorageDeviceMediaType
                     -> Word32  -- ^ bsize
                     -> Word64  -- ^ size
                     -> Word64  -- ^ last_state
                     -> Word64  -- ^ flags
                     -> CString -- ^ filename
                     -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_site_add"
  c_spiel_site_add :: Ptr SpielTransactionV
                   -> Ptr Fid
                   -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_rack_add"
  c_spiel_rack_add :: Ptr SpielTransactionV
                   -> Ptr Fid
                   -> Ptr Fid -- ^ parent
                   -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_enclosure_add"
  c_spiel_enclosure_add :: Ptr SpielTransactionV
                        -> Ptr Fid
                        -> Ptr Fid -- ^ parent
                        -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_controller_add"
  c_spiel_controller_add :: Ptr SpielTransactionV
                         -> Ptr Fid
                         -> Ptr Fid -- ^ parent
                         -> Ptr Fid -- ^ node
                         -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_drive_add"
  c_spiel_drive_add :: Ptr SpielTransactionV
                    -> Ptr Fid
                    -> Ptr Fid -- ^ parent
                    -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_pool_add"
  c_spiel_pool_add :: Ptr SpielTransactionV
                   -> Ptr Fid
                   -> Word32  -- ^ pver_policy
                   -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_pver_actual_add"
  c_spiel_pver_actual_add :: Ptr SpielTransactionV
                          -> Ptr Fid
                          -> Ptr Fid         -- ^ parent
                          -> Ptr PDClustAttr -- ^ attrs
                          -> Ptr Word32      -- ^ tolerance
                          -> Word32          -- ^ tolerance_len
                          -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_pver_formulaic_add"
  c_spiel_pver_formulaic_add :: Ptr SpielTransactionV
                             -> Ptr Fid
                             -> Ptr Fid    -- ^ parent
                             -> Word32     -- ^ index
                             -> Ptr Fid    -- ^ base_pver
                             -> Ptr Word32 -- ^ allowance
                             -> Word32     -- ^ allowance_len
                             -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_site_v_add"
  c_spiel_site_v_add :: Ptr SpielTransactionV
                     -> Ptr Fid
                     -> Ptr Fid -- ^ parent
                     -> Ptr Fid -- ^ real
                     -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_rack_v_add"
  c_spiel_rack_v_add :: Ptr SpielTransactionV
                     -> Ptr Fid
                     -> Ptr Fid -- ^ parent
                     -> Ptr Fid -- ^ real
                     -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_enclosure_v_add"
  c_spiel_enclosure_v_add :: Ptr SpielTransactionV
                          -> Ptr Fid
                          -> Ptr Fid -- ^ parent
                          -> Ptr Fid -- ^ real
                          -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_controller_v_add"
  c_spiel_controller_v_add :: Ptr SpielTransactionV
                           -> Ptr Fid
                           -> Ptr Fid -- ^ parent
                           -> Ptr Fid -- ^ real
                           -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_drive_v_add"
  c_spiel_drive_v_add :: Ptr SpielTransactionV
                      -> Ptr Fid
                      -> Ptr Fid -- ^ parent
                      -> Ptr Fid -- ^ real
                      -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_pool_version_done"
  c_spiel_pool_version_done :: Ptr SpielTransactionV
                            -> Ptr Fid
                            -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_profile_add"
  c_spiel_profile_add :: Ptr SpielTransactionV
                      -> Ptr Fid
                      -> IO CInt

foreign import capi "spiel/spiel.h m0_spiel_profile_pool_add"
  c_spiel_profile_pool_add :: Ptr SpielTransactionV
                           -> Ptr Fid -- ^ profile
                           -> Ptr Fid -- ^ pool
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

foreign import capi "spiel/spiel.h m0_spiel_node_direct_rebalance_start"
  c_spiel_node_direct_rebalance_start :: Ptr SpielContextV
                                      -> Ptr Fid
                                      -> IO CInt

foreign import capi "confc_helpers.h halon_interface_spiel"
  c_spiel :: IO (Ptr SpielContextV)

foreign import capi "spiel/spiel.h m0_spiel_filesystem_stats_fetch"
  c_spiel_filesystem_stats_fetch :: Ptr SpielContextV
                                 -> Ptr FSStats
                                 -> IO CInt

---------------------------------------------------------------
-- Cache validation                                          --
---------------------------------------------------------------

foreign import capi "confc_helpers.h confc_validate_cache_of_tx"
  c_confc_validate_cache_of_tx :: Ptr SpielTransactionV
                               -> CSize
                               -> IO CString
