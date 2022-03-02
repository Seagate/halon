{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE EmptyDataDecls    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}
{-# LANGUAGE TemplateHaskell   #-}

-- |
-- Copyright : (C) 2015-2018 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- inline-c context for the spiel interface.
--

module Mero.Spiel.Context
  ( FSStats(..)
  , ServiceInfo(..)
  , SnsCmStatus(..)
  , SnsStatus(..)
  , StorageDeviceInterfaceType(..)
  , StorageDeviceMediaType(..)
  ) where

import Mero.ConfC (Fid, ServiceType)

import Control.Monad (liftM3)
import Data.Aeson (FromJSON, ToJSON)
import Data.Binary (Binary(get,put), Get)
import Data.Hashable (Hashable)
import Data.Word (Word32, Word64)
import Foreign.C.String (CString, newCString, peekCString)
import Foreign.C.Types (CInt, CUInt)
import Foreign.Marshal.Array (advancePtr, newArray0)
import Foreign.Ptr (Ptr, castPtr, nullPtr, plusPtr)
import Foreign.Storable (Storable(..))
import GHC.Generics (Generic)
import System.IO.Unsafe (unsafePerformIO)

#include "spiel/spiel.h"
#include "sns/cm/cm.h"

-- | @conf/schema.h m0_cfg_storage_device_interface_type@
data {-# CTYPE "conf/schema.h" "struct m0_cfg_storage_device_interface_type" #-}
  StorageDeviceInterfaceType
  = M0_CFG_DEVICE_INTERFACE_ATA
  | M0_CFG_DEVICE_INTERFACE_SATA
  | M0_CFG_DEVICE_INTERFACE_SCSI
  | M0_CFG_DEVICE_INTERFACE_SATA2
  | M0_CFG_DEVICE_INTERFACE_SCSI2
  | M0_CFG_DEVICE_INTERFACE_SAS
  | M0_CFG_DEVICE_INTERFACE_SAS2
  | M0_CFG_DEVICE_INTERFACE_UNKNOWN Int
  deriving (Eq, Show)

instance Enum StorageDeviceInterfaceType where
  toEnum #{const M0_CFG_DEVICE_INTERFACE_ATA}   = M0_CFG_DEVICE_INTERFACE_ATA
  toEnum #{const M0_CFG_DEVICE_INTERFACE_SATA}  = M0_CFG_DEVICE_INTERFACE_SATA
  toEnum #{const M0_CFG_DEVICE_INTERFACE_SCSI}  = M0_CFG_DEVICE_INTERFACE_SCSI
  toEnum #{const M0_CFG_DEVICE_INTERFACE_SATA2} = M0_CFG_DEVICE_INTERFACE_SATA2
  toEnum #{const M0_CFG_DEVICE_INTERFACE_SCSI2} = M0_CFG_DEVICE_INTERFACE_SCSI2
  toEnum #{const M0_CFG_DEVICE_INTERFACE_SAS}   = M0_CFG_DEVICE_INTERFACE_SAS
  toEnum #{const M0_CFG_DEVICE_INTERFACE_SAS2}  = M0_CFG_DEVICE_INTERFACE_SAS2
  toEnum i = M0_CFG_DEVICE_INTERFACE_UNKNOWN i

  fromEnum M0_CFG_DEVICE_INTERFACE_ATA   = #{const M0_CFG_DEVICE_INTERFACE_ATA}
  fromEnum M0_CFG_DEVICE_INTERFACE_SATA  = #{const M0_CFG_DEVICE_INTERFACE_SATA}
  fromEnum M0_CFG_DEVICE_INTERFACE_SCSI  = #{const M0_CFG_DEVICE_INTERFACE_SCSI}
  fromEnum M0_CFG_DEVICE_INTERFACE_SATA2 = #{const M0_CFG_DEVICE_INTERFACE_SATA2}
  fromEnum M0_CFG_DEVICE_INTERFACE_SCSI2 = #{const M0_CFG_DEVICE_INTERFACE_SCSI2}
  fromEnum M0_CFG_DEVICE_INTERFACE_SAS   = #{const M0_CFG_DEVICE_INTERFACE_SAS}
  fromEnum M0_CFG_DEVICE_INTERFACE_SAS2  = #{const M0_CFG_DEVICE_INTERFACE_SAS2}
  fromEnum (M0_CFG_DEVICE_INTERFACE_UNKNOWN i) = i

instance Storable StorageDeviceInterfaceType where
  sizeOf _ = sizeOf (undefined :: CInt)
  alignment _ = alignment (undefined :: CInt)
  peek p = fmap toEnum $ peek (castPtr p)
  poke p s = poke (castPtr p) $ fromEnum s

-- | @conf/schema.h m0_cfg_storage_device_media_type@
data {-# CTYPE "conf/schema.h" "struct m0_cfg_storage_device_media_type" #-}
  StorageDeviceMediaType
  = M0_CFG_DEVICE_MEDIA_DISK
  | M0_CFG_DEVICE_MEDIA_SSD
  | M0_CFG_DEVICE_MEDIA_TAPE
  | M0_CFG_DEVICE_MEDIA_ROM
  | M0_CFG_DEVICE_MEDIA_UNKNOWN Int
  deriving (Eq, Show)

instance Enum StorageDeviceMediaType where
  toEnum #{const M0_CFG_DEVICE_MEDIA_DISK} = M0_CFG_DEVICE_MEDIA_DISK
  toEnum #{const M0_CFG_DEVICE_MEDIA_SSD}  = M0_CFG_DEVICE_MEDIA_SSD
  toEnum #{const M0_CFG_DEVICE_MEDIA_TAPE} = M0_CFG_DEVICE_MEDIA_TAPE
  toEnum #{const M0_CFG_DEVICE_MEDIA_ROM}  = M0_CFG_DEVICE_MEDIA_ROM
  toEnum i = M0_CFG_DEVICE_MEDIA_UNKNOWN i

  fromEnum M0_CFG_DEVICE_MEDIA_DISK = #{const M0_CFG_DEVICE_MEDIA_DISK}
  fromEnum M0_CFG_DEVICE_MEDIA_SSD  = #{const M0_CFG_DEVICE_MEDIA_SSD}
  fromEnum M0_CFG_DEVICE_MEDIA_TAPE = #{const M0_CFG_DEVICE_MEDIA_TAPE}
  fromEnum M0_CFG_DEVICE_MEDIA_ROM  = #{const M0_CFG_DEVICE_MEDIA_ROM}
  fromEnum (M0_CFG_DEVICE_MEDIA_UNKNOWN i) = i

instance Storable StorageDeviceMediaType where
  sizeOf _ = sizeOf (undefined :: CInt)
  alignment _ = alignment (undefined :: CInt)
  peek p = fmap toEnum $ peek (castPtr p)
  poke p s = poke (castPtr p) $ fromEnum s

-- @spiel.h m0_spiel_service_info@
data {-# CTYPE "spiel/spiel.h" "struct m0_spiel_service_info" #-} ServiceInfo
  = ServiceInfo
  { _svi_type :: ServiceType
  , _svi_endpoints :: [String]
  } deriving (Eq, Show)

instance Storable ServiceInfo where
  sizeOf _ = #{size struct m0_spiel_service_info}
  alignment _ = #{alignment struct m0_spiel_service_info}
  peek p = do
    st <- fmap (toEnum . fromIntegral) $
            (#{peek struct m0_spiel_service_info, svi_type} p :: IO CInt)
    ep <- peekStringArray (#{ptr struct m0_spiel_service_info, svi_endpoints} p)
    return $ ServiceInfo st ep

  poke p (ServiceInfo t e) = do
    #{poke struct m0_spiel_service_info, svi_type} p $ fromEnum t
    cstrs <- mapM newCString e
    cstr_arr_ptr <- newArray0 nullPtr cstrs
    #{poke struct m0_spiel_service_info, svi_endpoints} p cstr_arr_ptr

-- | @sns/cm/cm.h m0_sns_cm_status@
data {-# CTYPE "sns/cm/cm.h" "struct m0_sns_cm_status" #-} SnsCmStatus
  = M0_SNS_CM_STATUS_INVALID
  | M0_SNS_CM_STATUS_IDLE
  | M0_SNS_CM_STATUS_STARTED
  | M0_SNS_CM_STATUS_FAILED
  | M0_SNS_CM_STATUS_PAUSED
  | M0_SNS_CM_STATUS_UNKNOWN Int
  deriving (Eq, Show)

instance Enum SnsCmStatus where
  toEnum #{const SNS_CM_STATUS_INVALID} = M0_SNS_CM_STATUS_INVALID
  toEnum #{const SNS_CM_STATUS_IDLE}    = M0_SNS_CM_STATUS_IDLE
  toEnum #{const SNS_CM_STATUS_STARTED} = M0_SNS_CM_STATUS_STARTED
  toEnum #{const SNS_CM_STATUS_FAILED}  = M0_SNS_CM_STATUS_FAILED
  toEnum #{const SNS_CM_STATUS_PAUSED}  = M0_SNS_CM_STATUS_PAUSED
  toEnum i = M0_SNS_CM_STATUS_UNKNOWN i

  fromEnum M0_SNS_CM_STATUS_INVALID = #{const SNS_CM_STATUS_INVALID}
  fromEnum M0_SNS_CM_STATUS_IDLE    = #{const SNS_CM_STATUS_IDLE}
  fromEnum M0_SNS_CM_STATUS_STARTED = #{const SNS_CM_STATUS_STARTED}
  fromEnum M0_SNS_CM_STATUS_FAILED  = #{const SNS_CM_STATUS_FAILED}
  fromEnum M0_SNS_CM_STATUS_PAUSED  = #{const SNS_CM_STATUS_PAUSED}
  fromEnum (M0_SNS_CM_STATUS_UNKNOWN i) = i

instance Storable SnsCmStatus where
  sizeOf _ = sizeOf (undefined :: CInt)
  alignment _ = alignment (undefined :: CInt)
  peek p = fmap (toEnum . fromIntegral) $ peek (castPtr p :: Ptr CInt)
  poke p s = poke (castPtr p :: Ptr CInt) . fromIntegral $ fromEnum s

-- | @spiel.h m0_spiel_sns_status@
--
-- XXX TODO: Replace with m0_spiel_repreb_status.
data {-# CTYPE "spiel/spiel.h" "struct m0_spiel_sns_status" #-} SnsStatus
  = SnsStatus
  { _sss_fid :: Fid
  , _sss_state :: SnsCmStatus
  , _sss_progress :: CUInt
  } deriving (Eq, Show)

instance Storable SnsStatus where
  sizeOf _ = #{size struct m0_spiel_sns_status}
  alignment _ = #{alignment struct m0_spiel_sns_status}
  peek p = liftM3 SnsStatus
    (#{peek struct m0_spiel_sns_status, sss_fid} p)
    (#{peek struct m0_spiel_sns_status, sss_state} p)
    (#{peek struct m0_spiel_sns_status, sss_progress} p)

  poke p (SnsStatus f st pr) = do
    #{poke struct m0_spiel_sns_status, sss_fid} p f
    #{poke struct m0_spiel_sns_status, sss_state} p st
    #{poke struct m0_spiel_sns_status, sss_progress} p pr

instance Binary SnsStatus where
  put (SnsStatus f s u) = put f >> put (fromEnum s) >> put (fromIntegral u :: Word64)
  get = SnsStatus <$> get <*> fmap toEnum get <*> fmap fromIntegral (get :: Get Word64)

-- | @spiel.h m0_fs_stats@
data {-# CTYPE "spiel/spiel.h" "struct m0_fs_stats" #-} FSStats
  = FSStats
  { _fss_free_seg :: Word64
  , _fss_total_seg :: Word64
  , _fss_free_disk :: Word64
  , _fss_total_disk :: Word64
  , _fss_svc_total :: Word32
  , _fss_svc_replied :: Word32
  } deriving (Eq, Generic, Show)

instance Hashable FSStats
instance FromJSON FSStats
instance ToJSON FSStats

instance Storable FSStats where
  sizeOf _ = #{size struct m0_fs_stats}
  alignment _ = #{alignment struct m0_fs_stats}
  peek p = FSStats
    <$> (#{peek struct m0_fs_stats, fs_free_seg} p)
    <*> (#{peek struct m0_fs_stats, fs_total_seg} p)
    <*> (#{peek struct m0_fs_stats, fs_free_disk} p)
    <*> (#{peek struct m0_fs_stats, fs_total_disk} p)
    <*> (#{peek struct m0_fs_stats, fs_svc_total} p)
    <*> (#{peek struct m0_fs_stats, fs_svc_replied} p)

  poke p f = do
    #{poke struct m0_fs_stats, fs_free_seg} p (_fss_free_seg f)
    #{poke struct m0_fs_stats, fs_total_seg} p (_fss_total_seg f)
    #{poke struct m0_fs_stats, fs_free_disk} p (_fss_free_disk f)
    #{poke struct m0_fs_stats, fs_total_disk} p (_fss_total_disk f)
    #{poke struct m0_fs_stats, fs_svc_total} p (_fss_svc_total f)
    #{poke struct m0_fs_stats, fs_svc_replied} p (_fss_svc_replied f)

--------------------------------------------------------------------------------
-- Utility
--------------------------------------------------------------------------------

peekStringArray :: Ptr CString -> IO [String]
peekStringArray p = mapM peekCString
                  $ takeWhile (/=nullPtr)
                  $ map (unsafePerformIO . peek)
                  $ iterate (`advancePtr` 1) p
