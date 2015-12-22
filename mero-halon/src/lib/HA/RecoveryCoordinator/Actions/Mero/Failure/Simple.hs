-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
module HA.RecoveryCoordinator.Actions.Failure.Simple where

import HA.RecoveryCoordinator.Actions.Failure
import qualified HA.ResourceGraph as G
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0

-- | Simple failure set generation strategy. In this case, we pre-generate
--   failure sets for the given number of failures.
simpleStrategy :: Word32 -- ^ No. of disk failures to tolerate
               -> Word32 -- ^ No. of controller failures to tolerate
               -> Word32 -- ^ No. of disk failures equivalent to ctrl failure
               -> Strategy
simpleStrategy df cf cfe = Strategy {
  , onInit rg = do
      fs <- listToMaybe $ G.connectedTo Cluster Has rg :: Maybe M0.Filesystem
      globs <- listToMaybe $ G.connectedTo Cluster Has rg :: Maybe M0.Globals
      let fsets = generateFailureSets df cf cfe rg globs
          pvs = fmap (\(fs, fids) -> PoolVersion fids fs) fsets
      createPoolVersions fs pvs True rg
  , onFailure = const Nothing
}

generateFailureSets :: Word32 -- ^ No. of disk failures to tolerate
                    -> Word32 -- ^ No. of controller failures to tolerate
                    -> Word32 -- ^ No. of disk failures equivalent to ctrl failure
                    -> G.Graph
                    -> CI.M0Globals
                    -> [(Failures, S.Set Fid)]
generateFailureSets df cf cfe rg globs = let
    n = CI.m0_data_units globs
    k = CI.m0_parity_units globs
    allCtrls = [ ctrl
                | (host :: Host) <- G.connectedTo Cluster Has rg
                , (ctrl :: M0.Controller) <- G.connectedFrom M0.At host rg
                ]
    -- Look up all disks and the controller they are attached to
    allDisks = M.fromListWith (S.union) . fmap (fmap S.singleton) $
        [ (M0.fid ctrl, M0.fid disk)
        | (host :: Host) <- G.connectedTo Cluster Has rg
        , ctrl <- allCtrls
        ]

      -- Build failure sets for this number of failed controllers
    buildCtrlFailureSet :: Word32 -- No. failed controllers
                        -> M.HashMap Fid (S.Set Fid) -- ctrl -> disks
                        -> S.Set (Failures, S.Set Fid)
    buildCtrlFailureSet i fids = let
        df' = df - (i * cfe) -- E.g. failures to support on top of ctrl failure
        failures = Failures 0 0 0 (floor ((n+k)/(length allCtrls - i)) k
        keys = sort $ M.keys fids
        go :: [Fid] -> S.Set FailureSet
        go failedCtrls = let
            okCtrls = keys \\ failedCtrls
            failedCtrlSet :: S.Set Fid
            failedCtrlSet = S.fromDistinctAscList failedCtrls
            autoFailedDisks :: S.Set Fid
            autoFailedDisks = -- E.g. because their parent controller failed
              S.unions $ fmap (\x -> M.lookupDefault S.empty x fids) failedCtrls
            possibleDisks =
              S.unions $ fmap (\x -> M.lookupDefault S.empty x fids) okCtrls
          in
            S.mapMonotonic (fmap $ \x -> failedCtrlSet
                      `S.union` (autoFailedDisks `S.union` x))
                 (buildDiskFailureSets df' possibleDisks failures)
      in
        S.unions $ go <$> choose i keys

    buildDiskFailureSets :: Word32 -- Max no. failed disks
                         -> S.Set Fid
                         -> Failures
                         -> S.Set (Failures, S.Set Fid)
    buildDiskFailureSets i fids failures =
      S.unions $ fmap (\j -> buildDiskFailureSet j fids failures) [0 .. i]

    buildDiskFailureSet :: Word32 -- No. failed disks
                        -> S.Set Fid -- Set of disks
                        -> Failures -- Existing allowed failure map
                        -> S.Set (Failures, S.Set Fid)
    buildDiskFailureSet i fids failures =
        S.fromList $ go <$> (choose i (S.toList fids))
      where
        go failed = (failures, (S.fromDistinctAscList failed))


    choose :: Word32 -> [a] -> [[a]]
    choose 0 _ = [[]]
    choose _ [] = []
    choose n (x:xs) = ((x:) <$> choose (n-1) xs) ++ choose n xs

  in S.toList . S.unions $
    fmap (\j -> buildCtrlFailureSet j allDisks) [0 .. cf]
