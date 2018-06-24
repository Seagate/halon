-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
module HA.RecoveryCoordinator.Mero.Failure.Formulaic  -- XXX RENAMEME
  ( addPVerFormulaic
  , formulaicUpdate  -- XXX DELETEME
  , newPVerRC
  ) where

import           Control.Category ((>>>))
import           Control.Exception (assert)
import           Control.Monad (when)
import qualified Control.Monad.Trans.State as S
import           Data.Bifunctor (first)
import           Data.Bits (setBit, testBit)
import           Data.Either (isRight)
import           Data.Foldable (for_)
import qualified Data.Map.Strict as Map
import           Data.Maybe (fromMaybe, isNothing)
import           Data.Proxy (Proxy(..))
import qualified Data.Set as Set
import           HA.RecoveryCoordinator.Mero.Actions.Core
  ( newFid
  , newFidRC
  , uniquePVerCounter
  )
import           HA.RecoveryCoordinator.Mero.Failure.Internal
  ( ConditionOfDevices(DevicesFailed)
  , UpdateType(Monolithic)
  , PoolVersion(..)
  , UpdateType
  , createPoolVersions
  )
import           HA.RecoveryCoordinator.RC.Actions.Core (getGraph, modifyGraph)
import           HA.RecoveryCoordinator.RC.Application (RC)
import qualified HA.ResourceGraph as G
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import           Mero.ConfC (Fid(..), PDClustAttr(..), Word128(..))
import           Network.CEP (PhaseM)

-- | State updated during pool version tree construction.
type PVerSt
  = ( G.Graph          -- ^ Resource graph.
    , Map.Map Fid Fid  -- ^ Pool version devices.  Maps fid of real object
                       --   to the fid of corresponding virtual object.
    )

