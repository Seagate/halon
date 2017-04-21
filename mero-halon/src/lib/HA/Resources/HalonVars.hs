{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell            #-}
-- |
-- Copyright : (C) 2016 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Dealing with configurable values throughout the halon rules.
module HA.Resources.HalonVars
  ( HalonVars(..)
  , defaultHalonVars
  , module HA.Resources.HalonVars
  ) where

import Data.Binary (Binary)
import Data.Hashable
import Data.Typeable
import GHC.Generics (Generic)
import HA.RecoveryCoordinator.RC.Actions.Core
import HA.ResourceGraph as G
import HA.Resources
import HA.Resources.Castor
import HA.SafeCopy
import Network.CEP

-- | Get 'HalonVars' from RG
getHalonVars :: PhaseM RC l HalonVars
getHalonVars =
    maybe defaultHalonVars id . G.connectedTo Cluster Has <$>
    getLocalGraph

-- | Set a new 'HalonVars' in RG.
setHalonVars :: HalonVars -> PhaseM RC l ()
setHalonVars = modifyGraph . G.connect Cluster Has

-- | Change existing 'HalonVars' in RG.
modifyHalonVars :: (HalonVars -> HalonVars) -> PhaseM RC l ()
modifyHalonVars f = f <$> getHalonVars >>= setHalonVars

-- | Extract a value from 'HalonVars' in RG.
getHalonVar :: (HalonVars -> a) -> PhaseM RC l a
getHalonVar f = f <$> getHalonVars

-- | Set the 'HalonVars' in RG to the variables specified in this
-- message.
newtype SetHalonVars = SetHalonVars HalonVars
  deriving (Show, Eq, Generic, Typeable)
instance Hashable SetHalonVars
deriveSafeCopy 0 'base ''SetHalonVars

-- | 'SetHalonVars' has finished and the 'HalonVars' in this message
-- were set.
newtype HalonVarsUpdated = HalonVarsUpdated HalonVars
  deriving (Show, Eq, Generic, Typeable)
instance Binary HalonVarsUpdated
instance Hashable HalonVarsUpdated
