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

import Mero.ConfC
  ( Fid )
import Mero.Spiel.Context

import Network.RPC.RPCLite
  ( RPCMachine(..) )

import Data.Monoid ((<>))
import Data.Word ( Word32, Word64 )

import Foreign.C.String
  ( CString )
import Foreign.C.Types
import Foreign.Marshal.Error
  ( throwIf_ )
import Foreign.Ptr
  ( Ptr
  , castPtr
  )
import Foreign.Storable

import qualified Language.C.Inline as C

import System.IO.Unsafe (unsafePerformIO)

#include "spiel/spiel.h"
#include "rpc/rpc_machine.h"

#let alignment t = "%lu", (unsigned long)offsetof(struct {char x__; t (y__);}, y__)

-- | m0_reqh
data ReqHV

-- | Extract the request handler from RPC machine
rm_reqh :: RPCMachine -> Ptr ReqHV
rm_reqh (RPCMachine rpcmach) = unsafePerformIO $
  #{peek struct m0_rpc_machine, rm_reqh} rpcmach

-- | m0_spiel
data SpielContextV

-- | Size of m0_spiel struct for allocation
m0_spiel_size :: Int
m0_spiel_size = #{size struct m0_spiel}

foreign import ccall "spiel.h m0_spiel_start"
  c_spiel_start :: Ptr SpielContextV
                -> Ptr ReqHV
                -> Ptr CString
                -> CString
                -> IO CInt

foreign import ccall "spiel.h m0_spiel_stop"
  c_spiel_stop :: Ptr SpielContextV
               -> IO ()

---------------------------------------------------------------
-- Transactions                                              --
---------------------------------------------------------------

-- | m0_spiel_tx
data SpielTransactionV

-- | Size of m0_spiel_tx struct for allocation
m0_spiel_tx_size :: Int
m0_spiel_tx_size = #{size struct m0_spiel_tx}

foreign import ccall "spiel.h m0_spiel_tx_open"
  c_spiel_tx_open :: Ptr SpielContextV
                  -> Ptr SpielTransactionV
                  -> IO (Ptr SpielTransactionV)

foreign import ccall "spiel.h m0_spiel_tx_close"
  c_spiel_tx_close :: Ptr SpielTransactionV
                   -> IO ()

foreign import ccall "spiel.h m0_spiel_tx_commit"
  c_spiel_tx_commit :: Ptr SpielTransactionV
                    -> IO CInt

foreign import ccall "spiel.h m0_spiel_tx_commit_forced"
  c_spiel_tx_commit_forced :: Ptr SpielTransactionV
                           -> CChar -- ^ Forced - used as bool
                           -> Word64 -- ^ ver_forced
                           -> Word32 -- ^ Quorum
                           -> IO CInt

---------------------------------------------------------------
-- Configuration management                                  --
---------------------------------------------------------------

foreign import ccall "spiel.h m0_spiel_profile_add"
  c_spiel_profile_add :: Ptr SpielTransactionV
                      -> Ptr Fid
                      -> IO CInt

foreign import ccall "spiel.h m0_spiel_filesystem_add"
  c_spiel_filesystem_add :: Ptr SpielTransactionV
                         -> Ptr Fid -- ^ fid of the filesystem
                         -> Ptr Fid -- ^ fid of the parent profile
                         -> CUInt   -- ^ metadata redundancy count
                         -> Ptr Fid -- ^ root's fid of filesystem
                         -> Ptr (Ptr CChar) -- ^ NULL-terminated array of command-line like parameters
                         -> IO CInt

foreign import ccall "spiel.h m0_spiel_node_add"
  c_spiel_node_add :: Ptr SpielTransactionV
                   -> Ptr Fid -- ^ fid of the filesystem
                   -> Ptr Fid -- ^ fid of the parent profile
                   -> Word32
                   -> Word32
                   -> Word64
                   -> Word64
                   -> Ptr Fid -- ^ Pool fid
                   -> IO CInt

foreign import ccall "spiel.h m0_spiel_process_add"
  c_spiel_process_add :: Ptr SpielTransactionV
                      -> Ptr Fid -- ^ fid of the filesystem
                      -> Ptr Fid -- ^ fid of the parent profile
                      -> Ptr Bitmap
                      -> Word64
                      -> Word64
                      -> Word64
                      -> Word64
                      -> IO CInt

