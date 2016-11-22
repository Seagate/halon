-- |
-- Module    : HA.RecoveryCoordinator.Mero.Actions.Failure
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
module HA.RecoveryCoordinator.Mero.Actions.Failure
  ( Failures(..)
  , PoolVersion(..)
  , UpdateType(..)
  , createPoolVersions
  , getCurrentGraphUpdateType
  ) where

import HA.RecoveryCoordinator.RC.Actions
import HA.RecoveryCoordinator.Mero.Actions.Core
import HA.RecoveryCoordinator.Mero.Failure.Formulaic (formulaicUpdate)
import HA.RecoveryCoordinator.Mero.Failure.Internal
import HA.RecoveryCoordinator.Mero.Failure.Simple  (simpleUpdate)
import HA.Resources.Castor.Initial
import Network.CEP

-- | Load current strategy from resource graph.
getCurrentGraphUpdateType :: Monad m => PhaseM RC l (Maybe (UpdateType m))
getCurrentGraphUpdateType = fmap (mkUpdateType . m0_failure_set_gen) <$> getM0Globals
   where
     mkUpdateType (Preloaded df cf cfe) = simpleUpdate df cf cfe
     mkUpdateType (Formulaic fs) = formulaicUpdate fs
