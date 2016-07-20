{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
module HA.RecoveryCoordinator.Events.Castor.Process
  ( ProcessRecoveryFailure(..)
  ) where

import           Data.Binary
import           Data.Hashable
import           Data.Typeable
import           GHC.Generics
import qualified HA.Resources.Mero as M0
import           Mero.ConfC (Fid)

newtype ProcessRecoveryFailure = ProcessRecoveryFailure (Fid, String)
  deriving (Show, Eq, Ord, Generic, Typeable)

instance Binary ProcessRecoveryFailure
instance Hashable ProcessRecoveryFailure