foreign import ccall "spiel.h m0_spiel_service_add"
  c_spiel_service_add :: Ptr SpielTransactionV
                      -> Ptr Fid -- ^ fid of the filesystem
                      -> Ptr Fid -- ^ fid of the parent profile
                      -> Ptr ServiceInfo
                      -> IO CInt

-- | @schema.h m0_cfg_storage_device_interface_type@
data StorageDeviceInterfaceType =
    M0_CFG_DEVICE_INTERFACE_ATA
  | M0_CFG_DEVICE_INTERFACE_SATA
  | M0_CFG_DEVICE_INTERFACE_SCSI
  | M0_CFG_DEVICE_INTERFACE_SATA2
  | M0_CFG_DEVICE_INTERFACE_SCSI2
  | M0_CFG_DEVICE_INTERFACE_SAS
  | M0_CFG_DEVICE_INTERFACE_SAS2
  | M0_CFG_DEVICE_INTERFACE_UNKNOWN Int
  deriving (Eq, Show)

instance Enum StorageDeviceInterfaceType where
  toEnum #{const M0_CFG_DEVICE_INTERFACE_ATA} = M0_CFG_DEVICE_INTERFACE_ATA
  toEnum #{const M0_CFG_DEVICE_INTERFACE_SATA} = M0_CFG_DEVICE_INTERFACE_SATA
  toEnum #{const M0_CFG_DEVICE_INTERFACE_SCSI} = M0_CFG_DEVICE_INTERFACE_SCSI
  toEnum #{const M0_CFG_DEVICE_INTERFACE_SATA2} = M0_CFG_DEVICE_INTERFACE_SATA2
  toEnum #{const M0_CFG_DEVICE_INTERFACE_SCSI2} = M0_CFG_DEVICE_INTERFACE_SCSI2
  toEnum #{const M0_CFG_DEVICE_INTERFACE_SAS} = M0_CFG_DEVICE_INTERFACE_SAS
  toEnum #{const M0_CFG_DEVICE_INTERFACE_SAS2} = M0_CFG_DEVICE_INTERFACE_SAS2
  toEnum i = M0_CFG_DEVICE_INTERFACE_UNKNOWN i

  fromEnum M0_CFG_DEVICE_INTERFACE_ATA = #{const M0_CFG_DEVICE_INTERFACE_ATA }
  fromEnum M0_CFG_DEVICE_INTERFACE_SATA = #{const M0_CFG_DEVICE_INTERFACE_SATA }
  fromEnum M0_CFG_DEVICE_INTERFACE_SCSI = #{const M0_CFG_DEVICE_INTERFACE_SCSI }
  fromEnum M0_CFG_DEVICE_INTERFACE_SATA2 = #{const M0_CFG_DEVICE_INTERFACE_SATA2 }
  fromEnum M0_CFG_DEVICE_INTERFACE_SCSI2 = #{const M0_CFG_DEVICE_INTERFACE_SCSI2 }
  fromEnum M0_CFG_DEVICE_INTERFACE_SAS = #{const M0_CFG_DEVICE_INTERFACE_SAS }
  fromEnum M0_CFG_DEVICE_INTERFACE_SAS2 = #{const M0_CFG_DEVICE_INTERFACE_SAS2 }
  fromEnum (M0_CFG_DEVICE_INTERFACE_UNKNOWN i) = i

instance Storable StorageDeviceInterfaceType where
  sizeOf _ = sizeOf (undefined :: CInt)
  alignment _ = alignment (undefined :: CInt)
  peek p = fmap toEnum $ peek (castPtr p)
  poke p s = poke (castPtr p) $ fromEnum s

-- | @schema.h m0_cfg_storage_device_media_type@
data StorageDeviceMediaType =
    M0_CFG_DEVICE_MEDIA_DISK
  | M0_CFG_DEVICE_MEDIA_SSD
  | M0_CFG_DEVICE_MEDIA_TAPE
  | M0_CFG_DEVICE_MEDIA_ROM
  | M0_CFG_DEVICE_MEDIA_UNKNOWN Int
  deriving (Eq, Show)

