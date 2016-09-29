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
  { onInit = Monolithic $ \rg -> maybe (return rg) return $ do
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

          mdpool = M0.Pool (M0.f_mdpool_fid fs)
          n = CI.m0_data_units globs
          k = CI.m0_parity_units globs
          noCtlrs = length [ cntr
                     | rack :: M0.Rack <- G.connectedTo fs M0.IsParentOf rg
                     , encl :: M0.Enclosure <- G.connectedTo rack M0.IsParentOf rg
                     , cntr :: M0.Controller <- G.connectedTo encl M0.IsParentOf rg
                     ]
        -- Following change is temporary, and would work as long as failures
        -- above controllers (encl, racks) are not to be supported
        -- (ref. HALON-406)
          quotient =  (n + 2*k) `quot` (fromIntegral noCtlrs)
          remainder = (n + 2*k) `rem` (fromIntegral noCtlrs)
          kc = remainder * (quotient + 1)
          ctrlFailures
              | kc > k = k `quot` (quotient + 1)
              | kc < k = (k - remainder) `quot` quotient
              | otherwise = remainder
          addFormulas g = flip execState g $ do
            for_ (filter (/= mdpool) $ G.connectedTo fs M0.IsParentOf g) $ \(pool::M0.Pool) -> do
              for_ (G.connectedTo pool M0.IsRealOf g) $ \(pver::M0.PVer) -> do
                for_ formulas $ \formula -> do
                  pvf <- M0.PVer <$> state (first mkVirtualFid . newFid (Proxy :: Proxy M0.PVer))
                                 <*> (M0.PVerFormulaic <$> state uniquePVerCounter
                                                       <*> pure formula
                                                       <*> pure (M0.fid pver))
                  modify (G.connect pool M0.IsRealOf pvf)
      Just (addFormulas $ createPoolVersions fs
                            [PoolVersion Set.empty (Failures 0 0 0 ctrlFailures k) attrs] True rg)
  , onFailure = const Nothing
  }
