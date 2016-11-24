{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright:  (C) 2015 Seagate Technology Limited.
--
module HA.RecoveryCoordinator.Job.Internal
  ( ListenerId(..)
  , JobDescription(..)
  ) where

import Data.UUID
import Data.Typeable (Typeable)
import GHC.Generics
import HA.SafeCopy

-- | Wrapper for listener id.
newtype ListenerId = ListenerId UUID
  deriving (Typeable, Generic, Ord, Eq, Show)
deriveSafeCopy 0 'base ''ListenerId

data JobDescription = JobDescription
  { requestUUIDS :: [UUID]
  , listenersUUIDS :: [ListenerId]
  }

instance Monoid JobDescription where
  mempty = JobDescription [] []
  (JobDescription a b) `mappend` (JobDescription c d) =
    JobDescription (a `mappend` c) (b `mappend` d)

deriveSafeCopy 0 'base ''JobDescription
