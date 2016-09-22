{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
module HA.RecoveryCoordinator.Events.Castor.Process
  ( ProcessRecoveryFailure(..)
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
newtype ProcessRecoveryFailure = ProcessRecoveryFailure (Fid, String)
  deriving (Show, Eq, Ord, Generic, Typeable)

instance Binary ProcessRecoveryFailure
instance Hashable ProcessRecoveryFailure

newtype ProcessRestartRequest = ProcessRestartRequest M0.Process
  deriving (Show, Eq, Ord, Typeable, Generic)
instance Binary ProcessRestartRequest
