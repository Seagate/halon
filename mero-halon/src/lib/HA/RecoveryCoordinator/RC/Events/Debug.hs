{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2018 Seagate Technology Limited.
-- License   : All rights reserved.

module HA.RecoveryCoordinator.RC.Events.Debug
  ( DriveId(..)
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

data QueryDriveStateReq = QueryDriveStateReq
  { qdsSelect :: SelectDrive
  , qdsReplyTo :: SendPort QueryDriveStateResp
  } deriving Show

data QueryDriveStateResp
  = QueryDriveState Text
  | QueryDriveStateNoStorageDeviceError
  deriving (Generic, Show)

instance Binary QueryDriveStateResp

data ModifyDriveStateReq = ModifyDriveStateReq
  { mdsSelect :: SelectDrive
  , mdsNewState :: StateOfDrive
  , mdsReplyTo :: SendPort ModifyDriveStateResp
  } deriving Show

data ModifyDriveStateResp
  = ModifyDriveStateOK
  | ModifyDriveStateNoStorageDeviceError
  deriving (Generic, Show)

instance Binary ModifyDriveStateResp

newtype SelectDrive = SelectDrive DriveId
  deriving Show

-- | Drive identifier.
data DriveId
  = DriveSerial Text  -- ^ Serial number of the drive.
  | DriveWwn Text     -- ^ World Wide Name of the drive.
  deriving Show

-- | Desired state of drive.
-- See also HA.Resources.Mero.SDevState.
data StateOfDrive = DriveOnline | DriveFailed | DriveBlank
  deriving Show

deriveSafeCopy 0 'base ''DriveId
deriveSafeCopy 0 'base ''ModifyDriveStateReq
deriveSafeCopy 0 'base ''QueryDriveStateReq
deriveSafeCopy 0 'base ''SelectDrive
deriveSafeCopy 0 'base ''StateOfDrive