instance Enum StorageDeviceMediaType where
  toEnum #{const M0_CFG_DEVICE_MEDIA_DISK} = M0_CFG_DEVICE_MEDIA_DISK
  toEnum #{const M0_CFG_DEVICE_MEDIA_SSD} = M0_CFG_DEVICE_MEDIA_SSD
  toEnum #{const M0_CFG_DEVICE_MEDIA_TAPE} = M0_CFG_DEVICE_MEDIA_TAPE
  toEnum #{const M0_CFG_DEVICE_MEDIA_ROM} = M0_CFG_DEVICE_MEDIA_ROM
  toEnum i = M0_CFG_DEVICE_MEDIA_UNKNOWN i

  fromEnum M0_CFG_DEVICE_MEDIA_DISK = #{const M0_CFG_DEVICE_MEDIA_DISK }
  fromEnum M0_CFG_DEVICE_MEDIA_SSD = #{const M0_CFG_DEVICE_MEDIA_SSD }
  fromEnum M0_CFG_DEVICE_MEDIA_TAPE = #{const M0_CFG_DEVICE_MEDIA_TAPE }
  fromEnum M0_CFG_DEVICE_MEDIA_ROM = #{const M0_CFG_DEVICE_MEDIA_ROM }
  fromEnum (M0_CFG_DEVICE_MEDIA_UNKNOWN i) = i

instance Storable StorageDeviceMediaType where
  sizeOf _ = sizeOf (undefined :: CInt)
  alignment _ = alignment (undefined :: CInt)
  peek p = fmap toEnum $ peek (castPtr p)
  poke p s = poke (castPtr p) $ fromEnum s

foreign import ccall "spiel.h m0_spiel_device_add"
  c_spiel_device_add :: Ptr SpielTransactionV
                     -> Ptr Fid -- ^ fid of the filesystem
                     -> Ptr Fid -- ^ fid of the parent profile
                     -> CInt -- ^ StorageDeviceInterfaceType
                     -> CInt -- ^ StorageDeviceMediaType
                     -> Word32
                     -> Word64
                     -> Word64
                     -> Word64
                     -> Ptr Char
                     -> IO CInt

foreign import ccall "spiel.h m0_spiel_pool_add"
  c_spiel_pool_add :: Ptr SpielTransactionV
                   -> Ptr Fid -- ^ fid of the filesystem
                   -> Ptr Fid -- ^ fid of the parent profile
                   -> Word32
                   -> IO CInt

foreign import ccall "spiel.h m0_spiel_rack_add"
  c_spiel_rack_add :: Ptr SpielTransactionV
                   -> Ptr Fid -- ^ fid of the filesystem
                   -> Ptr Fid -- ^ fid of the parent profile
                   -> IO CInt


foreign import ccall "spiel.h m0_spiel_enclosure_add"
  c_spiel_enclosure_add :: Ptr SpielTransactionV
                        -> Ptr Fid -- ^ fid of the filesystem
                        -> Ptr Fid -- ^ fid of the parent profile
                        -> IO CInt


foreign import ccall "spiel.h m0_spiel_pool_version_add"
  c_spiel_pool_version_add :: Ptr SpielTransactionV
                         -> Ptr Fid -- ^ fid of the filesystem
                         -> Ptr Fid -- ^ fid of the parent profile
                         -> Ptr PDClustAttr -- ^ Node
                         -> IO CInt

foreign import ccall "spiel.h m0_spiel_rack_v_add"
  c_spiel_rack_v_add :: Ptr SpielTransactionV
                     -> Ptr Fid -- ^ fid of the filesystem
                     -> Ptr Fid -- ^ fid of the parent profile
                     -> Ptr Fid -- ^ Node
                     -> IO CInt

foreign import ccall "spiel.h m0_spiel_enclosure_v_add"
  c_spiel_enclosure_v_add :: Ptr SpielTransactionV
                          -> Ptr Fid -- ^ fid of the filesystem
                          -> Ptr Fid -- ^ fid of the parent profile
                          -> Ptr Fid -- ^ Node
                          -> IO CInt

foreign import ccall "spiel.h m0_spiel_controller_v_add"
  c_spiel_controller_v_add :: Ptr SpielTransactionV
                           -> Ptr Fid -- ^ fid of the filesystem
                           -> Ptr Fid -- ^ fid of the parent profile
                           -> Ptr Fid -- ^ Node
                           -> IO CInt

foreign import ccall "spiel.h m0_spiel_pool_version_done"
  c_spiel_pool_version_done :: Ptr SpielTransactionV
                            -> Ptr Fid -- ^ fid of the filesystem
                            -> IO CInt

