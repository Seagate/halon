-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
{-# LANGUAGE LambdaCase #-}
module HA.RecoveryCoordinator.Actions.Mero.Failure
  ( Failures(..)
  , PoolVersion(..)
  , Strategy(..)
  , createPoolVersions
  , getCurrentStrategy
  ) where

import HA.RecoveryCoordinator.Actions.Mero.Core
import HA.RecoveryCoordinator.Actions.Mero.Failure.Dynamic (dynamicStrategy)
import HA.RecoveryCoordinator.Actions.Mero.Failure.Simple  (simpleStrategy)
import HA.RecoveryCoordinator.Actions.Mero.Failure.Internal
import qualified HA.Resources.Castor.Initial as CI

import HA.RecoveryCoordinator.Actions.Core
import Network.CEP

-- | Load current strategy from resource graph.
getCurrentStrategy :: PhaseM LoopState l (Maybe Strategy)
getCurrentStrategy = fmap (mkStrategy . CI.m0_failure_set_gen) <$> getM0Globals
   where
     mkStrategy CI.Dynamic = dynamicStrategy
     mkStrategy ( CI.Preloaded df cf cfe) = simpleStrategy df cf cfe

