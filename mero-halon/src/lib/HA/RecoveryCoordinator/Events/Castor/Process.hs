{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
module HA.RecoveryCoordinator.Events.Castor.Process
  ( ProcessRecoveryResult(..)
  , ProcessRestartRequest(..)
  ) where

import           Data.Binary
import           Data.Hashable
import           Data.Typeable
import           GHC.Generics
import qualified HA.Resources.Mero as M0
import           Mero.ConfC (Fid)

-- | Event is arrived in case if recovery failed, this event goes
-- via replicated state.
data ProcessRecoveryResult
  = ProcessRecoveryFailure (Fid, String)
    -- ^ When process recovery fails
  | ProcessRecoveryNotNeeded Fid
    -- ^ When there is no need to recover the process,
    -- due to e.g. cluster state being invalid.
  deriving (Show, Eq, Ord, Generic, Typeable)

instance Binary ProcessRecoveryResult
instance Hashable ProcessRecoveryResult

newtype ProcessRestartRequest = ProcessRestartRequest M0.Process
  deriving (Show, Eq, Ord, Typeable, Generic)
instance Binary ProcessRestartRequest
