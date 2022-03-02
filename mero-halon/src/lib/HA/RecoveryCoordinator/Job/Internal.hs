{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
-- |
-- Module   : HA.RecoveryCoordinator.Job.Internal
-- Copyright: (C) 2015-2016 Seagate Technology LLC and/or its Affiliates.
--
-- Internal types for jobs mechanism
module HA.RecoveryCoordinator.Job.Internal
  ( ListenerId(..)
  , JobDescription(..)
  ) where

import Data.Typeable (Typeable)
import Data.UUID
import GHC.Generics
import HA.SafeCopy

-- | Wrapper for listener id.
newtype ListenerId = ListenerId UUID
  deriving (Typeable, Generic, Ord, Eq, Show)
deriveSafeCopy 0 'base ''ListenerId

-- | A description of listeners and requesters of the job.
data JobDescription = JobDescription
  { requestUUIDS :: [UUID]
  , listenersUUIDS :: [ListenerId]
  }

instance Monoid JobDescription where
  mempty = JobDescription [] []
  (JobDescription a b) `mappend` (JobDescription c d) =
    JobDescription (a `mappend` c) (b `mappend` d)

deriveSafeCopy 0 'base ''JobDescription
