-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
module HA.RecoveryCoordinator.Mero.Failure.Formulaic
  ( formulaicUpdate
  ) where

import           Control.Monad.Trans.State (execState, modify, state)
import           Data.Bifunctor (first)
import           Data.Bits (setBit, testBit)
import           Data.Foldable (for_)
import           Data.Maybe (listToMaybe)
import           Data.Proxy (Proxy(..))
import qualified Data.Set as Set
import           Data.Word
import           HA.RecoveryCoordinator.Mero.Actions.Core
import           HA.RecoveryCoordinator.Mero.Failure.Internal
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..), Has(..))
import           HA.Resources.Castor.Initial (m0_data_units_XXX0, m0_parity_units_XXX0)
import qualified HA.Resources.Mero as M0
import           Mero.ConfC (Fid(..), PDClustAttr(..), Word128(..))

-- | Sets "kind" bit of a pver fid, making it a formulaic pver.
--
-- See https://github.com/seagate-ssg/mero/blob/master/doc/formulaic-pvers.org#fid-formats
mkPVerFormulaicFid :: Fid -> Either String Fid
mkPVerFormulaicFid fid@(Fid container key)
  | not $ M0.fidIsType (Proxy :: Proxy M0.PVer) fid = Left "Invalid fid type"
  | container `testBit` 55                          = Left "Invalid container"
  | otherwise = Right $ Fid (container `setBit` 54) key

-- | Formulaic 'UpdateType'.
formulaicUpdate :: Monad m => [[Word32]] -> UpdateType m
formulaicUpdate formulas = Monolithic $ \rg -> maybe (return rg) return $ do
  prof <- G.connectedTo Cluster Has rg :: Maybe M0.Profile
  fs   <- listToMaybe $ -- TODO: Don't ignore the remaining filesystems
    G.connectedTo prof M0.IsParentOf rg :: Maybe M0.Filesystem
  globs <- G.connectedTo Cluster Has rg :: Maybe M0.M0Globals_XXX0
  let attrs = PDClustAttr
                { pa_N = m0_data_units_XXX0 globs
                , pa_K = m0_parity_units_XXX0 globs
                , pa_P = 0
                , pa_unit_size = 4096
                , pa_seed = Word128 101 102
                }
      mdpool = M0.Pool (M0.f_mdpool_fid fs)
      imeta_pver = M0.f_imeta_fid fs
      n = m0_data_units_XXX0 globs
      k = m0_parity_units_XXX0 globs
      noCtlrs = length
        [ cntr
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
        for_ (filter (/= mdpool) $
          G.connectedTo fs M0.IsParentOf g) $ \(pool::M0.Pool) ->
          for_ (filter ((/= imeta_pver) . M0.fid) $ G.connectedTo pool M0.IsParentOf g) $
            \(pver::M0.PVer) -> do
            for_ formulas $ \formula -> do
              let f = either error id . mkPVerFormulaicFid
              pvf <- M0.PVer <$> state (first f . newFid (Proxy :: Proxy M0.PVer))
                             <*> (M0.PVerFormulaic <$> state uniquePVerCounter
                                                   <*> pure formula
                                                   <*> pure (M0.fid pver))
              modify (G.connect pool M0.IsParentOf pvf)
  Just (addFormulas $ createPoolVersions fs
                        [PoolVersion Nothing Set.empty (Failures 0 0 0 ctrlFailures k) attrs] True rg)
