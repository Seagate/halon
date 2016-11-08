{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- |
-- Module   : HA.RecoveryCoordinator.Job.Internal
-- Copyright: (C) 2015-2016 Seagate Technology Limited.
--
-- Internal types for jobs mechanism
module HA.RecoveryCoordinator.Job.Internal
  ( ListenerId(..)
  , JobDescription(..)
  ) where

import Data.Binary (Binary)
import Data.Typeable (Typeable)
import Data.UUID
import GHC.Generics

-- | Wrapper for listener id.
newtype ListenerId = ListenerId UUID
  deriving (Typeable, Generic, Binary, Ord, Eq, Show)

-- | A description of listeners and requesters of the job.
data JobDescription = JobDescription
  { requestUUIDS :: [UUID]
  , listenersUUIDS :: [ListenerId]
  }

instance Monoid JobDescription where
  mempty = JobDescription [] []
  (JobDescription a b) `mappend` (JobDescription c d) =
    JobDescription (a `mappend` c) (b `mappend` d)
