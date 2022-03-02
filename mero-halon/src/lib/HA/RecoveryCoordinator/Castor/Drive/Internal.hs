{-# LANGUAGE FlexibleContexts #-}
-- |
-- Module    : HA.RecoveryCoordinator.Castor.Drive.Internal
-- Copyright : (C) 2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
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
import           HA.Resources (Has(..))
import qualified HA.Resources.Mero as M0
import qualified HA.RecoveryCoordinator.Castor.Pool.Actions as Pool (getNonMD)

import Data.Foldable (foldl')
import Data.List (nub, intersect)

-- $disk-failure-vector
-- Halon stores the order in which disks are failing, this is needed
-- in order to be able to create a consistent view on the disks failures
-- at mero site.

-- | Record disk failure in Failure vector
rgRecordDiskFailure :: M0.Disk -> G.Graph -> G.Graph
rgRecordDiskFailure disk = updateDiskFailure defAction ins disk where
  defAction pool = G.connect pool Has (M0.DiskFailureVector [disk])
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
updateDiskFailure df f disk rg = foldl' apply rg (nonMDPools `intersect` pools) where
  nonMDPools = Pool.getNonMD rg
  pools = nub
    [ pool
    | diskv :: M0.DiskV              <- G.connectedTo disk M0.IsRealOf rg
    , Just (ctrlv :: M0.ControllerV) <- [G.connectedFrom M0.IsParentOf diskv rg]
    , Just (enclv :: M0.EnclosureV)  <- [G.connectedFrom M0.IsParentOf ctrlv rg]
    , Just (rackv :: M0.RackV)       <- [G.connectedFrom M0.IsParentOf enclv rg]
    , Just (sitev :: M0.SiteV)       <- [G.connectedFrom M0.IsParentOf rackv rg]
    , Just (pver :: M0.PVer)         <- [G.connectedFrom M0.IsParentOf sitev rg]
    , Just (pool :: M0.Pool)         <- [G.connectedFrom M0.IsParentOf pver rg]
    ]
  apply rg' pool =
    case G.connectedTo pool Has rg' of
      Nothing -> df pool rg'
      Just (M0.DiskFailureVector v) -> case f disk v of
        Nothing -> rg'
        Just fv -> G.connect pool Has (M0.DiskFailureVector fv) rg'
