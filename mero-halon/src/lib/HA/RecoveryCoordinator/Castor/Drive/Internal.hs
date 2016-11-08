{-# LANGUAGE FlexibleContexts #-}
-- |
-- Module    : HA.RecoveryCoordinator.Castor.Drive.Internal
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Internal drive actions.
module HA.RecoveryCoordinator.Castor.Drive.Internal
  ( -- * Resource Graph Primitives
    -- ** Disk Failure Vector
    -- $disk-failure-vector
    rgRecordDiskFailure
  , rgRecordDiskOnline
  ) where

import qualified HA.ResourceGraph as G
import qualified HA.Resources as R
import qualified HA.Resources.Mero as M0
import HA.RecoveryCoordinator.Mero.Actions.Conf (rgGetPool)

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
  rm _ [] = Nothing
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
    | Just cntrl <- [G.connectedFrom     M0.IsParentOf disk  graph :: Maybe M0.Controller]
    , Just encl  <- [G.connectedFrom     M0.IsParentOf cntrl graph :: Maybe M0.Enclosure]
    , Just rack  <- [G.connectedFrom     M0.IsParentOf encl  graph :: Maybe M0.Rack]
    , rackv <- G.connectedTo  rack M0.IsRealOf         graph :: [M0.RackV]
    , Just pver  <- [G.connectedFrom     M0.IsParentOf rackv graph :: Maybe M0.PVer]
    , Just pool  <- [G.connectedFrom     M0.IsRealOf   pver  graph :: Maybe M0.Pool]
    ]
  -- Get all pools, except metadata pools.
  allPools = rgGetPool graph
  apply rg pool =
    case G.connectedTo pool R.Has rg of
      Nothing -> df pool rg
      Just (M0.DiskFailureVector v) -> case f disk v of
        Nothing -> rg
        Just fv -> G.connect pool R.Has (M0.DiskFailureVector fv) rg
