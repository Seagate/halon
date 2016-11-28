{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
module HA.RecoveryCoordinator.Castor.Process.Events
  ( ProcessStartRequest(..)
  , ProcessStartResult(..)
  ) where

import           Data.Typeable
import           GHC.Generics
import qualified HA.Resources.Mero as M0
import           HA.SafeCopy

-- | Request that process be started.

newtype ProcessStartRequest = ProcessStartRequest M0.Process
  deriving (Show, Eq, Ord, Typeable, Generic)
deriveSafeCopy 0 'base ''ProcessStartRequest

-- | Reply in job handling 'ProcessStartRequest'
data ProcessStartResult = ProcessStarted M0.Process
                        | ProcessStartFailed M0.Process String
  deriving (Show, Eq, Ord, Typeable, Generic)
deriveSafeCopy 0 'base ''ProcessStartResult