-- | Generate new 'Fid' for the given 'M0.ConfObj' type.
newFidPVerGen :: M0.ConfObj a => Proxy a -> Fid -> S.State PVerSt Fid
newFidPVerGen p real = do
    (rg, devs) <- S.get
    assert (Map.notMember real devs) (pure ())
    let (virt, rg') = newFid p rg
        devs' = Map.insert real virt devs
    S.put (rg', devs')
    pure virt

-- | Build pool version tree.
buildPVerTree :: M0.PVer -> [M0.Disk] -> S.State PVerSt ()
buildPVerTree pver disks = for_ disks $ \disk -> do
    let modifyG = S.modify' . first

    -- Disk level
    diskv <- M0.DiskV <$>
        newFidPVerGen (Proxy :: Proxy M0.DiskV) (M0.fid disk)
    modifyG $ G.connect disk M0.IsRealOf diskv

    -- Controller level
    (ctrl :: M0.Controller, mctrlv_fid) <- S.gets $ \(rg, devs) ->
        let Just ctrl = G.connectedFrom M0.IsParentOf disk rg
        in (ctrl, Map.lookup (M0.fid ctrl) devs)
    ctrlv <- M0.ControllerV <$>
        maybe (newFidPVerGen (Proxy :: Proxy M0.ControllerV) (M0.fid ctrl))
              pure
              mctrlv_fid
    when (isNothing mctrlv_fid) $
        modifyG $ G.connect ctrl M0.IsRealOf ctrlv
    modifyG $ G.connect ctrlv M0.IsParentOf diskv

    -- Enclosure level
    (encl :: M0.Enclosure, menclv_fid) <- S.gets $ \(rg, devs) ->
        let Just encl = G.connectedFrom M0.IsParentOf ctrl rg
        in (encl, Map.lookup (M0.fid encl) devs)
    enclv <- M0.EnclosureV <$>
        maybe (newFidPVerGen (Proxy :: Proxy M0.EnclosureV) (M0.fid encl))
              pure
              menclv_fid
    when (isNothing menclv_fid) $
        modifyG $ G.connect encl M0.IsRealOf enclv
    modifyG $ G.connect enclv M0.IsParentOf ctrlv

    -- Rack level
    (rack :: M0.Rack, mrackv_fid) <- S.gets $ \(rg, devs) ->
        let Just rack = G.connectedFrom M0.IsParentOf encl rg
        in (rack, Map.lookup (M0.fid rack) devs)
    rackv <- M0.RackV <$>
        maybe (newFidPVerGen (Proxy :: Proxy M0.RackV) (M0.fid rack))
              pure
              mrackv_fid
    when (isNothing mrackv_fid) $
        modifyG $ G.connect rack M0.IsRealOf rackv
    modifyG $ G.connect rackv M0.IsParentOf enclv

    -- Site level
    (site :: M0.Site, msitev_fid) <- S.gets $ \(rg, devs) ->
        let Just site = G.connectedFrom M0.IsParentOf rack rg
        in (site, Map.lookup (M0.fid site) devs)
    sitev <- M0.SiteV <$>
        maybe (newFidPVerGen (Proxy :: Proxy M0.SiteV) (M0.fid site))
              pure
              msitev_fid
    when (isNothing msitev_fid) $
        modifyG $ G.connect site M0.IsRealOf sitev
    modifyG $ G.connect sitev M0.IsParentOf rackv
          >>> G.connect pver M0.IsParentOf sitev

-- | Create actual ("base") pool version.
newPVerRC :: Maybe Fid -> CI.PDClustAttrs0 -> Maybe CI.Failures -> [M0.Disk]
          -> PhaseM RC l M0.PVer
newPVerRC mfid CI.PDClustAttrs0{..} mtolerated disks = do
    assert (fromMaybe True $ M0.fidIsType (Proxy :: Proxy M0.PVer) <$> mfid)
        (pure ())
    assert (Set.size (Set.fromList disks) == length disks) (pure ())
    let attrs = PDClustAttr { _pa_N = pa0_data_units
                            , _pa_K = pa0_parity_units
                            , _pa_P = fromIntegral (length disks)
                            , _pa_unit_size = pa0_unit_size
                            , _pa_seed = pa0_seed
                            }
        tolerance rg = CI.failuresToList $
            fromMaybe (toleratedFailures rg) mtolerated
    pver <- M0.PVer <$> maybe (newFidRC (Proxy :: Proxy M0.PVer)) pure mfid
                    <*> (pure . Right . M0.PVerActual attrs . tolerance
                         =<< getGraph)
    modifyGraph $ \rg ->
        fst $ S.execState (buildPVerTree pver disks) (rg, Map.empty)
    pure pver
  where
    toleratedFailures :: G.Graph -> CI.Failures
    toleratedFailures rg =
        let n = pa0_data_units
            k = pa0_parity_units
            nrCtrls = fromIntegral $ Set.size $ Set.fromList
              [ M0.fid ctrl
              | disk <- disks
              , let Just (ctrl :: M0.Controller) =
                        G.connectedFrom M0.IsParentOf disk rg
              ]
            -- XXX Failures above controllers are not currently supported
            -- (ref. HALON-406).
            (q, r) = (n + 2*k) `quotRem` nrCtrls
            kc = r * (q + 1)  -- XXX What's this?
            ctrlFailures  -- XXX TODO: explain this formula
              | kc > k    = k `quot` (q + 1)
              | kc < k    = (k - r) `quot` q
              | otherwise = r
        in CI.Failures 0 0 0 ctrlFailures k

-- | Create formulaic pool version and link it to the @pool@.
addPVerFormulaic :: M0.Pool -> M0.PVer -> CI.Failures -> G.Graph -> G.Graph
addPVerFormulaic pool base allowance rg = flip S.execState rg $ do
    assert (isRight $ M0.v_data base) (pure ())
    fid <- S.state (first toFormulaic . newFid (Proxy :: Proxy M0.PVer))
    idx <- S.state uniquePVerCounter
    let pvf = M0.PVerFormulaic idx (M0.fid base) (CI.failuresToList allowance)
        pver = M0.PVer fid (Left pvf)
    S.modify' $ G.connect pool M0.IsParentOf pver

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
      addFormulas g = flip S.execState g $ do
        for_ (filter (/= mdpool) $ G.connectedTo root M0.IsParentOf g) $
          \(pool :: M0.Pool) ->
          for_ (filter ((/= imeta_pver) . M0.fid) $ G.connectedTo pool M0.IsParentOf g) $
            \(pver :: M0.PVer) -> do
            for_ formulas $ \f -> do
              let mkFormulaic :: Fid -> Fid
                  mkFormulaic = either error id . mkPVerFormulaicFid
              pvf <- M0.PVer <$> S.state (first mkFormulaic . newFid (Proxy :: Proxy M0.PVer))
                             <*> (Left <$> (M0.PVerFormulaic <$> S.state uniquePVerCounter
                                                             <*> pure (M0.fid pver)
                                                             <*> pure (CI.failuresToList f)))
              S.modify $ G.connect pool M0.IsParentOf pvf

      pv = PoolVersion Nothing Set.empty (CI.Failures 0 0 0 ctrlFailures k) attrs

  Just . addFormulas $ createPoolVersions [pv] DevicesFailed rg
