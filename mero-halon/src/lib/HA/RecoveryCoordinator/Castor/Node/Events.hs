{-# LANGUAGE TemplateHaskell #-}
-- |
-- Module    : HA.RecoveryCoordinator.Castor.Node.Events
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
module HA.RecoveryCoordinator.Castor.Node.Events where

import           GHC.Generics
import qualified HA.Resources as R
import           HA.SafeCopy

-- | Request start of the 'ruleNewNode'.
newtype StartProcessNodeNew = StartProcessNodeNew R.Node
  deriving (Eq, Show, Generic, Ord)
deriveSafeCopy 0 'base ''StartProcessNodeNew
