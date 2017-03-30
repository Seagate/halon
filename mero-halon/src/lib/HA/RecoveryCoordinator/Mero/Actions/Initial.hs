{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
-- |
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
module HA.RecoveryCoordinator.Mero.Actions.Initial
  ( -- * Initialization
    initialiseConfInRG
  , loadMeroServers
  , createMDPoolPVer
  , createIMeta
  ) where

import           Control.Category ((>>>))
import           Data.Foldable (foldl', for_)
import           Data.List (notElem, scanl')
import           Data.Maybe (fromMaybe)
import           Data.Proxy
import qualified Data.Set as Set
import           Data.Traversable (for)
import           HA.RecoveryCoordinator.Castor.Drive.Actions as Drive
import qualified HA.RecoveryCoordinator.Hardware.StorageDevice.Actions as StorageDevice
import           HA.RecoveryCoordinator.Mero.Actions.Conf
  ( getFilesystem
  , lookupEnclosureM0
  )
import           HA.RecoveryCoordinator.Mero.Actions.Core
import           HA.RecoveryCoordinator.Mero.Failure.Internal
import           HA.RecoveryCoordinator.RC.Actions.Core
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..), Has(..), Runs(..))
import           HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           Mero.ConfC
  ( PDClustAttr(..)
  , ServiceType(..)
  , Word128(..)
  , bitmapFromArray
  , m0_fid0
  )
import           Network.CEP
import           Text.Regex.TDFA ((=~))

-- | Initialise a reflection of the Mero configuration in the resource graph.
--   This does the following:
--   * Create a single profile, filesystem
--   * Create Mero rack and enclosure entities reflecting existing
--     entities in the graph.
initialiseConfInRG :: PhaseM RC l M0.Filesystem
initialiseConfInRG = getFilesystem >>= \case
    Just fs -> return fs
    Nothing -> do
      root    <- M0.Root    <$> newFidRC (Proxy :: Proxy M0.Root)
      profile <- M0.Profile <$> newFidRC (Proxy :: Proxy M0.Profile)
      pool <- M0.Pool <$> newFidRC (Proxy :: Proxy M0.Pool)
      mdpool <- M0.Pool <$> newFidRC (Proxy :: Proxy M0.Pool)
      -- Note that this FID will actually be overwritten by `createIMeta`
      imeta_fid <- newFidRC (Proxy :: Proxy M0.PVer)
      fs <- M0.Filesystem <$> newFidRC (Proxy :: Proxy M0.Filesystem)
                          <*> return (M0.fid mdpool)
                          <*> return imeta_fid
      modifyGraph
          $ G.connect Cluster Has profile
        >>> G.connect Cluster Has M0.OFFLINE
        >>> G.connect Cluster M0.RunLevel (M0.BootLevel 0)
        >>> G.connect Cluster M0.StopLevel (M0.BootLevel 0)
        >>> G.connect profile M0.IsParentOf fs
        >>> G.connect fs M0.IsParentOf pool
        >>> G.connect fs M0.IsParentOf mdpool
        >>> G.connect Cluster Has root
        >>> G.connect root M0.IsParentOf profile

      rg <- getLocalGraph
      let re = [ (r, G.connectedTo r Has rg)
               | r <- G.connectedTo Cluster Has rg
               ]
      mapM_ (mirrorRack fs) re
      return fs
  where
    mirrorRack :: M0.Filesystem -> (Rack, [Enclosure]) -> PhaseM RC l ()
    mirrorRack fs (r, encls) = do
      m0r <- M0.Rack <$> newFidRC (Proxy :: Proxy M0.Rack)
      m0e <- mapM mirrorEncl encls
      modifyGraph
          $ G.connect m0r M0.At r
        >>> G.connect fs M0.IsParentOf m0r
        >>> ( foldl' (.) id
              $ fmap (G.connect m0r M0.IsParentOf) m0e)
    mirrorEncl :: Enclosure -> PhaseM RC l M0.Enclosure
    mirrorEncl r = lookupEnclosureM0 r >>= \case
      Just k -> return k
      Nothing -> do
         m0r <- M0.Enclosure <$> newFidRC (Proxy :: Proxy M0.Enclosure)
         modifyGraph $ G.connect m0r M0.At r
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
                -> PhaseM RC l ()
loadMeroServers fs = mapM_ goHost . offsetHosts where
  offsetHosts hosts = zip hosts
    (scanl' (\acc h -> acc + (length $ CI.m0h_devices h)) (0 :: Int) hosts)
  goHost (CI.M0Host{..}, hostIdx) = let
      host = Host m0h_fqdn
    in do
      Log.rcLog' Log.DEBUG $ "Adding host " ++ show host
      node <- M0.Node <$> newFidRC (Proxy :: Proxy M0.Node)

      modifyGraph $ G.connect Cluster Has host
                >>> G.connect host Has HA_M0SERVER
                >>> G.connect fs M0.IsParentOf node
                >>> G.connect host Runs node

      if not (null m0h_devices) then do
        ctrl <- M0.Controller <$> newFidRC (Proxy :: Proxy M0.Controller)
        rg <- getLocalGraph
        let (m0enc,enc) = fromMaybe (error "loadMeroServers: can't find enclosure") $ do
              e <- G.connectedFrom Has host rg :: Maybe Enclosure
              m0e <- G.connectedFrom M0.At e rg :: Maybe M0.Enclosure
              return (m0e, e)

        devs <- mapM (goDev enc ctrl)
                     (zip m0h_devices [hostIdx..length m0h_devices + hostIdx])
        mapM_ (goProc node devs) m0h_processes


        modifyGraph $ G.connect m0enc M0.IsParentOf ctrl
                  >>> G.connect ctrl M0.At host
                  >>> G.connect node M0.IsOnHardware ctrl
      else
        mapM_ (goProc node []) m0h_processes

  goProc node devs CI.M0Process{..} = let
      cores = bitmapFromArray
        . fmap (> 0)
        $ m0p_cores
      mkProc fid = M0.Process fid m0p_mem_as m0p_mem_rss
                              m0p_mem_stack m0p_mem_memlock
                              cores m0p_endpoint
      procLabel = case m0p_boot_level of
        CI.PLM0t1fs -> M0.PLM0t1fs
        CI.PLClovis a b -> M0.PLClovis a b
        CI.PLM0d x -> M0.PLM0d $ M0.BootLevel (fromIntegral x)
        CI.PLHalon -> M0.PLHalon
      procEnv rg = (mkProcEnv rg) <$> fromMaybe [] m0p_environment
      mkProcEnv _ (key, CI.M0PEnvValue val) = M0.ProcessEnvValue key val
      mkProcEnv rg (key, CI.M0PEnvRange from to) = let
          used = [ i | (proc :: M0.Process) <- G.connectedTo node M0.IsParentOf rg
                     , M0.ProcessEnvInRange k i <- G.connectedTo proc Has rg
                     , k == key
                 ]
          fstUnused = case filter (flip notElem used) [from .. to] of
            (x:_) -> x
            [] -> error $ "Specified range for " ++ show key ++ " is insufficient."
        in M0.ProcessEnvInRange key fstUnused
    in do
      rg <- getLocalGraph
      proc <- mkProc <$> newFidRC (Proxy :: Proxy M0.Process)
      mapM_ (goSrv proc devs) m0p_services

      modifyGraph $ G.connect node M0.IsParentOf proc
                >>> G.connect proc Has procLabel

      for_ (procEnv rg) $ \pe -> modifyGraph $
        G.connect proc Has pe

  goSrv proc devs CI.M0Service{..} = let
      filteredDevs = maybe
        devs
        (\x -> filter (\y -> M0.d_path y =~ x) devs)
        m0s_pathfilter
      mkSrv fid = M0.Service fid m0s_type m0s_endpoints m0s_params
      linkDrives svc = case m0s_type of
        CST_IOS -> foldl' (.) id
                    $ fmap (G.connect svc M0.IsParentOf) filteredDevs
        _ -> id
    in do
      svc <- mkSrv <$> newFidRC (Proxy :: Proxy M0.Service)
      modifyGraph $ G.connect proc M0.IsParentOf svc >>> linkDrives svc

  goDev enc ctrl (CI.M0Device{..}, idx) = let
      mkSDev fid = M0.SDev fid (fromIntegral idx) m0d_size m0d_bsize m0d_path
      devIds = [ DIWWN m0d_wwn
               , DIPath m0d_path
               ]
    in do
      let sdev = StorageDevice m0d_serial
          slot = Slot enc m0d_slot
      StorageDevice.identify sdev devIds
      m0sdev <- lookupStorageDeviceSDev sdev >>= \case
        Just m0sdev -> return m0sdev
        Nothing -> mkSDev <$> newFidRC (Proxy :: Proxy M0.SDev)
      m0disk <- lookupSDevDisk m0sdev >>= \case
        Just m0disk -> return m0disk
        Nothing -> M0.Disk <$> newFidRC (Proxy :: Proxy M0.Disk)
      StorageDevice.poweron sdev
      modifyGraph
          $ G.connect ctrl M0.IsParentOf m0disk
        >>> G.connect m0sdev M0.IsOnHardware m0disk
        >>> G.connect m0disk M0.At sdev
        >>> G.connect m0sdev M0.At slot
        >>> G.connect sdev Has slot
        >>> G.connect enc Has slot
        >>> G.connect Cluster Has sdev
      return m0sdev

-- | Create a pool version for the MDPool. This should have one device in
--   each controller.
createMDPoolPVer :: M0.Filesystem -> PhaseM RC l ()
createMDPoolPVer fs = getLocalGraph >>= \rg -> let
    mdpool = M0.Pool (M0.f_mdpool_fid fs)
    racks = G.connectedTo fs M0.IsParentOf rg :: [M0.Rack]
    encls = (\r -> G.connectedTo r M0.IsParentOf rg :: [M0.Enclosure]) =<< racks
    ctrls = (\r -> G.connectedTo r M0.IsParentOf rg :: [M0.Controller]) =<< encls
    disks = (\r -> take 1 $ G.connectedTo r M0.IsParentOf rg :: [M0.Disk]) =<< ctrls
    fids = Set.unions . (fmap Set.fromList) $
            [ (M0.fid <$> racks)
            , (M0.fid <$> encls)
            , (M0.fid <$> ctrls)
            , (M0.fid <$> disks)
            ]
    failures = Failures 0 0 0 1 0
    attrs = PDClustAttr {
        _pa_N = fromIntegral $ length disks
      , _pa_K = 0
      , _pa_P = 0 -- Will be overridden
      , _pa_unit_size = 4096
      , _pa_seed = Word128 101 101
    }
    pver = PoolVersion Nothing fids failures attrs
  in do
    Log.actLog "createMDPoolPVer" [("fs", M0.showFid fs)]
    Log.rcLog' Log.DEBUG $ "Creating PVer in metadata pool: " ++ show pver
    modifyGraph $ createPoolVersionsInPool fs mdpool [pver] False

-- | Create an imeta_pver along with all associated structures. This should
--   create:
--   - A (fake) disk entity for each CAS service in the graph.
--   - A single top-level pool for the imeta service.
--   - A single (actual) pool version in this pool containing all above disks.
--   Since the disks created here are fake, they will not have an associated
--   'StorageDevice'.
--
--   If there are no CAS services in the graph, then we have a slight
--   problem, since it is invalid to have a zero-width pver (e.g. a pver with
--   no associated devices). In this case, we use the special FID 'M0_FID0'
--   in the 'f_imeta_pver' field. This should validate correctly in Mero iff
--   there are no CAS services.
createIMeta :: M0.Filesystem -> PhaseM RC l ()
createIMeta fs = do
  Log.actLog "createIMeta" [("fs", M0.showFid fs)]
  pool <- M0.Pool <$> newFidRC (Proxy :: Proxy M0.Pool)
  rg <- getLocalGraph
  let cas = [ (rack, encl, ctrl, srv)
            | node <- G.connectedTo fs M0.IsParentOf rg :: [M0.Node]
            , proc <- G.connectedTo node M0.IsParentOf rg :: [M0.Process]
            , srv <- G.connectedTo proc M0.IsParentOf rg :: [M0.Service]
            , M0.s_type srv == CST_CAS
            , Just ctrl <- [G.connectedTo node M0.IsOnHardware rg :: Maybe M0.Controller]
            , Just encl <- [G.connectedFrom M0.IsParentOf ctrl rg :: Maybe M0.Enclosure]
            , Just rack <- [G.connectedFrom M0.IsParentOf encl rg :: Maybe M0.Rack]
            ]
      attrs = PDClustAttr {
                _pa_N = fromIntegral $ length cas
              , _pa_K = 0
              , _pa_P = 0 -- Will be overridden
              , _pa_unit_size = 4096
              , _pa_seed = Word128 101 102
              }
      failures = Failures 0 0 0 1 0
      maxDiskIdx = maximum [ M0.d_idx disk | disk <- Drive.getAllSDev rg ]
  fids <- for (zip cas [1.. length cas]) $ \((rack, encl, ctrl, srv), idx) -> do
    sdev <- M0.SDev <$> newFidRC (Proxy :: Proxy M0.SDev)
                    <*> return (fromIntegral idx + maxDiskIdx)
                    <*> return 1024
                    <*> return 1
                    <*> return "/dev/null"
    disk <- M0.Disk <$> newFidRC (Proxy :: Proxy M0.Disk)
    modifyGraph
        $ G.connect ctrl M0.IsParentOf disk
      >>> G.connect sdev M0.IsOnHardware disk
      >>> G.connect srv M0.IsParentOf sdev
    return [M0.fid rack, M0.fid encl, M0.fid ctrl, M0.fid disk]

  let pver = PoolVersion (Just $ M0.f_imeta_fid fs)
                          (Set.unions $ Set.fromList <$> fids) failures attrs
      -- If there are no CAS services then we need to replace the Filesystem
      -- entity with one containing the special M0_FID0 value. We can't do this
      -- before since we create the filesystem before we create services in the
      -- graph.
      updateGraph = if null cas
        then G.mergeResources head
                [M0.Filesystem (M0.f_fid fs) (M0.f_mdpool_fid fs) m0_fid0, fs]
        else G.connect fs M0.IsParentOf pool
          >>> createPoolVersionsInPool fs pool [pver] False

  modifyGraph updateGraph
