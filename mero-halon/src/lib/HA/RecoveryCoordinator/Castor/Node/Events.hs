{-# LANGUAGE TemplateHaskell #-}
-- |
-- Module    : HA.RecoveryCoordinator.Castor.Node.Events
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
module HA.RecoveryCoordinator.Castor.Node.Events where

import           Data.Binary (Binary)
import           Data.SafeCopy
import           GHC.Generics
import qualified HA.Resources as R

-- | Request start of the 'ruleNewNode'.
newtype StartProcessNodeNew = StartProcessNodeNew R.Node
  deriving (Eq, Show, Generic, Binary, Ord)
deriveSafeCopy 0 'base ''StartProcessNodeNew
