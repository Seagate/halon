-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
module HA.RecoveryCoordinator.Mero.Failure.Formulaic  -- XXX RENAMEME
  ( addPVerFormulaic
  , formulaicUpdate
  ) where

import           Control.Exception (assert)
import           Control.Monad.Trans.State (execState, modify, modify', state)
import           Data.Bifunctor (first)
import           Data.Bits (setBit, testBit)
import           Data.Either (isRight)
import           Data.Foldable (for_)
import           Data.Proxy (Proxy(..))
import qualified Data.Set as Set
import           HA.RecoveryCoordinator.Mero.Actions.Core
  ( newFid
  , uniquePVerCounter
  )
import           HA.RecoveryCoordinator.Mero.Failure.Internal
  ( ConditionOfDevices(DevicesFailed)
  , UpdateType(Monolithic)
  , PoolVersion(..)
  , UpdateType
  , createPoolVersions
  )
import qualified HA.ResourceGraph as G
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import           Mero.ConfC (Fid(..), PDClustAttr(..), Word128(..))

-- | Generate formulaic pool version and link it to the @pool@.
addPVerFormulaic :: M0.Pool -> M0.PVer -> CI.Failures -> G.Graph -> G.Graph
addPVerFormulaic pool base allowance rg = flip execState rg $ do
    assert (isRight $ M0.v_data base) (pure ())
    fid <- state (first toFormulaic . newFid (Proxy :: Proxy M0.PVer))
    idx <- state uniquePVerCounter
    let pvf = M0.PVerFormulaic idx (M0.fid base) (CI.failuresToList allowance)
        pver = M0.PVer fid (Left pvf)
    modify' $ G.connect pool M0.IsParentOf pver

-- | Set "kind" bit of a pver fid, making it a formulaic pver.
--
-- See https://github.com/seagate-ssg/mero/blob/master/doc/formulaic-pvers.org#fid-formats
toFormulaic :: Fid -> Fid
toFormulaic fid@(Fid container key)
  | not $ M0.fidIsType (Proxy :: Proxy M0.PVer) fid = error "Invalid fid type"
  | container `testBit` 55                          = error "Invalid container"
  | otherwise = Fid (container `setBit` 54) key

----------------------------------------------------------------------
-- XXX-MULTIPOOLS: DELETEME

-- | Sets "kind" bit of a pver fid, making it a formulaic pver.
--
-- See https://github.com/seagate-ssg/mero/blob/master/doc/formulaic-pvers.org#fid-formats
mkPVerFormulaicFid :: Fid -> Either String Fid
mkPVerFormulaicFid fid@(Fid container key)
  | not $ M0.fidIsType (Proxy :: Proxy M0.PVer) fid = Left "Invalid fid type"
  | container `testBit` 55                          = Left "Invalid container"
  | otherwise = Right $ Fid (container `setBit` 54) key

-- | Formulaic 'UpdateType'.
formulaicUpdate :: Monad m => [CI.Failures] -> UpdateType m
formulaicUpdate formulas = Monolithic $ \rg -> maybe (return rg) return $ do
  let root = M0.getM0Root rg
      data_units = error "XXX IMPLEMENTME"
      parity_units = error "XXX IMPLEMENTME"
      attrs = PDClustAttr
                { _pa_N = data_units    -- XXX 2
                , _pa_K = parity_units  -- XXX 1
                , _pa_P = 0
                , _pa_unit_size = 4096
                , _pa_seed = Word128 101 102
                }
      mdpool = M0.Pool (M0.rt_mdpool root)
      imeta_pver = M0.rt_imeta_pver root
      n = data_units
      k = parity_units
      -- XXX-MULTIPOOLS: This calculation is wrong --- it assumes that
      -- there is only one pool, while in fact there may be several
      -- specified in the _facts_ file.
      noCtrls = length  -- XXX 5
        [ ctrl
        | site :: M0.Site <- G.connectedTo root M0.IsParentOf rg
        , rack :: M0.Rack <- G.connectedTo site M0.IsParentOf rg
        , encl :: M0.Enclosure <- G.connectedTo rack M0.IsParentOf rg
        , ctrl :: M0.Controller <- G.connectedTo encl M0.IsParentOf rg
        ]
      -- Following change is temporary, and would work as long as failures
      -- above controllers (encl, racks) are not to be supported
      -- (ref. HALON-406)
      parityGroupSize = n + 2*k  -- XXX 4
      quotient =  parityGroupSize `quot` fromIntegral noCtrls  -- XXX 0
      remainder = parityGroupSize `rem` fromIntegral noCtrls   -- XXX 4
      kc = remainder * (quotient + 1)  -- XXX 4
      ctrlFailures
          | kc > k = k `quot` (quotient + 1)  -- XXX 1
          | kc < k = (k - remainder) `quot` quotient
          | otherwise = remainder

      addFormulas :: G.Graph -> G.Graph
      addFormulas g = flip execState g $ do
        for_ (filter (/= mdpool) $ G.connectedTo root M0.IsParentOf g) $
          \(pool :: M0.Pool) ->
          for_ (filter ((/= imeta_pver) . M0.fid) $ G.connectedTo pool M0.IsParentOf g) $
            \(pver :: M0.PVer) -> do
            for_ formulas $ \f -> do
              let mkFormulaic :: Fid -> Fid
                  mkFormulaic = either error id . mkPVerFormulaicFid
              pvf <- M0.PVer <$> state (first mkFormulaic . newFid (Proxy :: Proxy M0.PVer))
                             <*> (Left <$> (M0.PVerFormulaic <$> state uniquePVerCounter
                                                             <*> pure (M0.fid pver)
                                                             <*> pure (CI.failuresToList f)))
              modify $ G.connect pool M0.IsParentOf pvf

      pv = PoolVersion Nothing Set.empty (CI.Failures 0 0 0 ctrlFailures k) attrs

  Just . addFormulas $ createPoolVersions [pv] DevicesFailed rg
