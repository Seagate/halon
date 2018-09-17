{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2018 Seagate Technology Limited.
-- License   : All rights reserved.

module HA.RecoveryCoordinator.RC.Events.Debug
  ( DriveId(..)
  , QueryDriveStateReq(..)
  , QueryDriveStateResp(..)
  , SelectDrive(..)
  ) where

import Control.Distributed.Process (SendPort)
import Data.Binary (Binary)
import Data.Text (Text)
import Data.Word (Word8)
import GHC.Generics (Generic)

import HA.SafeCopy (base, deriveSafeCopy)

data QueryDriveStateReq = QueryDriveStateReq
  { qdsSelect :: SelectDrive
  , qdsReplyTo :: SendPort QueryDriveStateResp
  } deriving Show

data QueryDriveStateResp
  = QueryDriveState Text
  | QueryDriveStateError
  deriving (Generic, Show)

instance Binary QueryDriveStateResp

data SelectDrive = SelectDrive
  { sdEnclosure :: Text
  , sdSlot :: Word8
  , sdDrive :: DriveId
  } deriving Show

-- | Drive identifier.
data DriveId
  = DriveSerial Text  -- ^ Serial number of the drive.
  | DriveWwn Text     -- ^ World Wide Name of the drive.
  deriving Show

deriveSafeCopy 0 'base ''DriveId
deriveSafeCopy 0 'base ''QueryDriveStateReq
deriveSafeCopy 0 'base ''SelectDrive
