-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
module HA.RecoveryCoordinator.Actions.Mero.Failure.Simple where

import HA.RecoveryCoordinator.Actions.Mero.Failure.Internal

import qualified HA.ResourceGraph as G
import           HA.Resources
import           HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import Mero.ConfC
  ( Fid
  , PDClustAttr(..)
  , Word128(..)
  )

import           Control.Monad (join)

import           Data.Ratio
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.List ((\\), sort, unfoldr)
import           Data.Maybe (listToMaybe)
import           Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as Map
import           Data.Word

-- | Simple failure set generation strategy. In this case, we pre-generate
--   failure sets for the given number of failures.
simpleStrategy :: Word32 -- ^ No. of disk failures to tolerate
               -> Word32 -- ^ No. of controller failures to tolerate
               -> Word32 -- ^ No. of disk failures equivalent to ctrl failure
               -> Strategy
simpleStrategy df cf cfe = Strategy {
    onInit = \rg ->
      let mchunks = do
            prof <- listToMaybe $ G.connectedTo Cluster Has rg :: Maybe M0.Profile
            fs <- listToMaybe $ G.connectedTo prof M0.IsParentOf rg :: Maybe M0.Filesystem
            globs <- listToMaybe $ G.connectedTo Cluster Has rg :: Maybe M0.M0Globals
            let fsets = generateFailureSets df cf cfe rg globs
                attrs = PDClustAttr {
                          _pa_N = CI.m0_data_units globs
                        , _pa_K = CI.m0_parity_units globs
                        , _pa_P = 0
                        , _pa_unit_size = 4096
                        , _pa_seed = Word128 101 102
                        }
                -- update chunks
            return (flip unfoldr fsets $ \xs ->
                    case xs of
                      [] -> Nothing
                      _  -> Just $ splitAt 5 xs
                    , fs, attrs)
      in case mchunks of
           Nothing -> Nothing
           Just (chunks,fs, attrs) -> Just $ \sync ->
             let go g [] = return g
                 go g (c:cs) =
                    let pvs = fmap (\(fs', fids) -> PoolVersion fids fs' attrs) c
                    in do g' <- sync $ createPoolVersions fs pvs True g
                          go g' cs
             in go rg chunks
  , onFailure = const Nothing
}

generateFailureSets :: Word32 -- ^ No. of disk failures to tolerate
                    -> Word32 -- ^ No. of controller failures to tolerate
                    -> Word32 -- ^ No. of disk failures equivalent to ctrl failure
                    -> G.Graph
                    -> CI.M0Globals
                    -> [(Failures, Set Fid)]
generateFailureSets df cf cfe rg globs = let
    n = CI.m0_data_units globs
    k = CI.m0_parity_units globs
    allCtrls = [ ctrl
                | (host :: Host) <- G.connectedTo Cluster Has rg
                , (ctrl :: M0.Controller) <- G.connectedFrom M0.At host rg
                ]
    -- Look up all disks and the controller they are attached to
    allDisks = Map.fromListWith (Set.union) . fmap (fmap Set.singleton) $
        [ (M0.fid ctrl, M0.fid disk)
        | (_host :: Host) <- G.connectedTo Cluster Has rg
        , ctrl <- allCtrls
        , (disk :: M0.Disk) <- G.connectedTo ctrl M0.IsParentOf rg
        ]

    buildCtrlFailureSet :: Word32 -> HashMap Fid (Set Fid) -> Set (Failures, Set Fid)
    buildCtrlFailureSet i fids = let
        df' = if df > i * cfe then df - (i*cfe) else 0 -- E.g. failures to support on top of ctrl failure
        ctrlFailures = floor $ (fromIntegral (length allCtrls) -i) % (n+k)
        failures = Failures 0 0 0 ctrlFailures k
        keys = sort $ Map.keys fids
        go :: [Fid] -> Set (Failures, Set Fid)  -- FailureSet
        go failedCtrls = let
            okCtrls = keys \\ failedCtrls
            failedCtrlSet :: Set Fid
            failedCtrlSet = Set.fromDistinctAscList failedCtrls
            autoFailedDisks :: Set Fid
            autoFailedDisks = -- E.g. because their parent controller failed
              Set.unions $ fmap (\x -> Map.lookupDefault Set.empty x fids) failedCtrls
            possibleDisks =
              Set.unions $ fmap (\x -> Map.lookupDefault Set.empty x fids) okCtrls
          in
            Set.mapMonotonic (fmap $ \x -> failedCtrlSet
                      `Set.union` (autoFailedDisks `Set.union` x))
                 (buildDiskFailureSets df' possibleDisks failures)
      in
        Set.unions $ go <$> choose i keys

    buildDiskFailureSets :: Word32 -- Max no. failed disks
                         -> Set Fid
                         -> Failures
                         -> Set (Failures, Set Fid)
    buildDiskFailureSets i fids failures =
      Set.unions $ fmap (\j -> buildDiskFailureSet j fids failures) [0 .. i]

    buildDiskFailureSet :: Word32 -- ^ No. failed disks
                        -> Set Fid -- ^ Set of disks
                        -> Failures -- ^ Existing allowed failure map
                        -> Set (Failures, Set Fid)
    buildDiskFailureSet i fids failures =
        Set.fromList $ go <$> (choose i (Set.toList fids))
      where
        go failed = (failures, (Set.fromDistinctAscList failed))

    choose :: Word32 -> [a] -> [[a]]
    choose 0 _ = [[]]
    choose _ [] = []
    choose z (x:xs) = ((x:) <$> choose (z-1) xs) ++ choose z xs

  in join $
    fmap (\j -> Set.toList $ buildCtrlFailureSet j allDisks) [0 .. cf]
