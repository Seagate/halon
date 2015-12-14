-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE LambdaCase                 #-}

module HA.RecoveryCoordinator.Actions.Mero.Conf where

import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Hardware
import HA.RecoveryCoordinator.Actions.Mero.Core
import qualified HA.ResourceGraph as G
import HA.Resources (Cluster(..), Has(..))
import HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0

import Mero.ConfC
  ( Fid
  , ServiceType(..)
  , bitmapFromArray
  )

import Control.Applicative
import Control.Category (id, (>>>))
import Control.Distributed.Process (liftIO)
import Control.Monad (forM_)

import Data.Foldable (find, foldl')
import qualified Data.HashMap.Strict as M
import Data.List (sort, (\\))
import Data.Maybe (listToMaybe)
import Data.Proxy
import qualified Data.Set as S
import Data.UUID.V4 (nextRandom)
import Data.Word ( Word32 )

import Network.CEP

import Prelude hiding (id)

-- | Lookup a configuration object by its Mero FID.
lookupConfObjByFid :: (G.Resource a, M0.ConfObj a)
                   => Fid
                   -> PhaseM LoopState l (Maybe a)
lookupConfObjByFid f = do
    phaseLog "rg-query" $ "Looking for conf objects with FID "
                        ++ show f
    fmap (rgLookupConfObjByFid f) getLocalGraph

rgLookupConfObjByFid :: forall a. (G.Resource a, M0.ConfObj a)
                     => Fid
                     -> G.Graph
                     -> Maybe a
rgLookupConfObjByFid f =
    listToMaybe
  . filter ((== f) . M0.fid)
  . G.getResourcesOfType

-- | Initialise a reflection of the Mero configuration in the resource graph.
--   This does the following:
--   * Create a single profile, filesystem
--   * Create Mero rack and enclosure entities reflecting existing
--     entities in the graph.
initialiseConfInRG :: PhaseM LoopState l M0.Filesystem
initialiseConfInRG = getFilesystem >>= \case
    Just fs -> return fs
    Nothing -> do
      rg <- getLocalGraph
      profile <- M0.Profile <$> newFid (Proxy :: Proxy M0.Profile)
      pool <- M0.Pool <$> newFid (Proxy :: Proxy M0.Pool)
      fs <- M0.Filesystem <$> newFid (Proxy :: Proxy M0.Filesystem)
                          <*> return (M0.fid pool)
      modifyGraph
          $ G.newResource profile
        >>> G.newResource fs
        >>> G.newResource pool
        >>> G.connectUniqueFrom Cluster Has profile
        >>> G.connectUniqueFrom profile M0.IsParentOf fs
        >>> G.connect fs M0.IsParentOf pool

      let re = [ (r, G.connectedTo r Has rg)
               | r <- G.connectedTo Cluster Has rg
               ]
      mapM_ (mirrorRack fs) re
      return fs
  where
    mirrorRack :: M0.Filesystem -> (Rack, [Enclosure]) -> PhaseM LoopState l ()
    mirrorRack fs (r, encls) = do
      m0r <- M0.Rack <$> newFid (Proxy :: Proxy M0.Rack)
      m0e <- mapM mirrorEncl encls
      modifyGraph
          $ G.newResource m0r
        >>> G.connectUnique m0r M0.At r
        >>> G.connect fs M0.IsParentOf m0r
        >>> ( foldl' (.) id
              $ fmap (G.connect m0r M0.IsParentOf) m0e)
    mirrorEncl :: Enclosure -> PhaseM LoopState l M0.Enclosure
    mirrorEncl r = do
      m0r <- M0.Enclosure <$> newFid (Proxy :: Proxy M0.Enclosure)
      modifyLocalGraph $ return
                       . (G.newResource m0r >>> G.connectUnique m0r M0.At r)
      return m0r

-- | Load Mero servers (e.g. Nodes, Processes, Services, Drives) into conf
--   tree.
--   For each 'M0Host', we add the following:
--     - A Host (Halon representation)
--     - A controller (physical host)
--     - A node (logical host)
--     - A process (Mero process)
--   Then we add all drives (storage devices) into the system, involving:
--     - A @StorageDevice@ (Halon representation)
--     - A disk (physical device)
--     - An SDev (logical device)
--   We then add any relevant services running on this process. If one is
--   an ioservice (and it should be!), we link the sdevs to the IOService.
loadMeroServers :: M0.Filesystem
                -> [CI.M0Host]
                -> PhaseM LoopState l ()
loadMeroServers fs = mapM_ goHost where
  goHost CI.M0Host{..} = let
      host = Host m0h_fqdn
    in do
      ctrl <- M0.Controller <$> newFid (Proxy :: Proxy M0.Controller)
      node <- M0.Node <$> newFid (Proxy :: Proxy M0.Node)

      devs <- mapM (goDev host ctrl) m0h_devices
      mapM_ (goProc node devs) m0h_processes

      rg <- getLocalGraph
      let enc = head $ [ e | e1 <- G.connectedFrom Has host rg :: [Enclosure]
                           , e <- G.connectedFrom M0.At e1 rg :: [M0.Enclosure]
                           ]

      modifyGraph $ G.newResource host
                >>> G.newResource ctrl
                >>> G.newResource node
                >>> G.connect Cluster Has host
                >>> G.connect fs M0.IsParentOf node
                >>> G.connect enc M0.IsParentOf ctrl
                >>> G.connect ctrl M0.At host
                >>> G.connect node M0.IsOnHardware ctrl

  goProc node devs CI.M0Process{..} = let
      cores = bitmapFromArray
        . fmap (> 0)
        $ m0p_cores
      mkProc fid = M0.Process fid m0p_mem_as m0p_mem_rss
                              m0p_mem_stack m0p_mem_memlock
                              cores m0p_endpoint
    in do
      proc <- mkProc <$> newFid (Proxy :: Proxy M0.Process)
      mapM_ (goSrv proc devs) m0p_services

      modifyGraph $ G.newResource proc
                >>> G.newResource proc
                >>> G.connect node M0.IsParentOf proc

  goSrv proc devs CI.M0Service{..} = let
      mkSrv fid = M0.Service fid m0s_type m0s_endpoints m0s_params
      linkDrives svc = case m0s_type of
        CST_IOS -> foldl' (.) id
                    $ fmap (G.connect svc M0.IsParentOf) devs
        _ -> id
    in do
      svc <- mkSrv <$> newFid (Proxy :: Proxy M0.Service)
      modifyLocalGraph $ return
                       . (    G.newResource svc
                          >>> G.connect proc M0.IsParentOf svc
                          >>> linkDrives svc
                         )

  goDev host ctrl CI.M0Device{..} = let
      mkSDev fid = M0.SDev fid m0d_size m0d_bsize m0d_path
      devIds = [ DIWWN m0d_wwn
               , DIPath m0d_path
               ]
    in do
      m0sdev <- mkSDev <$> newFid (Proxy :: Proxy M0.SDev)
      m0disk <- M0.Disk <$> newFid (Proxy :: Proxy M0.Disk)
      sdev <- StorageDevice <$> liftIO nextRandom
      mapM_ (identifyStorageDevice sdev) devIds
      locateStorageDeviceOnHost host sdev
      markDiskPowerOn sdev
      modifyGraph
          $ G.newResource m0sdev
        >>> G.newResource m0disk
        >>> G.connect ctrl M0.IsParentOf m0disk
        >>> G.connect m0sdev M0.IsOnHardware m0disk
        >>> G.connect m0disk M0.At sdev
      return m0sdev

--------------------------------------------------------------------------------
-- Querying conf in RG
--------------------------------------------------------------------------------

-- | Fetch the Mero Profile in the system. Currently, we
--   only support a single profile, though in future there
--   might be multiple profiles and this function will need
--   to change.
getProfile :: PhaseM LoopState l (Maybe M0.Profile)
getProfile = getLocalGraph >>= \rg -> do
  phaseLog "rg-query" $ "Looking for Mero profile."
  return . listToMaybe
    $ G.connectedTo Cluster Has rg

-- | Fetch the Mero filesystem in the system. Currently, we
--   only support a single filesystem, though in future there
--   might be multiple filesystems and this function will need
--   to change.
getFilesystem :: PhaseM LoopState l (Maybe M0.Filesystem)
getFilesystem = getLocalGraph >>= \rg -> do
  phaseLog "rg-query" $ "Looking for Mero filesystem."
  return . listToMaybe
    $ [ fs | p <- G.connectedTo Cluster Has rg :: [M0.Profile]
           , fs <- G.connectedTo p M0.IsParentOf rg :: [M0.Filesystem]
      ]

-- | Get all 'M0.Service' running on the 'Cluster', starting at
-- 'M0.Profile's.
getM0Services :: PhaseM LoopState l [M0.Service]
getM0Services = getLocalGraph >>= \g ->
  let svs = [ sv | (prof :: M0.Profile) <- G.connectedTo Cluster Has g
                   , (fs :: M0.Filesystem) <- G.connectedTo prof M0.IsParentOf g
                   , (node :: M0.Node) <- G.connectedTo fs M0.IsParentOf g
                   , (p :: M0.Process) <- G.connectedTo node M0.IsParentOf g
                   , sv <- G.connectedTo p M0.IsParentOf g
            ]
  in return svs

lookupStorageDevice :: M0.SDev -> PhaseM LoopState l (Maybe StorageDevice)
lookupStorageDevice sdev = do
    rg <- getLocalGraph
    let sds =
          [ sd | dev  <- G.connectedTo sdev M0.IsOnHardware rg :: [M0.Disk]
               , sd   <- G.connectedTo dev M0.At rg :: [StorageDevice]
               ]
    return $ listToMaybe sds

-- | Return the Mero SDev associated with the given storage device
lookupStorageDeviceSDev :: StorageDevice -> PhaseM LoopState l (Maybe M0.SDev)
lookupStorageDeviceSDev sdev = do
  rg <- getLocalGraph
  let sds =
        [ sd | disk <- G.connectedFrom M0.At sdev rg :: [M0.Disk]
             , sd <- G.connectedFrom M0.IsOnHardware disk rg :: [M0.SDev]
             ]
  return $ listToMaybe sds

lookupSDevDisk :: M0.SDev -> PhaseM LoopState l (Maybe M0.Disk)
lookupSDevDisk sdev = do
  phaseLog "rg" $ "Looking up M0.Disk objects attached to sdev " ++ show sdev
  rg <- getLocalGraph
  return . listToMaybe $ G.connectedTo sdev M0.IsOnHardware rg

getSDevPools :: M0.SDev -> PhaseM LoopState l [M0.Pool]
getSDevPools sdev = do
    rg <- getLocalGraph
    let ps =
          [ p | d  <- G.connectedTo sdev M0.IsOnHardware rg :: [M0.Disk]
              , dv <- G.connectedTo d M0.IsRealOf rg :: [M0.DiskV]
              , ct <- G.connectedFrom M0.IsParentOf dv rg :: [M0.ControllerV]
              , ev <- G.connectedFrom M0.IsParentOf ct rg :: [M0.EnclosureV]
              , rv <- G.connectedFrom M0.IsParentOf ev rg :: [M0.RackV]
              , pv <- G.connectedFrom M0.IsParentOf rv rg :: [M0.PVer]
              , p  <- G.connectedFrom M0.IsRealOf pv rg :: [M0.Pool]
              ]

    return ps

--------------------------------------------------------------------------------
-- Pool versions and failure sets
--------------------------------------------------------------------------------

-- | Allowed failures in each failure domain
data Failures = Failures {
    f_pool :: !Word32
  , f_rack :: !Word32
  , f_encl :: !Word32
  , f_ctrl :: !Word32
  , f_disk :: !Word32
} deriving (Eq, Ord, Show)

data FailureSet = FailureSet !(S.Set Fid) !Failures
                  -- ^ @FailureSet fids fs@ where @fids@ is a set of
                  -- fids and @fs@ are allowable failures in each
                  -- failure domain.
  deriving (Eq, Ord, Show)

failuresToArray :: Failures -> [Word32]
failuresToArray f = [f_pool f, f_rack f, f_encl f, f_ctrl f, f_disk f]

mapFS :: (S.Set Fid -> S.Set Fid) -> FailureSet -> FailureSet
mapFS f (FailureSet a b) = FailureSet (f a) b

-- |  Completely isomorphic to pool version
data PoolVersion = PoolVersion !(S.Set Fid) !Failures
                  -- ^ @PoolVersion fids fs@ where @fids@ is a set of
                  -- fids and @fs@ are allowable failures in each
                  -- failure domain.
  deriving (Eq, Ord, Show)

-- | Convert from failure set representation to pool version representation.
--   These representations are complementary within the context of a fixed
--   set of objects.
failureSetToPoolVersion :: G.Graph
                        -> M0.Filesystem
                        -> FailureSet
                        -> PoolVersion
failureSetToPoolVersion rg fs (FailureSet badFids failures) = let
    allFids = findFailableObjs rg fs
    goodFids = allFids `S.difference` badFids
  in PoolVersion goodFids failures

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

-- | Returns true if a PVer was created.
createPVerIfNotExists :: PhaseM LoopState l Bool
createPVerIfNotExists = do
  rg <- getLocalGraph
  (Just fs) <- getFilesystem
  let failedDevs = findCurrentFailedDevices rg fs
      mcur = findMatchingPVer rg fs failedDevs
      allDrives = G.getResourcesOfType rg :: [M0.Disk]
      failures = Failures 0 0 0 1 (fromIntegral $ length allDrives - S.size failedDevs)
  case mcur of
    Just _ -> return False
    Nothing -> let
        failureSet = FailureSet failedDevs failures
        pv = failureSetToPoolVersion rg fs failureSet
      in createPoolVersions fs [pv] >> return True

-- | Create pool versions based upon failure sets.
createPoolVersions :: M0.Filesystem
                   -> [PoolVersion]
                   -> PhaseM LoopState l ()
createPoolVersions fs = mapM_ createPoolVersion
  where
    pool = M0.Pool (M0.f_mdpool_fid fs)
    createPoolVersion :: PoolVersion -> PhaseM LoopState l ()
    createPoolVersion (PoolVersion failset failures) = do
      pver <- M0.PVer <$> newFid (Proxy :: Proxy M0.PVer)
                      <*> return (failuresToArray failures)
      modifyGraph
          $ G.newResource pver
        >>> G.connect pool M0.IsRealOf pver
      rg <- getLocalGraph
      forM_ (filter (\x -> M0.fid x `S.member` failset)
              $ G.connectedTo fs M0.IsParentOf rg :: [M0.Rack])
            $ \rack -> do
        rackv <- M0.RackV <$> newFid (Proxy :: Proxy M0.RackV)
        modifyGraph
            $ G.newResource rackv
          >>> G.connect pver M0.IsParentOf rackv
          >>> G.connect rack M0.IsRealOf rackv
        rg1 <- getLocalGraph
        forM_ (filter (\x -> M0.fid x `S.member` failset)
                $ G.connectedTo rack M0.IsParentOf rg1 :: [M0.Enclosure])
              $ \encl -> do
          enclv <- M0.EnclosureV <$> newFid (Proxy :: Proxy M0.EnclosureV)
          modifyGraph
              $ G.newResource enclv
            >>> G.connect rackv M0.IsParentOf enclv
            >>> G.connect encl M0.IsRealOf enclv
          rg2 <- getLocalGraph
          forM_ (filter (\x -> M0.fid x `S.member` failset)
                  $ G.connectedTo encl M0.IsParentOf rg2 :: [M0.Controller])
                $ \ctrl -> do
            ctrlv <- M0.ControllerV <$> newFid (Proxy :: Proxy M0.ControllerV)
            modifyGraph
                $ G.newResource ctrlv
              >>> G.connect enclv M0.IsParentOf ctrlv
              >>> G.connect ctrl M0.IsRealOf ctrlv
            rg3 <- getLocalGraph
            forM_ (filter (\x -> M0.fid x `S.member` failset)
                    $ G.connectedTo ctrl M0.IsParentOf rg3 :: [M0.Disk])
                  $ \disk -> do
              diskv <- M0.DiskV <$> newFid (Proxy :: Proxy M0.DiskV)
              modifyGraph
                  $ G.newResource diskv
                >>> G.connect ctrlv M0.IsParentOf diskv
                >>> G.connect disk M0.IsRealOf diskv

generateFailureSets :: Word32 -- ^ No. of disk failures to tolerate
                    -> Word32 -- ^ No. of controller failures to tolerate
                    -> Word32 -- ^ No. of disk failures equivalent to ctrl failure
                    -> PhaseM LoopState l [FailureSet]
generateFailureSets df cf cfe = do
  rg <- getLocalGraph
  -- Look up all disks and the controller they are attached to
  let allDisks = M.fromListWith (S.union) . fmap (fmap S.singleton) $
        [ (M0.fid ctrl, M0.fid disk)
        | (host :: Host) <- G.connectedTo Cluster Has rg
        , (ctrl :: M0.Controller) <- G.connectedFrom M0.At host rg
        , (disk :: M0.Disk) <- G.connectedTo ctrl M0.IsParentOf rg
        ]

      -- Build failure sets for this number of failed controllers
      buildCtrlFailureSet :: Word32 -- No. failed controllers
                          -> M.HashMap Fid (S.Set Fid) -- ctrl -> disks
                          -> S.Set FailureSet
      buildCtrlFailureSet i fids = let
          df' = df - (i * cfe) -- E.g. failures to support on top of ctrl failure
          failures = Failures 0 0 0 (cf - i) (df')
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
              S.mapMonotonic (mapFS $ \x -> failedCtrlSet
                        `S.union` (autoFailedDisks `S.union` x))
                   (buildDiskFailureSets df' possibleDisks failures)
        in
          S.unions $ go <$> choose i keys

      buildDiskFailureSets :: Word32 -- Max no. failed disks
                           -> S.Set Fid
                           -> Failures
                           -> S.Set FailureSet
      buildDiskFailureSets i fids failures =
        S.unions $ fmap (\j -> buildDiskFailureSet j fids failures) [0 .. i]

      buildDiskFailureSet :: Word32 -- No. failed disks
                          -> S.Set Fid -- Set of disks
                          -> Failures -- Existing allowed failure map
                          -> S.Set FailureSet
      buildDiskFailureSet i fids failures =
          S.fromList $ go <$> (choose i (S.toList fids))
        where
          go failed = FailureSet
                        (S.fromDistinctAscList failed)
                        failures { f_disk = f_disk failures - i }

      choose :: Word32 -> [a] -> [[a]]
      choose 0 _ = [[]]
      choose _ [] = []
      choose n (x:xs) = ((x:) <$> choose (n-1) xs) ++ choose n xs

  return $ S.toList $ S.unions $
    fmap (\j -> buildCtrlFailureSet j allDisks) [0 .. cf]
