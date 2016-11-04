{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
module HA.RecoveryCoordinator.Events.Castor.Process
  ( ProcessStartRequest(..)
  , ProcessStartResult(..)
  ) where

import           Data.Binary
import           Data.Typeable
import           GHC.Generics
import qualified HA.Resources.Mero as M0

-- | Request that process be started.
newtype ProcessStartRequest = ProcessStartRequest M0.Process
  deriving (Show, Eq, Ord, Typeable, Generic)
instance Binary ProcessStartRequest

-- | Reply in job handling 'ProcessStartRequest'
data ProcessStartResult = ProcessStarted M0.Process
                        | ProcessStartFailed M0.Process String
  deriving (Show, Eq, Ord, Typeable, Generic)
instance Binary ProcessStartResult
