-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
module HA.RecoveryCoordinator.Mero.Failure.Simple where  -- XXX DELETEME

#if 0  /* XXX */
import           HA.RecoveryCoordinator.Mero.Failure.Internal
  ( ConditionOfDevices(DevicesFailed)
  , PoolVersion(..)
  , UpdateType(Iterative)
  , createPoolVersions
  )
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..), Has(..))
import qualified HA.Resources.Castor as Cas (Host(..))
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import           Mero.ConfC (Fid, PDClustAttr(..), Word128(..))

import           Control.Monad (join)
import           Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as Map
import           Data.List ((\\), sort, unfoldr)
import           Data.Ratio
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Word (Word32)

data_units :: Word32
data_units = error "XXX IMPLEMENTME"

parity_units :: Word32
parity_units = error "XXX IMPLEMENTME"

-- | Simple failure set generation strategy. In this case, we pre-generate
--   failure sets for the given number of failures.
simpleUpdate :: Monad m
             => Word32 -- ^ No. of disk failures to tolerate
             -> Word32 -- ^ No. of controller failures to tolerate
             -> Word32 -- ^ No. of disk failures equivalent to ctrl failure
             -> UpdateType m
simpleUpdate df cf cfe = Iterative $ \rg ->
  let mchunks = do
        let fsets = generateFailureSets df cf cfe rg
            attrs = PDClustAttr {
                      _pa_N = data_units
                    , _pa_K = parity_units
                    , _pa_P = 0
                    , _pa_unit_size = 4096
                    , _pa_seed = Word128 101 102
                    }
            -- update chunks
        return (flip unfoldr fsets $ \xs -> if null xs
                                            then Nothing
                                            else Just (splitAt 5 xs)
                , attrs)
  in case mchunks of
       Nothing -> Nothing
       Just (chunks, attrs) -> Just $ \sync ->
         let go g [] = return g
             go g (c:cs) =
                let pvs = fmap (\(fs', fids) -> PoolVersion Nothing fids fs' attrs) c
                in do
                    g' <- sync $ createPoolVersions pvs DevicesFailed g
                    go g' cs
         in go rg chunks

-- | Given tolerance parameters, generate failure sets.
generateFailureSets :: Word32 -- ^ No. of disk failures to tolerate
                    -> Word32 -- ^ No. of controller failures to tolerate
                    -> Word32 -- ^ No. of disk failures equivalent to ctrl failure
                    -> G.Graph
                    -> [(CI.Failures, Set Fid)]
generateFailureSets df cf cfe rg = let
    n = data_units
    k = parity_units
    allCtrls =
      [ ctrl
      | host :: Cas.Host <- G.connectedTo Cluster Has rg
      , Just (ctrl :: M0.Controller) <- [G.connectedFrom M0.At host rg]
      ]
    -- Look up all disks and the controller they are attached to
    allDisks :: HashMap Fid (Set Fid)
    allDisks = Map.fromListWith Set.union . fmap (fmap Set.singleton) $
        [ (M0.fid ctrl, M0.fid disk)
        | ctrl <- allCtrls
        , disk :: M0.Disk <- G.connectedTo ctrl M0.IsParentOf rg
        ]

    buildCtrlFailureSet :: Word32 -> HashMap Fid (Set Fid) -> Set (CI.Failures, Set Fid)
    buildCtrlFailureSet i fids = let
        df' = if df > i * cfe then df - (i*cfe) else 0 -- E.g. failures to support on top of ctrl failure
        -- Following change is temporary, and would work as long as failures
        -- above controllers (encl, racks) are not to be supported
        -- (ref. HALON-406)
        quotient = floor $ (n + 2*k) % (fromIntegral (length allCtrls) -i)
        remainder = (n + 2*k) `rem` (fromIntegral (length allCtrls) - i)
        kc = remainder * (quotient + 1)
        ctrlFailures
            | kc > k = k `quot` (quotient + 1)
            | kc < k = floor $ (k - remainder) % quotient
            | otherwise = remainder
        failures = CI.Failures 0 0 0 ctrlFailures k
        keys = sort $ Map.keys fids
        go :: [Fid] -> Set (CI.Failures, Set Fid)  -- FailureSet
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
                         -> CI.Failures
                         -> Set (CI.Failures, Set Fid)
    buildDiskFailureSets i fids failures =
      Set.unions $ fmap (\j -> buildDiskFailureSet j fids failures) [0 .. i]

    buildDiskFailureSet :: Word32 -- ^ No. failed disks
                        -> Set Fid -- ^ Set of disks
                        -> CI.Failures -- ^ Existing allowed failure map
                        -> Set (CI.Failures, Set Fid)
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
#endif
