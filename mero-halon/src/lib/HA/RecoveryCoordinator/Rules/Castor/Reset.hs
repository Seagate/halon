
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Module containing some reset bits that multiple rules may want access to
module HA.RecoveryCoordinator.Rules.Castor.Reset where

import Data.Binary (Binary)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import HA.Resources.Castor

--------------------------------------------------------------------------------
-- Reset bit                                                                  --
--------------------------------------------------------------------------------

-- | When the number of reset attempts is greater than this threshold, a 'Disk'
--   should be in 'DiskFailure' status.
resetAttemptThreshold :: Int
resetAttemptThreshold = 10

-- | Time to allow for SSPL to reply on a reset request.
driveResetTimeout :: Int
driveResetTimeout = 5*60

-- | Event sent when to many failures has been sent for a 'Disk'.
data ResetAttempt = ResetAttempt StorageDevice
  deriving (Eq, Generic, Show, Typeable)

instance Binary ResetAttempt

-- | Event sent when a ResetAttempt were successful.
newtype ResetSuccess =
    ResetSuccess StorageDevice
    deriving (Eq, Show, Binary)

-- | Event sent when a ResetAttempt failed.
newtype ResetFailure =
    ResetFailure StorageDevice
    deriving (Eq, Show, Binary)
