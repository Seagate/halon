{-# LANGUAGE CPP                        #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RecordWildCards            #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Rules and primitives specific to Mero

module HA.RecoveryCoordinator.Rules.Mero where

import HA.RecoveryCoordinator.Actions.Mero (getFilesystem)
import HA.RecoveryCoordinator.Mero
import HA.Resources.Castor
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Castor.Initial as CI
import HA.Resources
import qualified HA.ResourceGraph as G

import Mero.ConfC (Fid)

import Control.Category (id, (>>>))
import Control.Distributed.Process (liftIO)
import Control.Monad (forM_)

import Data.Foldable (foldl')
import qualified Data.HashMap.Strict as M
import Data.List (sort, (\\))
import Data.Proxy
import qualified Data.Set as S
import Data.UUID.V4 (nextRandom)
import Data.Word ( Word64 )

import Network.CEP

import Prelude hiding (id)

-- | Atomically fetch a FID sequence number of increment the sequence count.
newFidSeq :: PhaseM LoopState l Word64
newFidSeq = getLocalGraph >>= \rg ->
    case G.connectedTo Cluster Has rg of
      ((M0.FidSeq w):_) -> go rg w
      [] -> go rg 0
  where
    go rg w = let
        w' = w + 1
        rg' = G.connectUniqueFrom Cluster Has (M0.FidSeq w') $ rg
      in do
        putLocalGraph rg'
        return w'

newFid :: M0.ConfObj a => Proxy a -> PhaseM LoopState l Fid
newFid p = newFidSeq >>= return . M0.fidInit p 1

loadMeroGlobals :: CI.M0Globals
                -> PhaseM LoopState l ()
loadMeroGlobals g = modifyLocalGraph $ return . G.connect Cluster Has g

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
      mkProc fid = M0.Process fid m0h_mem_as m0h_mem_rss
                              m0h_mem_stack m0h_mem_memlock
                              m0h_cores

    in do
      ctrl <- M0.Controller <$> newFid (Proxy :: Proxy M0.Controller)
      node <- M0.Node <$> newFid (Proxy :: Proxy M0.Node)
      proc <- mkProc <$> newFid (Proxy :: Proxy M0.Process)

      devs <- mapM (goDev host ctrl) m0h_devices
      mapM_ (goSrv proc devs) m0h_services

      rg <- getLocalGraph
      let enc = head $ [ e | e1 <- G.connectedFrom Has host rg :: [Enclosure]
                           , e <- G.connectedFrom M0.At e1 rg :: [M0.Enclosure]
                           ]

      modifyGraph $ G.newResource host
                >>> G.newResource ctrl
                >>> G.newResource node
                >>> G.newResource proc
                >>> G.connect Cluster Has host
                >>> G.connect fs M0.IsParentOf node
                >>> G.connect enc M0.IsParentOf ctrl
                >>> G.connect ctrl M0.At host
                >>> G.connect node M0.IsOnHardware ctrl
                >>> G.connect node M0.IsParentOf proc

  goSrv proc devs CI.M0Service{..} = let
      mkSrv fid = M0.Service fid m0s_type m0s_endpoints m0s_params
      linkDrives svc = case m0s_type of
        "ioservice" -> foldl' (.) id
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
      devId = DeviceIdentifier "wwn" $ IdentString m0d_wwn
    in do
      m0sdev <- mkSDev <$> newFid (Proxy :: Proxy M0.SDev)
      m0disk <- M0.Disk <$> newFid (Proxy :: Proxy M0.Disk)
      sdev <- StorageDevice <$> liftIO nextRandom
      identifyStorageDevice sdev devId
      locateStorageDeviceOnHost host sdev
      modifyGraph
          $ G.newResource m0sdev
        >>> G.newResource m0disk
        >>> G.connect ctrl M0.IsParentOf m0disk
        >>> G.connect m0sdev M0.IsOnHardware m0disk
        >>> G.connect m0disk M0.At sdev
      return m0sdev

-- | Has the configuration already been initialised?
confInitialised :: PhaseM LoopState l Bool
confInitialised = getLocalGraph >>=
  return . null . (G.connectedTo Cluster Has :: G.Graph -> [M0.Profile])

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
      fs <- M0.Filesystem <$> newFid (Proxy :: Proxy M0.Profile)
      modifyLocalGraph $ return
                       . ( G.connectUniqueFrom Cluster Has profile
                           >>> G.connectUniqueFrom profile M0.IsParentOf fs
                         )
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

-- | Create pool versions based upon failure sets.
createPoolVersions :: M0.Filesystem
                   -> S.Set (S.Set Fid)
                   -> PhaseM LoopState l ()
createPoolVersions fs = mapM_ createPoolVersion . S.toList
  where
    createPoolVersion :: S.Set Fid -> PhaseM LoopState l ()
    createPoolVersion failset = do
      pool <- M0.Pool <$> newFid (Proxy :: Proxy M0.Pool)
      pver <- M0.PVer <$> newFid (Proxy :: Proxy M0.PVer)
      modifyGraph
          $ G.newResource pool
        >>> G.newResource pver
        >>> G.connect fs M0.IsParentOf pool
        >>> G.connect pool M0.IsRealOf pver
      rg <- getLocalGraph
      forM_ (G.connectedTo fs M0.IsParentOf rg :: [M0.Rack]) $ \rack -> do
        rackv <- M0.RackV <$> newFid (Proxy :: Proxy M0.RackV)
        modifyGraph
            $ G.newResource rackv
          >>> G.connect pver M0.IsParentOf rackv
          >>> G.connect rack M0.IsRealOf rackv
        rg1 <- getLocalGraph
        forM_ (filter (\x -> not $ M0.fid x `S.member` failset)
                $ G.connectedTo rack M0.IsParentOf rg1 :: [M0.Enclosure])
              $ \encl -> do
          enclv <- M0.EnclosureV <$> newFid (Proxy :: Proxy M0.EnclosureV)
          modifyGraph
              $ G.newResource enclv
            >>> G.connect rackv M0.IsParentOf enclv
            >>> G.connect encl M0.IsRealOf enclv
          rg2 <- getLocalGraph
          forM_ (filter (\x -> not $ M0.fid x `S.member` failset)
                  $ G.connectedTo encl M0.IsParentOf rg2 :: [M0.Controller])
                $ \ctrl -> do
            ctrlv <- M0.ControllerV <$> newFid (Proxy :: Proxy M0.ControllerV)
            modifyGraph
                $ G.newResource ctrlv
              >>> G.connect enclv M0.IsParentOf ctrlv
              >>> G.connect ctrl M0.IsRealOf ctrlv
            rg3 <- getLocalGraph
            forM_ (filter (\x -> not $ M0.fid x `S.member` failset)
                    $ G.connectedTo ctrl M0.IsParentOf rg3 :: [M0.Disk])
                  $ \disk -> do
              diskv <- M0.DiskV <$> newFid (Proxy :: Proxy M0.DiskV)
              modifyGraph
                  $ G.newResource ctrlv
                >>> G.connect ctrlv M0.IsParentOf diskv
                >>> G.connect disk M0.IsRealOf diskv

generateFailureSets :: Int -- ^ No. of disk failures to tolerate
                    -> Int -- ^ No. of controller failures to tolerate
                    -> Int -- ^ No. of disk failures equivalent to ctrl failure
                    -> PhaseM LoopState l (S.Set (S.Set Fid))
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
      buildCtrlFailureSet :: Int -- No. failed controllers
                          -> M.HashMap Fid (S.Set Fid) -- ctrl -> disks
                          -> S.Set (S.Set Fid)
      buildCtrlFailureSet i fids = let
          df' = df - (i * cfe) -- E.g. failures to support on top of ctrl failure
          keys = sort $ M.keys fids
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
              S.mapMonotonic (\x -> failedCtrlSet
                        `S.union` (autoFailedDisks `S.union` x))
                   (buildDiskFailureSets df' possibleDisks)
        in
          S.unions $ go <$> choose i keys

      buildDiskFailureSets :: Int -- Max no. failed disks
                           -> S.Set Fid
                           -> S.Set (S.Set Fid)
      buildDiskFailureSets i fids =
        S.unions $ fmap (\j -> buildDiskFailureSet j fids) [0 .. i]

      buildDiskFailureSet :: Int -- No. failed disks
                          -> S.Set Fid
                          -> S.Set (S.Set Fid)
      buildDiskFailureSet i fids =
          S.unions $ go <$> (choose i (S.toList fids))
        where
          go failed = S.singleton $ S.fromDistinctAscList failed

      choose :: Int -> [a] -> [[a]]
      choose 0 _ = [[]]
      choose _ [] = []
      choose n (x:xs) = ((x:) <$> choose (n-1) xs) ++ choose n xs

  return $ S.unions $ fmap (\j -> buildCtrlFailureSet j allDisks) [0 .. cf]
