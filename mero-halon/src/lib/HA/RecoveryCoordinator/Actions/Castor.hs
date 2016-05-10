{-# LANGUAGE FlexibleContexts #-}
module HA.RecoveryCoordinator.Actions.Castor
  ( -- * Resource Graph Primitives
    -- ** Disk Failure Vector
    -- $disk-failure-vector
    rgRecordDiskFailure
  , rgRecordDiskOnline
  ) where

import qualified HA.ResourceGraph as G
import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Mero as M0
import HA.RecoveryCoordinator.Actions.Mero.Conf (rgGetPool)

import Data.Maybe (listToMaybe)
import Data.Foldable (foldl')
import Data.List (nub, intersect)

-- $disk-failure-vector
-- Halon stores the order in which disks are failing, this is needed
-- in order to be able to create a consistent view on the disks failures
-- at mero site.

-- | Record disk failure in Failure vector
rgRecordDiskFailure :: M0.Disk -> G.Graph -> G.Graph
rgRecordDiskFailure disk = updateDiskFailure defAction ins disk where
  defAction pool = G.connect pool R.Has (M0.DiskFailureVector [disk])
  ins d [] = Just [d]
  ins d (x:xs)
     | d == x = Nothing
     | otherwise = (x:) <$> ins d xs

-- | Record disk recovery in Failure vector
rgRecordDiskOnline :: M0.Disk -> G.Graph -> G.Graph
rgRecordDiskOnline = updateDiskFailure defAction rm where
  defAction = flip const
  rm d [] = Nothing
  rm d (x:xs)
     | d == x = Just xs
     | otherwise = (x:) <$> rm d xs

-- | Generic update graph function that just removes code duplication
updateDiskFailure :: (M0.Pool -> G.Graph -> G.Graph) -- ^ Default action if structure does not exist.
                  -> (M0.Disk -> [M0.Disk] -> Maybe [M0.Disk]) -- ^ Vector update function
                  -> M0.Disk -- ^ Disk in question
                  -> G.Graph
                  -> G.Graph
updateDiskFailure df f disk graph =  foldl' apply graph (allPools `intersect` pools) where
  pools = nub
    [ pool
    | cntrl <- G.connectedFrom     M0.IsParentOf disk  graph :: [M0.Controller]
    , encl  <- G.connectedFrom     M0.IsParentOf cntrl graph :: [M0.Enclosure]
    , rack  <- G.connectedFrom     M0.IsParentOf encl  graph :: [M0.Rack]
    , rackv <- G.connectedTo  rack M0.IsRealOf         graph :: [M0.RackV]
    , pver  <- G.connectedFrom     M0.IsParentOf rackv graph :: [M0.PVer]
    , pool  <- G.connectedFrom     M0.IsRealOf   pver  graph :: [M0.Pool]
    ]
  -- Get all pools, except metadata pools.
  allPools = rgGetPool graph
  apply rg pool =
    case listToMaybe $ G.connectedTo pool R.Has rg of
      Nothing -> df pool rg
      Just (M0.DiskFailureVector v) -> case f disk v of
        Nothing -> rg
        Just fv -> G.connect pool R.Has (M0.DiskFailureVector fv) rg