foreign import ccall "spiel.h m0_spiel_controller_add"
  c_spiel_controller_add :: Ptr SpielTransactionV
                         -> Ptr Fid -- ^ fid of the filesystem
                         -> Ptr Fid -- ^ fid of the parent profile
                         -> Ptr Fid -- ^ Node
                         -> IO CInt

foreign import ccall "spiel.h m0_spiel_element_del"
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

foreign import ccall "spiel.h m0_spiel_service_init"
  c_spiel_service_init :: Ptr SpielContextV
                       -> Ptr Fid
                       -> IO CInt

foreign import ccall "spiel.h m0_spiel_service_start"
  c_spiel_service_start :: Ptr SpielContextV
                        -> Ptr Fid
                        -> IO CInt

foreign import ccall "spiel.h m0_spiel_service_stop"
  c_spiel_service_stop :: Ptr SpielContextV
                       -> Ptr Fid
                       -> IO CInt

foreign import ccall "spiel.h m0_spiel_service_health"
  c_spiel_service_health :: Ptr SpielContextV
                         -> Ptr Fid
                         -> IO CInt

foreign import ccall "spiel.h m0_spiel_service_quiesce"
  c_spiel_service_quiesce :: Ptr SpielContextV
                          -> Ptr Fid
                          -> IO CInt

foreign import ccall "spiel.h m0_spiel_device_attach"
  c_spiel_device_attach :: Ptr SpielContextV
                        -> Ptr Fid
                        -> IO CInt

foreign import ccall "spiel.h m0_spiel_device_detach"
  c_spiel_device_detach :: Ptr SpielContextV
                        -> Ptr Fid
                        -> IO CInt

foreign import ccall "spiel.h m0_spiel_device_format"
  c_spiel_device_format :: Ptr SpielContextV
                        -> Ptr Fid
                        -> IO CInt

foreign import ccall "spiel.h m0_spiel_process_stop"
  c_spiel_process_stop :: Ptr SpielContextV
                       -> Ptr Fid
                       -> IO CInt

foreign import ccall "spiel.h m0_spiel_process_reconfig"
  c_spiel_process_reconfig :: Ptr SpielContextV
                           -> Ptr Fid
                           -> IO CInt

foreign import ccall "spiel.h m0_spiel_process_health"
  c_spiel_process_health :: Ptr SpielContextV
                         -> Ptr Fid
                         -> IO CInt

foreign import ccall "spiel.h m0_spiel_process_quiesce"
  c_spiel_process_quiesce :: Ptr SpielContextV
                          -> Ptr Fid
                          -> IO CInt

foreign import ccall "spiel.h m0_spiel_process_list_services"
  c_spiel_process_list_services :: Ptr SpielContextV
                                -> Ptr Fid
                                -> Ptr (Ptr RunningService)
                                -> IO CInt

foreign import ccall "spiel.h m0_spiel_pool_repair_start"
  c_spiel_pool_repair_start :: Ptr SpielContextV
                            -> Ptr Fid
                            -> IO CInt

foreign import ccall "spiel.h m0_spiel_pool_repair_quiesce"
  c_spiel_pool_repair_quiesce :: Ptr SpielContextV
                              -> Ptr Fid
                              -> IO CInt

foreign import ccall "spiel.h m0_spiel_pool_rebalance_start"
  c_spiel_pool_rebalance_start :: Ptr SpielContextV
                               -> Ptr Fid
                               -> IO CInt

foreign import ccall "spiel.h m0_spiel_pool_rebalance_quiesce"
  c_spiel_pool_rebalance_quiesce :: Ptr SpielContextV
                                 -> Ptr Fid
                                 -> IO CInt

---------------------------------------------------------------
-- Utility                                                   --
---------------------------------------------------------------

C.context $ C.baseCtx <> spielCtx

C.include "lib/memory.h"
C.include "spiel/spiel.h"

freeRunningServices :: Ptr RunningService -- ^ Pointer to head of array
                    -> IO CInt
freeRunningServices arr = [C.block| int {
    struct m0_spiel_running_svc *arr = $(struct m0_spiel_running_svc *arr);
    m0_free(arr);
  }
|]

throwIfNonZero_ :: (Eq a, Num a) => (a -> String) -> IO a -> IO ()
throwIfNonZero_ = throwIf_ (/= 0)
