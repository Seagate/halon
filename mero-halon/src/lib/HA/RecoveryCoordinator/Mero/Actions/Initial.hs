{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs            #-}
{-# LANGUAGE LambdaCase       #-}
-- |
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
module HA.RecoveryCoordinator.Mero.Actions.Initial
  ( -- * Initialization
    initialiseConfInRG
  , loadMeroPools
  , loadMeroServers
  , createMDPoolPVer
  , createIMeta
  ) where

import           Control.Category ((>>>))
import           Control.Exception (assert)
import           Control.Monad (replicateM_, when)
import           Control.Monad.Catch (Exception, throwM)
import           Control.Monad.Trans.Class (lift)
import           Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
import qualified Control.Monad.Trans.State.Lazy as S
import           Data.Bifunctor (first)
import           Data.Foldable (foldl', for_)
import           Data.Functor.Identity (Identity(runIdentity))
import           Data.List (notElem, scanl')
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe (fromMaybe, isNothing)
import           Data.Proxy
import qualified Data.Set as Set
import qualified Data.Text as T
import           Data.Traversable (for)
import           HA.RecoveryCoordinator.Castor.Drive.Actions as Drive
import qualified HA.RecoveryCoordinator.Castor.Process.Actions as Process
import qualified HA.RecoveryCoordinator.Hardware.StorageDevice.Actions as StorageDevice
import           HA.RecoveryCoordinator.Mero.Actions.Conf (lookupM0Enclosure)
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
import           Mero.ConfC
  ( Fid
  , PDClustAttr(..)
  , ServiceType(CST_CAS,CST_IOS)
  , Word128(..)
  , bitmapFromArray
  , m0_fid0
  )
import           Mero.Lnet
import           Network.CEP
import           Text.Regex.TDFA ((=~))

-- | Initialise a reflection of the Mero configuration in the resource graph.
initialiseConfInRG :: PhaseM RC l ()
initialiseConfInRG = do
    root_fid <- mkRootFid -- the first newFidRC call is made here
    mdpool_fid <- newFidRC (Proxy :: Proxy M0.Pool)
    -- Note that `createIMeta` may replace `imeta_pver` fid with m0_fid0.
    imeta_pver <- newFidRC (Proxy :: Proxy M0.PVer)
    let root = M0.Root root_fid mdpool_fid imeta_pver
    modifyGraph
        $ G.connect Cluster Has root
      >>> G.connect Cluster Has M0.OFFLINE
      >>> G.connect Cluster M0.RunLevel (M0.BootLevel 0)
      >>> G.connect Cluster M0.StopLevel (M0.BootLevel 0)
    rg <- getGraph
    mapM_ mirrorSite (G.connectedTo Cluster Has rg)
  where
    mkRootFid = do
        let p = Proxy :: Proxy M0.Root
            root_0 = M0.fidInit p 1 0
        -- Root fid must be equal to M0_CONF_ROOT_FID=<7400000000000001:0>
        -- (see HALON-770).
        -- Only the first newFidRC call can generate fid with f_key == 0.
        -- That's why fid of the root object must be generated first.
        fid <- newFidRC p
        when (fid /= root_0) $
            error ("initialiseConfInRG.mkRootFid: Expected " ++ show root_0
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
--   For each 'CI.M0Host', we add the following:
--     - 'Host' (Halon representation)
--     - 'M0.Controller' (physical host)
--     - 'M0.Node' (logical host)
--     - 'M0.Process' (Mero process)
--   Then we add all drives (storage devices) into the system, involving:
--     - 'StorageDevice' (Halon representation)
--     - 'M0.Disk' (physical device)
--     - 'M0.SDev' (logical device)
--   We then add any relevant services running on this process. If one is
--   an ioservice (and it should be!), we link the sdevs to the IOService.
loadMeroServers :: [CI.M0Host] -> PhaseM RC l ()
loadMeroServers = mapM_ goHost . offsetHosts where
  offsetHosts hosts = zip hosts
    (scanl' (\acc h -> acc + (length $ CI.m0h_devices h)) (0 :: Int) hosts)

  goHost :: (CI.M0Host, Int) -> PhaseM RC l ()
  goHost (CI.M0Host{..}, hostIdx) = do
    let host = Host $! T.unpack m0h_fqdn
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
      let (m0enc, enc) = fromMaybe (error "loadMeroServers: Cannot find enclosure") $ do
            e <- G.connectedFrom Has host rg :: Maybe Enclosure
            m0e <- G.connectedFrom M0.At e rg :: Maybe M0.Enclosure
            return (m0e, e)
      devs <- mapM (goDev enc ctrl) (zip m0h_devices [hostIdx..])
      mapM_ (addProcess node devs) m0h_processes
      modifyGraph $ G.connect m0enc M0.IsParentOf ctrl
                >>> G.connect ctrl M0.At host
                >>> G.connect node M0.IsOnHardware ctrl

  goDev :: Enclosure -> M0.Controller -> (CI.M0Device, Int)
        -> PhaseM RC l M0.SDev
  goDev encl ctrl (CI.M0Device{..}, idx) = do
    let mkSDev fid = M0.SDev fid (fromIntegral idx) m0d_size m0d_bsize m0d_path
        sdev = StorageDevice m0d_serial
        slot = Slot encl m0d_slot
    StorageDevice.identify sdev [DIWWN m0d_wwn, DIPath m0d_path]
    m0sdev <- lookupStorageDeviceSDev sdev >>=
        maybe (mkSDev <$> newFidRC (Proxy :: Proxy M0.SDev)) return
    m0disk <- lookupSDevDisk m0sdev >>=
        maybe (M0.Disk <$> newFidRC (Proxy :: Proxy M0.Disk)) return
    StorageDevice.poweron sdev
    modifyGraph
        $ G.connect ctrl M0.IsParentOf m0disk
      >>> G.connect m0sdev M0.IsOnHardware m0disk
      >>> G.connect m0disk M0.At sdev
      >>> G.connect m0sdev M0.At slot
      >>> G.connect sdev Has slot
      >>> G.connect encl Has slot
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
    cores = bitmapFromArray $ map (> 0) m0p_cores
    mkProc fid ep = M0.Process fid m0p_mem_as m0p_mem_rss m0p_mem_stack
                               m0p_mem_memlock cores ep
    mkEndpoint = do
        exProcEps <- map M0.r_endpoint . Process.getAll <$> getGraph
        return $ findEP m0p_endpoint exProcEps
      where
        findEP ep eps | ep `notElem` eps = ep
                      | otherwise        = findEP (increment ep) eps
        increment ep = ep { transfer_machine_id = transfer_machine_id ep + 1 }

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

    goSvc proc ep CI.M0Service{..} = let
        filteredDevs = maybe
          devs
          (\x -> filter (\y -> M0.d_path y =~ x) devs)
          m0s_pathfilter
        mkSrv fid = M0.Service fid m0s_type [ep]
        linkDevs svc = case m0s_type of
          CST_IOS -> foldl' (.) id
                      $ fmap (G.connect svc M0.IsParentOf) filteredDevs
          _ -> id
      in do
        svc <- mkSrv <$> newFidRC (Proxy :: Proxy M0.Service)
        modifyGraph $ G.connect proc M0.IsParentOf svc >>> linkDevs svc

  in replicateM_ (fromMaybe 1 m0p_multiplicity) $ do
    ep <- mkEndpoint
    proc <- mkProc <$> newFidRC (Proxy :: Proxy M0.Process)
                   <*> return ep
    mapM_ (goSvc proc ep) m0p_services
    modifyGraph $ G.connect node M0.IsParentOf proc
              >>> G.connect proc Has m0p_boot_level
    rg <- getGraph
    for_ (procEnv rg) $ \pe ->
      modifyGraph (G.connect proc Has pe)

type StateExceptT s e m a = S.StateT s (ExceptT e m) a

runStateExceptT :: Monad m => StateExceptT s e m a -> s -> m (Either e (a, s))
runStateExceptT m = runExceptT . S.runStateT m

type StateExcept s e a = StateExceptT s e Identity a

runStateExcept :: StateExcept s e a -> s -> Either e (a, s)
runStateExcept m = runIdentity . runStateExceptT m

-- | State updated during pool version tree construction.
type PVerState
  = ( G.Graph      -- ^ Resource graph.
    , Map Fid Fid  -- ^ Pool version devices.  Maps fid of real object
                   --   to the fid of corresponding virtual object.
    )

type PVerGen a = StateExcept PVerState String a

-- | Try to find 'StorageDevice' which 'CI.M0DeviceRef' points at.
dereference :: CI.M0DeviceRef -> G.Graph -> Either String StorageDevice
dereference ref@CI.M0DeviceRef{..} rg = do
    let ds = [ d
             | d@(StorageDevice serial) <- G.connectedTo Cluster Has rg
             , let ids = G.connectedTo d Has rg :: [DeviceIdentifier]
             , maybe True (T.pack serial ==) dr_serial
             , maybe True ((flip elem) ids . DIWWN . T.unpack) dr_wwn
             , maybe True ((flip elem) ids . DIPath . T.unpack) dr_path
             ]
    case ds of
        [d] -> Right d
        []  -> Left $ "No target: " ++ show ref
        _   -> Left $ "Multiple targets: " ++ show ref

-- | Generate new 'Fid' for the given 'M0.ConfObj' type.
newFidPVerGen :: M0.ConfObj a => Proxy a -> Fid -> PVerGen Fid
newFidPVerGen p real = do
    (rg, devs) <- S.get
    assert (Map.notMember real devs) (pure ())
    let (virt, rg') = newFid p rg
        devs' = Map.insert real virt devs
    S.put (rg', devs')
    pure virt

newtype PVerGenError = PVerGenError String
  deriving Show
instance Exception PVerGenError

-- | Build pool version tree.
buildPVer :: M0.PVer -> [CI.M0DeviceRef] -> PVerGen ()
buildPVer pver refs = for_ refs $ \ref -> do
    let throw' = lift . throwE
        modifyG = S.modify' . first

    -- Find disk
    disk :: M0.Disk <- do
        (rg, devs) <- S.get
        sdev <- either throw' pure (dereference ref rg)
        let Just disk = G.connectedFrom M0.At sdev rg
        when (Map.member (M0.fid disk) devs) $
            throw' $ "Multiple M0DeviceRefs point at " ++ show sdev
        pure disk

    -- Disk level
    diskv <- M0.DiskV <$> newFidPVerGen (Proxy :: Proxy M0.DiskV) (M0.fid disk)
    modifyG $ G.connect disk M0.IsRealOf diskv

    -- Controller level
    (ctrl :: M0.Controller, mctrlv_fid) <- S.gets $ \(rg, devs) ->
        let Just ctrl = G.connectedFrom M0.IsParentOf disk rg
        in (ctrl, Map.lookup (M0.fid ctrl) devs)
    ctrlv <- M0.ControllerV <$>
        maybe (newFidPVerGen (Proxy :: Proxy M0.ControllerV) (M0.fid ctrl))
              pure
              mctrlv_fid
    when (isNothing mctrlv_fid) $
        modifyG $ G.connect ctrl M0.IsRealOf ctrlv
    modifyG $ G.connect ctrlv M0.IsParentOf diskv

    -- Enclosure level
    (encl :: M0.Enclosure, menclv_fid) <- S.gets $ \(rg, devs) ->
        let Just encl = G.connectedFrom M0.IsParentOf ctrl rg
        in (encl, Map.lookup (M0.fid encl) devs)
    enclv <- M0.EnclosureV <$>
        maybe (newFidPVerGen (Proxy :: Proxy M0.EnclosureV) (M0.fid encl))
              pure
              menclv_fid
    when (isNothing menclv_fid) $
        modifyG $ G.connect encl M0.IsRealOf enclv
    modifyG $ G.connect enclv M0.IsParentOf ctrlv

    -- Rack level
    (rack :: M0.Rack, mrackv_fid) <- S.gets $ \(rg, devs) ->
        let Just rack = G.connectedFrom M0.IsParentOf encl rg
        in (rack, Map.lookup (M0.fid rack) devs)
    rackv <- M0.RackV <$>
        maybe (newFidPVerGen (Proxy :: Proxy M0.RackV) (M0.fid rack))
              pure
              mrackv_fid
    when (isNothing mrackv_fid) $
        modifyG $ G.connect rack M0.IsRealOf rackv
    modifyG $ G.connect rackv M0.IsParentOf enclv

    -- Site level
    (site :: M0.Site, msitev_fid) <- S.gets $ \(rg, devs) ->
        let Just site = G.connectedFrom M0.IsParentOf rack rg
        in (site, Map.lookup (M0.fid site) devs)
    sitev <- M0.SiteV <$>
        maybe (newFidPVerGen (Proxy :: Proxy M0.SiteV) (M0.fid site))
              pure
              msitev_fid
    when (isNothing msitev_fid) $
        modifyG $ G.connect site M0.IsRealOf sitev
    modifyG $ G.connect sitev M0.IsParentOf rackv
          >>> G.connect pver M0.IsParentOf sitev

loadMeroPools :: [CI.M0Pool] -> [CI.M0Profile] -> PhaseM RC l ()
loadMeroPools pools profiles = do
    Just root <- getRoot
    for_ pools $ \ipool -> do
        pool <- M0.Pool <$> if CI.isMDPool ipool  -- 'CI.validateInitialData'
                                                  -- guarantees that there is
                                                  -- exactly one MD pool.
                            then pure $ M0.rt_mdpool root
                            else newFidRC (Proxy :: Proxy M0.Pool)
        let attrs = PDClustAttr { _pa_N = undefined  -- CI.m0_data_units globs
                                , _pa_K = undefined  -- CI.m0_parity_units globs
                                , _pa_P = undefined  -- 0  -- XXX
                                , _pa_unit_size = 4096
                                , _pa_seed = Word128 101 102
                                }
            tolerance = error "XXX IMPLEMENTME"
        pver <- M0.PVer <$> newFidRC (Proxy :: Proxy M0.PVer)
                        <*> (pure . Right $ M0.PVerActual attrs tolerance)
        modifyGraph $ G.connect root M0.IsParentOf pool
                  >>> G.connect pool M0.IsParentOf pver
        modifyGraphM $ \rg ->
            let buildPool = runStateExcept
                                (buildPVer pver $ CI.pool_device_refs ipool)
                                (rg, Map.empty)
            in either (throwM . PVerGenError) (pure . fst . snd) buildPool

    for_ profiles $ \_ -> do
        profile <- M0.Profile <$> newFidRC (Proxy :: Proxy M0.Profile)
        modifyGraph $ G.connect root M0.IsParentOf profile
        error "XXX IMPLEMENTME: Link profile with its pools"

-- | Create a pool version for the MDPool. This should have one device in
--   each controller.
createMDPoolPVer :: PhaseM RC l ()
createMDPoolPVer = do
    Log.actLog "createMDPoolPVer" []
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
        fids = Set.unions . fmap Set.fromList $
                [ M0.fid <$> sites
                , M0.fid <$> racks
                , M0.fid <$> encls
                , M0.fid <$> ctrls
                , M0.fid <$> disks
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
    modifyGraph $ createPoolVersionsInPool mdpool [pver] DevicesWorking

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
createIMeta :: PhaseM RC l ()
createIMeta = do
  Log.actLog "createIMeta" []
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
          >>> createPoolVersionsInPool pool [pver] DevicesWorking

  modifyGraph updateGraph
