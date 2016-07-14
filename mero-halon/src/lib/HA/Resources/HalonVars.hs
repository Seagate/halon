{-# LANGUAGE LambdaCase #-}
-- |
-- Copyright : (C) 2016 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Dealing with configurable values throughout the halon rules.

module HA.Resources.HalonVars
  ( HalonVars(..)
  , defaultHalonVars
  , getHalonVar
  , getHalonVars
  , modifyHalonVars
  ) where

import HA.RecoveryCoordinator.Actions.Core
import HA.ResourceGraph as G
import HA.Resources.Castor
import Network.CEP
import HA.Resources

-- | Default value for 'HalonVars'
defaultHalonVars :: HalonVars
defaultHalonVars = HalonVars
  { _hv_recovery_expiry_seconds = 300
  , _hv_recovery_max_retries = 5
  }

-- | Get 'HalonVars' from RG
getHalonVars :: PhaseM LoopState l HalonVars
getHalonVars = G.connectedTo Cluster Has <$> getLocalGraph >>= return . \case
  hv : _ -> hv
  _ -> defaultHalonVars

-- | Set a new 'HalonVars' in RG.
setHalonVars :: HalonVars -> PhaseM LoopState l ()
setHalonVars = modifyGraph . G.connectUniqueFrom Cluster Has

-- | Change existing 'HalonVars' in RG.
modifyHalonVars :: (HalonVars -> HalonVars) -> PhaseM LoopState l ()
modifyHalonVars f = f <$> getHalonVars >>= setHalonVars

-- | Extract a value from 'HalonVars' in RG.
getHalonVar :: (HalonVars -> a) -> PhaseM LoopState l a
getHalonVar f = f <$> getHalonVars
