{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2018 Seagate Technology Limited.
-- License   : All rights reserved.

module HA.RecoveryCoordinator.RC.Events.Debug
  ( DebugModify(..)
  , DebugQuery(..)
  , DriveId(..)
  , ModifyDriveStateReq(..)
  , ModifyDriveStateResp(..)
  , QueryDriveStateReq(..)
  , QueryDriveStateResp(..)
  , SelectDrive(..)
  , StateOfDrive(..)
  ) where

import Control.Distributed.Process (SendPort)
import Data.Binary (Binary)
import Data.Text (Text)
import GHC.Generics (Generic)

import HA.SafeCopy (base, deriveSafeCopy)

data DebugQuery
  = QueryDriveState QueryDriveStateReq
  -- | QueryDriveRelations
  -- | QuerySdevState QuerySdevState
  -- | QueryPoolState
  deriving Show

data DebugModify
  = ModifyDriveState ModifyDriveStateReq
  -- | ModifySdevState ModifySdevStateReq
  -- | ModifyPoolState
  -- | ModifyPoolRepair
  -- | ModifyPoolRebalance
  deriving Show

data QueryDriveStateReq = QueryDriveStateReq
  { qdsSelect :: SelectDrive
  , qdsReplyTo :: SendPort QueryDriveStateResp
  } deriving Show

data QueryDriveStateResp
  = QDriveState Text
  | QDriveStateNoStorageDeviceError String
  deriving (Generic, Show)

instance Binary QueryDriveStateResp

data ModifyDriveStateReq = ModifyDriveStateReq
  { mdsSelect :: SelectDrive
  , mdsNewState :: StateOfDrive
  , mdsReplyTo :: SendPort ModifyDriveStateResp
  } deriving Show

data ModifyDriveStateResp
  = MDriveStateOK
  | MDriveStateNoStorageDeviceError String
  deriving (Generic, Show)

instance Binary ModifyDriveStateResp

newtype SelectDrive = SelectDrive DriveId
  deriving Show

-- | Drive identifier.
--
-- See also 'M0Device'.
data DriveId
  = DriveSerial Text  -- ^ Serial number.
  | DriveWwn Text     -- ^ World Wide Name.
  | DriveEnclSlot Text Int  -- ^ Enclosure id and index of slot within
                            -- this enclosure.
  --XXX | DriveFid Fid
  deriving Show

-- | Desired state of drive.
-- See also HA.Resources.Mero.SDevState.
data StateOfDrive = DriveOnline | DriveFailed | DriveBlank
  deriving Show

deriveSafeCopy 0 'base ''DebugModify
deriveSafeCopy 0 'base ''DebugQuery
deriveSafeCopy 0 'base ''DriveId
deriveSafeCopy 0 'base ''ModifyDriveStateReq
deriveSafeCopy 0 'base ''QueryDriveStateReq
deriveSafeCopy 0 'base ''SelectDrive
deriveSafeCopy 0 'base ''StateOfDrive
