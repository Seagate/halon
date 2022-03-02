{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright:  (C) 2016 Seagate Technology LLC and/or its Affiliates.
--
-- Helpers that simplifies creation of the long running processes
module HA.RecoveryCoordinator.Job.Events
  ( JobStartRequest(..)
  , JobFinished(..)
  ) where

import HA.RecoveryCoordinator.Job.Internal
import HA.SafeCopy

import Data.Binary (Binary)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)

-- | Request to start a new job.
-- This event starts job with input @a@ but also adds a listener
-- to the rule. This way rule can match the job it's interested
-- in.
data JobStartRequest a = JobStartRequest ListenerId a
  deriving (Typeable, Generic, Show)
deriveSafeCopy 0 'base ''JobStartRequest

-- | Event that is sent when job with listeners finished it's
-- execution.
data JobFinished a = JobFinished [ListenerId] a
  deriving (Typeable, Generic, Show)
instance Binary a => Binary (JobFinished a)
