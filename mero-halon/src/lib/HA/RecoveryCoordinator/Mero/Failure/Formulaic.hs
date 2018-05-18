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
import           Data.Proxy (Proxy(..))
import qualified Data.Set as Set
import           Data.Word
import           HA.RecoveryCoordinator.Mero.Actions.Core
import           HA.RecoveryCoordinator.Mero.Failure.Internal
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..), Has(..))
import qualified HA.Resources.Castor.Initial as CI
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
  globs <- G.connectedTo Cluster Has rg :: Maybe M0.M0Globals
  let root = M0.getM0Root rg
      -- XXX-MULTIPOOLS: Global PDClustAttr makes no sense, there should be
      -- one PDClustAttr per pool.
      attrs = PDClustAttr
                { _pa_N = CI.m0_data_units globs
                , _pa_K = CI.m0_parity_units globs
                , _pa_P = 0
                , _pa_unit_size = 4096
                , _pa_seed = Word128 101 102
                }
      mdpool = M0.Pool (M0.rt_mdpool root)
      imeta_pver = M0.rt_imeta_pver root
      n = CI.m0_data_units globs
      k = CI.m0_parity_units globs
      -- XXX-MULTIPOOLS: This calculation is wrong --- it assumes that
      -- there is only one pool, while in fact there may be several
      -- specified in the _facts_ file.
      noCtrls = length
        [ ctrl
        | site :: M0.Site <- G.connectedTo root M0.IsParentOf rg
        , rack :: M0.Rack <- G.connectedTo site M0.IsParentOf rg
        , encl :: M0.Enclosure <- G.connectedTo rack M0.IsParentOf rg
        , ctrl :: M0.Controller <- G.connectedTo encl M0.IsParentOf rg
        ]
      -- Following change is temporary, and would work as long as failures
      -- above controllers (encl, racks) are not to be supported
      -- (ref. HALON-406)
      quotient =  (n + 2*k) `quot` fromIntegral noCtrls
      remainder = (n + 2*k) `rem` fromIntegral noCtrls
      kc = remainder * (quotient + 1)
      ctrlFailures
          | kc > k = k `quot` (quotient + 1)
          | kc < k = (k - remainder) `quot` quotient
          | otherwise = remainder

      addFormulas :: G.Graph -> G.Graph
      addFormulas g = flip execState g $ do
        for_ (filter (/= mdpool) $ G.connectedTo root M0.IsParentOf g) $
          \(pool :: M0.Pool) ->
          for_ (filter ((/= imeta_pver) . M0.fid) $ G.connectedTo pool M0.IsParentOf g) $
            \(pver :: M0.PVer) -> do
            for_ formulas $ \formula -> do
              let mkFormulaic :: Fid -> Fid
                  mkFormulaic = either error id . mkPVerFormulaicFid
              pvf <- M0.PVer <$> state (first mkFormulaic . newFid (Proxy :: Proxy M0.PVer))
                             <*> (Left <$> (M0.PVerFormulaic <$> state uniquePVerCounter
                                                             <*> pure (M0.fid pver)
                                                             <*> pure formula))
              modify $ G.connect pool M0.IsParentOf pvf

      pv = PoolVersion Nothing Set.empty (Failures 0 0 0 ctrlFailures k) attrs

  Just . addFormulas $ createPoolVersions [pv] DevicesFailed rg
