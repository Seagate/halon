-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
module HA.RecoveryCoordinator.Actions.Mero.Failure.Formulaic where

import HA.RecoveryCoordinator.Actions.Mero.Core
import HA.RecoveryCoordinator.Actions.Mero.Failure.Internal
import qualified HA.ResourceGraph as G
import           HA.Resources
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import Mero.ConfC
  ( PDClustAttr(..)
  , Word128(..)
  )

import Control.Monad.Trans.State (execState, modify, state)
import Data.Bifunctor (first)
import Data.Maybe (listToMaybe)
import Data.Foldable (for_)
import Data.Proxy (Proxy(..))
import Data.Word
import qualified Data.Set as Set

formulaicStrategy :: [[Word32]] -> Strategy
formulaicStrategy formulas = Strategy
  { onInit = \rg -> do
      prof <- listToMaybe $ G.connectedTo Cluster Has rg :: Maybe M0.Profile
      fs   <- listToMaybe $ G.connectedTo prof M0.IsParentOf rg :: Maybe M0.Filesystem
      globs <- listToMaybe $ G.connectedTo Cluster Has rg :: Maybe M0.M0Globals
      let attrs = PDClustAttr
                    { _pa_N = CI.m0_data_units globs
                    , _pa_K = CI.m0_parity_units globs
                    , _pa_P = 0
                    , _pa_unit_size = 4096
                    , _pa_seed = Word128 101 102
                    }
          addFormulas g = flip execState g $ do
            for_ (G.connectedTo fs M0.IsParentOf g) $ \(pool::M0.Pool) -> do
              for_ (G.connectedTo pool M0.IsRealOf g) $ \(pver::M0.PVer) -> do
                for_ formulas $ \formula -> do
                  pvf <- M0.PVer <$> state (first mkVirtualFid . newFid (Proxy :: Proxy M0.PVer))
                                 <*> (M0.PVerFormulaic <$> state uniquePVerCounter
                                                       <*> pure formula
                                                       <*> pure (M0.fid pver))
                  modify (G.connect pool M0.IsRealOf pvf)
      (flip id) <$> Just (addFormulas $ createPoolVersions fs
           [PoolVersion Set.empty (Failures 0 0 0 0 0) attrs] True rg)
  , onFailure = const Nothing
  }