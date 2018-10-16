{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2018 Seagate Technology Limited.
-- License   : All rights reserved.

module HA.RecoveryCoordinator.RC.Events.Debug
  ( DebugDriveInfo(..)
  , DebugH0Sdev(..)
  , DebugModify(..)
  , DebugQuery(..)
  , DriveId(..)
  , ModifyDriveStateReq(..)
  , ModifyDriveStateResp(ModifyDriveStateOK,ModifyDriveStateError)
  , ModifySdevStateReq(..)
  , ModifySdevStateResp(ModifySdevStateOK,ModifySdevStateError)
  , QueryDriveInfoReq(..)
  , QueryDriveInfoResp(QueryDriveInfo,QueryDriveInfoError)
  , SelectDrive(..)
  , SelectSdev(..)
  , StateOfDrive(..)
  , StateOfSdev(..)
  ) where

import           Control.Distributed.Process (SendPort)
import           Data.Binary (Binary)
import           Data.Text (Text)
import           GHC.Generics (Generic)

import qualified HA.Resources.Castor as Cas
-- import qualified HA.Resources.Mero as M0
import           HA.SafeCopy (base, deriveSafeCopy)

data DebugQuery
  = DebugQueryDriveInfo QueryDriveInfoReq
  -- | DebugQueryPoolInfo XXX
  deriving Show

data DebugModify
  = DebugModifyDriveState ModifyDriveStateReq
  | DebugModifySdevState ModifySdevStateReq
  -- | DebugModifyPoolState XXX
  -- | DebugModifyPoolRepair XXX
  -- | DebugModifyPoolRebalance XXX
  deriving Show

----------------------------------------------------------------------
-- hctl debug print drive

data QueryDriveInfoReq
  = QueryDriveInfoReq SelectDrive (SendPort QueryDriveInfoResp)
  deriving Show

data QueryDriveInfoResp
  = QueryDriveInfo DebugDriveInfo
  | QueryDriveInfoError String
  deriving (Generic, Show)

instance Binary QueryDriveInfoResp

-- | Various pieces of information about a storage device.
data DebugDriveInfo = DebugDriveInfo
  { dsiH0Sdev :: Maybe DebugH0Sdev
  --XXX , dsiM0Drive :: Maybe DebugM0Drive
  --XXX , dsiM0Sdev :: Maybe DebugM0Sdev
  } deriving (Generic, Show)

instance Binary DebugDriveInfo

-- Cas.StorageDevice info.
data DebugH0Sdev = DebugH0Sdev
  { dhsSdev :: Cas.StorageDevice
  , dhsIds :: [Cas.DeviceIdentifier]
  , dhsStatus :: Maybe Cas.StorageDeviceStatus
  , dhsAttrs :: [Cas.StorageDeviceAttr]
  } deriving (Generic, Show)

instance Binary DebugH0Sdev

newtype SelectDrive = SelectDrive DriveId
  deriving Show

-- | Drive identifier.
-- See also 'M0Device'.
data DriveId
  = DriveSerial Text  -- ^ Serial number.
  | DriveWwn Text     -- ^ World Wide Name.
  | DriveEnclSlot Text Int  -- ^ Enclosure id and index of slot within
                            -- this enclosure.
  --XXX | DriveFid Fid
  deriving Show

----------------------------------------------------------------------
-- hctl debug set drive

data ModifyDriveStateReq
  = ModifyDriveStateReq SelectDrive StateOfDrive (SendPort ModifyDriveStateResp)
  deriving Show

data ModifyDriveStateResp
  = ModifyDriveStateOK
  | ModifyDriveStateError String
  deriving (Generic, Show)

instance Binary ModifyDriveStateResp

-- | Desired state of a drive.
-- See also HA.Resources.Mero.SDevState.
data StateOfDrive = DriveOnline | DriveFailed | DriveBlank
  deriving Show

----------------------------------------------------------------------
-- hctl debug set sdev

data ModifySdevStateReq
  = ModifySdevStateReq SelectSdev StateOfSdev (SendPort ModifySdevStateResp)
  deriving Show

data ModifySdevStateResp
  = ModifySdevStateOK
  | ModifySdevStateError String
  deriving (Generic, Show)

instance Binary ModifySdevStateResp

newtype SelectSdev = SelectSdev DriveId
  deriving Show

-- | Desired state of a storage device.
-- See also HA.Resources.Mero.SDevState.
data StateOfSdev = SdevOnline | SdevFailed | SdevRepaired
  deriving Show

deriveSafeCopy 0 'base ''DebugModify
deriveSafeCopy 0 'base ''DebugQuery
deriveSafeCopy 0 'base ''DriveId
deriveSafeCopy 0 'base ''ModifyDriveStateReq
deriveSafeCopy 0 'base ''ModifySdevStateReq
deriveSafeCopy 0 'base ''QueryDriveInfoReq
deriveSafeCopy 0 'base ''SelectDrive
deriveSafeCopy 0 'base ''SelectSdev
deriveSafeCopy 0 'base ''StateOfDrive
deriveSafeCopy 0 'base ''StateOfSdev
