{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs            #-}
{-# LANGUAGE LambdaCase       #-}
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
import           Control.Monad (replicateM_, when)
import           Data.Foldable (foldl', for_)
import           Data.List (notElem, scanl')
import           Data.Maybe (fromMaybe)
import           Data.Proxy
import qualified Data.Set as Set
import qualified Data.Text as T
import           Data.Traversable (for)
import           HA.RecoveryCoordinator.Castor.Drive.Actions as Drive
import qualified HA.RecoveryCoordinator.Castor.Process.Actions as Process
import qualified HA.RecoveryCoordinator.Hardware.StorageDevice.Actions as StorageDevice
import           HA.RecoveryCoordinator.Mero.Actions.Conf
  ( getFilesystem
  , lookupM0Enclosure
  )
import           HA.RecoveryCoordinator.Mero.Actions.Core
import           HA.RecoveryCoordinator.Mero.Actions.Conf (getRoot)
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
import           Mero.Lnet
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
      root_fid <- genRootFid -- the first newFidRC call is made here
      -- XXX-MULTIPOOLS: create as many profiles as there are in the facts file
      profile <- M0.Profile <$> newFidRC (Proxy :: Proxy M0.Profile)
      pool <- M0.Pool <$> newFidRC (Proxy :: Proxy M0.Pool)
      mdpool <- M0.Pool <$> newFidRC (Proxy :: Proxy M0.Pool)
      -- Note that `createIMeta` may replace this FID with m0_fid0.
      imeta_pver <- newFidRC (Proxy :: Proxy M0.PVer)
      let root = M0.Root root_fid (M0.fid mdpool) imeta_pver
      fs <- M0.Filesystem <$> newFidRC (Proxy :: Proxy M0.Filesystem) -- XXX-MULTIPOOLS: DELETEME
      modifyGraph
          $ G.connect Cluster Has root
        >>> G.connect Cluster Has M0.OFFLINE
        >>> G.connect Cluster M0.RunLevel (M0.BootLevel 0)
        >>> G.connect Cluster M0.StopLevel (M0.BootLevel 0)
        >>> G.connect root M0.IsParentOf profile
        >>> G.connect Cluster Has profile -- XXX-MULTIPOOLS: delete this relation?
        >>> G.connect profile M0.IsParentOf fs
        >>> G.connect root M0.IsParentOf pool
        >>> G.connect root M0.IsParentOf mdpool

      rg <- getGraph
      mapM_ mirrorSite (G.connectedTo Cluster Has rg)
      return fs
  where
    genRootFid = do
        let p = Proxy :: Proxy M0.Root
            root_0 = M0.fidInit p 1 0
        -- Root fid must be equal to M0_CONF_ROOT_FID=<7400000000000001:0>
        -- (see HALON-770).
        -- Only the first newFidRC call can generate fid with f_key == 0.
        -- That's why fid of the root object must be generated first.
        fid <- newFidRC p
        when (fid /= root_0) $
            error ("initialiseConfInRG.genRootFid: Expected " ++ show root_0
                   ++ ", got " ++ show fid)
        pure fid

    mirrorSite :: Site -> PhaseM RC l ()
    mirrorSite site = do
      m0site <- M0.Site <$> newFidRC (Proxy :: Proxy M0.Site)
      rg <- getGraph
      mapM_ (mirrorRack m0site) (G.connectedTo site Has rg)
      Just root <- getRoot
      modifyGraph
          $ G.connect m0site M0.At site
        >>> G.connect root M0.IsParentOf m0site

    mirrorRack :: M0.Site -> Rack -> PhaseM RC l ()
    mirrorRack m0site rack = do
      m0rack <- M0.Rack <$> newFidRC (Proxy :: Proxy M0.Rack)
      rg <- getGraph
      mapM_ (mirrorEncl m0rack) (G.connectedTo rack Has rg)
      modifyGraph
          $ G.connect m0rack M0.At rack
        >>> G.connect m0site M0.IsParentOf m0rack

    mirrorEncl :: M0.Rack -> Enclosure -> PhaseM RC l M0.Enclosure
    mirrorEncl m0rack encl = lookupM0Enclosure encl >>= \case
      Just m0encl -> return m0encl
      Nothing -> do
         m0encl <- M0.Enclosure <$> newFidRC (Proxy :: Proxy M0.Enclosure)
         modifyGraph
             $ G.connect m0encl M0.At encl
           >>> G.connect m0rack M0.IsParentOf m0encl
         return m0encl

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
loadMeroServers :: [CI.M0Host] -> PhaseM RC l ()
loadMeroServers = mapM_ goHost . offsetHosts where
  offsetHosts hosts = zip hosts
    (scanl' (\acc h -> acc + (length $ CI.m0h_devices h)) (0 :: Int) hosts)

  goHost (CI.M0Host{..}, hostIdx) = let
      host = Host $! T.unpack m0h_fqdn
    in do
      Log.rcLog' Log.DEBUG $ "Adding host " ++ show host
      node <- M0.Node <$> newFidRC (Proxy :: Proxy M0.Node)

      Just root <- getRoot
      modifyGraph $ G.connect Cluster Has host
                >>> G.connect host Has HA_M0SERVER
                >>> G.connect root M0.IsParentOf node
                >>> G.connect host Runs node

      if null m0h_devices
      then
        mapM_ (addProcess node []) m0h_processes
      else do
        ctrl <- M0.Controller <$> newFidRC (Proxy :: Proxy M0.Controller)
        rg <- getGraph
        let (m0enc, enc) = fromMaybe (error "loadMeroServers: can't find enclosure") $ do
              e <- G.connectedFrom Has host rg :: Maybe Enclosure
              m0e <- G.connectedFrom M0.At e rg :: Maybe M0.Enclosure
              return (m0e, e)

        devs <- mapM (goDev enc ctrl)
                     (zip m0h_devices [hostIdx..length m0h_devices + hostIdx])
        mapM_ (addProcess node devs) m0h_processes

        modifyGraph $ G.connect m0enc M0.IsParentOf ctrl
                  >>> G.connect ctrl M0.At host
                  >>> G.connect node M0.IsOnHardware ctrl

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

-- | Add a process into the resource graph.
--   Where multiplicity is greater than 1, this will add multiple processes
--   into the RG.
addProcess :: M0.Node -- ^ Node hosting the Process.
           -> [M0.SDev] -- ^ Devices attached to this process.
           -> CI.M0Process -- ^ Initial process configuration.
           -> PhaseM RC l ()
addProcess node devs CI.M0Process{..} = let
    cores = bitmapFromArray
      . fmap (> 0)
      $ m0p_cores
    mkProc fid ep = M0.Process fid m0p_mem_as m0p_mem_rss
                            m0p_mem_stack m0p_mem_memlock
                            cores ep
    procLabel = case m0p_boot_level of
      CI.PLM0t1fs -> M0.PLM0t1fs
      CI.PLClovis a b -> M0.PLClovis a b
      CI.PLM0d x -> M0.PLM0d $ M0.BootLevel (fromIntegral x)
      CI.PLHalon -> M0.PLHalon
    mkEndpoint = do
        exProcEps <- fmap M0.r_endpoint . Process.getAll <$> getGraph
        return $ findEP m0p_endpoint exProcEps
      where
        findEP ep eps =
          if ep `notElem` eps
          then ep
          else findEP (increment ep) eps
        increment ep = ep
          { transfer_machine_id = transfer_machine_id ep + 1 }
    procEnv rg = mkProcEnv rg <$> fromMaybe [] m0p_environment
    mkProcEnv _ (key, CI.M0PEnvValue val) = M0.ProcessEnvValue key val
    mkProcEnv rg (key, CI.M0PEnvRange from to) = let
        used = [ i | proc :: M0.Process <- G.connectedTo node M0.IsParentOf rg
                   , M0.ProcessEnvInRange k i <- G.connectedTo proc Has rg
                   , k == key
               ]
        fstUnused = case filter (flip notElem used) [from .. to] of
          (x:_) -> x
          [] -> error $ "Specified range for " ++ show key ++ " is insufficient."
      in M0.ProcessEnvInRange key fstUnused
    goSrv proc ep CI.M0Service{..} = let
        filteredDevs = maybe
          devs
          (\x -> filter (\y -> M0.d_path y =~ x) devs)
          m0s_pathfilter
        mkSrv fid = M0.Service fid m0s_type [ep]
        linkDrives svc = case m0s_type of
          CST_IOS -> foldl' (.) id
                      $ fmap (G.connect svc M0.IsParentOf) filteredDevs
          _ -> id
      in do
        svc <- mkSrv <$> newFidRC (Proxy :: Proxy M0.Service)
        modifyGraph $ G.connect proc M0.IsParentOf svc >>> linkDrives svc
  in replicateM_ (fromMaybe 1 m0p_multiplicity) $ do
    ep <- mkEndpoint
    proc <- mkProc <$> newFidRC (Proxy :: Proxy M0.Process)
                   <*> return ep
    mapM_ (goSrv proc ep) m0p_services

    modifyGraph $ G.connect node M0.IsParentOf proc
              >>> G.connect proc Has procLabel

    rg <- getGraph
    for_ (procEnv rg) $ \pe ->
      modifyGraph (G.connect proc Has pe)

-- | Create a pool version for the MDPool. This should have one device in
--   each controller.
createMDPoolPVer :: M0.Filesystem -> PhaseM RC l ()
createMDPoolPVer fs = do
    Log.actLog "createMDPoolPVer" [("fs", M0.showFid fs)]
    rg <- getGraph
    let root = M0.getM0Root rg
        mdpool = M0.Pool (M0.rt_mdpool root)
        sites = G.connectedTo root M0.IsParentOf rg :: [M0.Site]
        racks = (\x -> G.connectedTo x M0.IsParentOf rg :: [M0.Rack])
                =<< sites
        encls = (\x -> G.connectedTo x M0.IsParentOf rg :: [M0.Enclosure])
                =<< racks
        ctrls = (\x -> G.connectedTo x M0.IsParentOf rg :: [M0.Controller])
                =<< encls
        -- XXX-MULTIPOOLS: Halon should not invent which disks belong to the
        -- meta-data pool --- it should use the information provided via
        -- `id_pools` section of the facts file.
        disks = (\x -> take 1 $ G.connectedTo x M0.IsParentOf rg :: [M0.Disk])
                =<< ctrls
        fids = Set.unions . (fmap Set.fromList) $
                [ (M0.fid <$> racks)
                , (M0.fid <$> encls)
                , (M0.fid <$> ctrls)
                , (M0.fid <$> disks)
                ]
        failures = Failures 0 0 0 1 0
        -- XXX FIXME: Get this info from facts file.
        attrs = PDClustAttr
                { _pa_N = fromIntegral $ length disks
                , _pa_K = 0
                , _pa_P = 0 -- Will be overridden
                , _pa_unit_size = 4096
                , _pa_seed = Word128 101 101
                }
        pver = PoolVersion Nothing fids failures attrs
    Log.rcLog' Log.DEBUG $ "Creating PVer in metadata pool: " ++ show pver
    modifyGraph $ createPoolVersionsInPool mdpool [pver] False

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
--   in the 'rt_imeta' field. This should validate correctly in Mero iff
--   there are no CAS services.
createIMeta :: M0.Filesystem -> PhaseM RC l ()
createIMeta fs = do
  Log.actLog "createIMeta" [("fs", M0.showFid fs)]
  pool <- M0.Pool <$> newFidRC (Proxy :: Proxy M0.Pool)
  rg <- getGraph
  let root = M0.getM0Root rg
      cas = [ (site, rack, encl, ctrl, svc)
            | node <- M0.getM0Nodes rg
            , proc :: M0.Process <- G.connectedTo node M0.IsParentOf rg
            , svc :: M0.Service <- G.connectedTo proc M0.IsParentOf rg
            , M0.s_type svc == CST_CAS
            , Just (ctrl :: M0.Controller) <- [G.connectedTo node M0.IsOnHardware rg]
            , Just (encl :: M0.Enclosure) <- [G.connectedFrom M0.IsParentOf ctrl rg]
            , Just (rack :: M0.Rack) <- [G.connectedFrom M0.IsParentOf encl rg]
            , Just (site :: M0.Site) <- [G.connectedFrom M0.IsParentOf rack rg]
            ]
      attrs = PDClustAttr {
                _pa_N = 1 -- For CAS service `N` must always be equal to `1` as
                          -- CAS records are indivisible pieces of data:  the
                          -- whole CAS record is always stored on one node.
              , _pa_K = 0
              , _pa_P = 0 -- Will be overridden
              , _pa_unit_size = 4096
              , _pa_seed = Word128 101 102
              }
      failures = Failures 0 0 0 1 0
      maxDiskIdx = maximum [ M0.d_idx disk | disk <- Drive.getAllSDev rg ]
  fids <- for (zip cas [1..]) $ \((site, rack, encl, ctrl, svc), idx :: Int) -> do
    sdev <- M0.SDev <$> newFidRC (Proxy :: Proxy M0.SDev)
                    <*> return (fromIntegral idx + maxDiskIdx)
                    <*> return 1024
                    <*> return 1
                    <*> return "/dev/null"
    disk <- M0.Disk <$> newFidRC (Proxy :: Proxy M0.Disk)
    modifyGraph
        $ G.connect ctrl M0.IsParentOf disk
      >>> G.connect sdev M0.IsOnHardware disk
      >>> G.connect svc M0.IsParentOf sdev
    return [M0.fid site, M0.fid rack, M0.fid encl, M0.fid ctrl, M0.fid disk]

  let pver = PoolVersion (Just $ M0.rt_imeta_pver root)
                          (Set.unions $ Set.fromList <$> fids) failures attrs
      -- If there are no CAS services then we need to replace the M0.Root
      -- entity with one containing the special M0_FID0 value. We can't do this
      -- before since we create the root before we create services in the
      -- graph.
      updateGraph = if null cas
        then G.mergeResources head [root {M0.rt_imeta_pver = m0_fid0}, root]
        else G.connect root M0.IsParentOf pool
          >>> createPoolVersionsInPool pool [pver] False

  modifyGraph updateGraph
