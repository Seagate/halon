{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- |
-- Copyright:  (C) 2015 Seagate Technology Limited.
--
module HA.RecoveryCoordinator.Job.Internal
  ( ListenerId(..)
  , JobDescription(..)
  ) where

import Data.UUID
import Data.Binary (Binary)
import Data.Typeable (Typeable)
import GHC.Generics

-- | Wrapper for listener id.
newtype ListenerId = ListenerId UUID
  deriving (Typeable, Generic, Binary, Ord, Eq, Show)

data JobDescription = JobDescription
  { requestUUIDS :: [UUID]
  , listenersUUIDS :: [ListenerId]
  }

instance Monoid JobDescription where
  mempty = JobDescription [] []
  (JobDescription a b) `mappend` (JobDescription c d) =
    JobDescription (a `mappend` c) (b `mappend` d)
