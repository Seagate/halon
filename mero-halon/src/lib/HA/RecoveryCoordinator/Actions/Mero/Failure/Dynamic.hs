-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
{-# LANGUAGE FlexibleContexts #-}
module HA.RecoveryCoordinator.Actions.Mero.Failure.Dynamic where

import HA.RecoveryCoordinator.Actions.Mero.Failure.Internal
import qualified HA.ResourceGraph as G
import           HA.Resources
import           HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import Mero.ConfC (Fid(..))

import Data.Maybe (listToMaybe)
import Data.List (find)
import Data.Ratio
import Data.Proxy (Proxy(..))
import qualified Data.Set as S

-- | Dynamic failure set generation strategy. In this case, we generate a
--   new pool version when a device fails iff we do not have an existing pool
--   version matching the set of failed devices.
dynamicStrategy :: Strategy
dynamicStrategy = Strategy {
    onInit = const Nothing
  , onFailure = \rg -> do
      prof <- listToMaybe $ G.connectedTo Cluster Has rg :: Maybe M0.Profile
      fs   <- listToMaybe $ G.connectedTo prof M0.IsParentOf rg :: Maybe M0.Filesystem 
      globs <- listToMaybe $ G.connectedTo Cluster Has rg :: Maybe M0.M0Globals
      createPVerIfNotExists rg fs globs
}

-- | Find the FIDs corresponding to real objects existing in a pool
--   version.
findRealObjsInPVer :: G.Graph -> M0.PVer -> S.Set Fid
findRealObjsInPVer rg pver = let
    rackvs = G.connectedTo pver M0.IsParentOf rg :: [M0.RackV]
    racks  = rackvs >>= \x -> (G.connectedFrom M0.IsRealOf x rg :: [M0.Rack])
    enclvs = rackvs >>= \x -> (G.connectedTo x M0.IsParentOf rg :: [M0.EnclosureV])
    encls  = enclvs >>= \x -> (G.connectedFrom M0.IsRealOf x rg :: [M0.Enclosure])
    ctrlvs = enclvs >>= \x -> (G.connectedTo x M0.IsParentOf rg :: [M0.ControllerV])
    ctrls  = ctrlvs >>= \x -> (G.connectedFrom M0.IsRealOf x rg :: [M0.Controller])
    diskvs = ctrlvs >>= \x -> (G.connectedTo x M0.IsParentOf rg :: [M0.DiskV])
    disks  = diskvs >>= \x -> (G.connectedFrom M0.IsRealOf x rg :: [M0.Disk])
  in S.unions . fmap S.fromList $
      [ fmap M0.fid racks
      , fmap M0.fid encls
      , fmap M0.fid ctrls
      , fmap M0.fid disks
      ]

-- | Fetch the set of all FIDs corresponding to real (failable)
--   objects in the filesystem.
findFailableObjs :: G.Graph -> M0.Filesystem -> S.Set Fid
findFailableObjs rg fs = let
    racks = G.connectedTo fs M0.IsParentOf rg :: [M0.Rack]
    encls = racks >>= \x -> (G.connectedTo x M0.IsParentOf rg :: [M0.Enclosure])
    ctrls = encls >>= \x -> (G.connectedTo x M0.IsParentOf rg :: [M0.Controller])
    disks = ctrls >>= \x -> (G.connectedTo x M0.IsParentOf rg :: [M0.Disk])
  in S.unions . fmap S.fromList $
    [ fmap M0.fid racks
    , fmap M0.fid encls
    , fmap M0.fid ctrls
    , fmap M0.fid disks
    ]

-- | Find the set of currently failed devices in the filesystem.
findCurrentFailedDevices :: G.Graph -> M0.Filesystem -> S.Set Fid
findCurrentFailedDevices rg fs = let
    isFailedDisk disk =
      case [stat | sdev <- G.connectedFrom M0.IsOnHardware disk rg :: [M0.SDev]
                 , stat <- G.connectedTo sdev Is  rg :: [M0.ConfObjectState]] of
        [M0.M0_NC_TRANSIENT] -> True
        _ -> False -- Maybe? This shouldn't happen...
    racks = G.connectedTo fs M0.IsParentOf rg :: [M0.Rack]
    encls = racks >>= \x -> (G.connectedTo x M0.IsParentOf rg :: [M0.Enclosure])
    ctrls = encls >>= \x -> (G.connectedTo x M0.IsParentOf rg :: [M0.Controller])
    disks = ctrls >>= \x -> (G.connectedTo x M0.IsParentOf rg :: [M0.Disk])
    -- Note that currently, only SDEVs can fail. Which is kind of weird...
  in S.fromList . fmap M0.fid . filter isFailedDisk $ disks

-- | Attempt to find a pool version matching the set of failed
--   devices.
findMatchingPVer :: G.Graph
                 -> M0.Filesystem
                 -> S.Set Fid -- ^ Set of failed devices
                 -> Maybe M0.PVer
findMatchingPVer rg fs failedDevs = let
    onlineDevs = (findFailableObjs rg fs) `S.difference` failedDevs
    allPvers = [ (pver, findRealObjsInPVer rg pver)
                  | pool <- G.connectedTo fs M0.IsParentOf rg :: [M0.Pool]
                  , pver <- G.connectedTo pool M0.IsRealOf rg :: [M0.PVer]
                  ]
  in fst <$> find (\(_, x) -> x == onlineDevs) allPvers

-- | Examines the current set of failed devices and existing pool versions.
--   If a pool version exists matching the failed devices, returns Nothing.
--   Otherwise, creates a pool version and returns the modified graph.
createPVerIfNotExists :: G.Graph
                      -> M0.Filesystem
                      -> M0.M0Globals
                      -> Maybe G.Graph
createPVerIfNotExists rg fs globs = let
    failableObjs = findFailableObjs rg fs
    failedDevs = findCurrentFailedDevices rg fs
    mcur = findMatchingPVer rg fs failedDevs
  in case mcur of
    Just _ -> Nothing
    Nothing -> let
        _allDrives = G.getResourcesOfType rg :: [M0.Disk] -- XXX: why it's not used
        n = CI.m0_data_units globs
        k = CI.m0_parity_units globs
        pvObjs = (failableObjs `S.difference` failedDevs)
        noCtlrs = S.size $ S.filter
                          (M0.fidIsType (Proxy :: Proxy M0.Controller))
                          pvObjs
        ctrlFailures = floor $ noCtlrs % (fromIntegral $ n+k)
        failures = Failures 0 0 0 ctrlFailures k
        pv = PoolVersion pvObjs failures
      in return $ createPoolVersions fs [pv] False rg
