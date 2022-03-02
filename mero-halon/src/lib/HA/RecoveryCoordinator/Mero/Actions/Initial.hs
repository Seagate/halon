{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs            #-}
{-# LANGUAGE LambdaCase       #-}
-- |
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
module HA.RecoveryCoordinator.Mero.Actions.Initial
  ( initialiseConfInRG
  , loadMeroPools
  , loadMeroProfiles
  , loadMeroServers
  ) where

import           Control.Category ((>>>))
import           Control.Monad (replicateM_, when)
import           Control.Monad.Catch (Exception, throwM)
import           Data.Either (partitionEithers)
import           Data.Foldable (foldl', for_)
import           Data.List (intercalate, notElem, scanl')
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe (fromJust, fromMaybe)
import           Data.MultiMap (MultiMap)
import qualified Data.MultiMap as MMap
import           Data.Proxy
import qualified Data.Set as Set
import qualified Data.Text as T
import           Data.Traversable (for)
import           HA.RecoveryCoordinator.Castor.Drive.Actions as Drive
import qualified HA.RecoveryCoordinator.Castor.Process.Actions as Process
import qualified HA.RecoveryCoordinator.Hardware.StorageDevice.Actions as StorageDevice
import           HA.RecoveryCoordinator.Mero.Actions.Conf
  ( getRoot
  , lookupM0Enclosure
  )
import           HA.RecoveryCoordinator.Mero.Actions.Core
import           HA.RecoveryCoordinator.Mero.PVerGen
  ( addPVerFormulaic
  , newPVerRC
  )
import           HA.RecoveryCoordinator.RC.Actions.Core
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..), Has(..), Runs(..))
import qualified HA.Resources.Castor as Cas
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import           Mero.ConfC
  ( ServiceType(CST_CAS,CST_IOS)
  , Word128(..)
  , bitmapFromArray
  , m0_fid0
  )
import           Mero.Lnet
import           Network.CEP
import           Text.Printf (printf)
import           Text.Regex.TDFA ((=~))

-- | Initialise a reflection of the Mero configuration in the resource graph.
initialiseConfInRG :: PhaseM RC l ()
initialiseConfInRG = do
    root_fid <- mkRootFid -- the first newFidRC call is made here
    mdpool <- newFidRC (Proxy :: Proxy M0.Pool)  -- XXX-MULTIPOOLS QnD
    -- Note that createDIXPool may replace `imeta_pver` fid with m0_fid0.
    --
    -- XXX We might have checked CI.InitialData here and use m0_fid0 if there
    -- are no CST_CAS services in the InitialData.
    imeta_pver <- newFidRC (Proxy :: Proxy M0.PVer)
    let root = M0.Root root_fid mdpool imeta_pver
    modifyGraph $ G.connect Cluster Has root
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

    mirrorSite :: Cas.Site -> PhaseM RC l ()
    mirrorSite site = do
      m0site <- M0.Site <$> newFidRC (Proxy :: Proxy M0.Site)
      rg <- getGraph
      mapM_ (mirrorRack m0site) (G.connectedTo site Has rg)
      Just root <- getRoot
      modifyGraph
          $ G.connect m0site M0.At site
        >>> G.connect root M0.IsParentOf m0site

    mirrorRack :: M0.Site -> Cas.Rack -> PhaseM RC l ()
    mirrorRack m0site rack = do
      m0rack <- M0.Rack <$> newFidRC (Proxy :: Proxy M0.Rack)
      rg <- getGraph
      mapM_ (mirrorEncl m0rack) (G.connectedTo rack Has rg)
      modifyGraph
          $ G.connect m0rack M0.At rack
        >>> G.connect m0site M0.IsParentOf m0rack

    mirrorEncl :: M0.Rack -> Cas.Enclosure -> PhaseM RC l M0.Enclosure
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
--     - 'Cas.Host' (Halon representation)
--     - 'M0.Controller' (physical host)
--     - 'M0.Node' (logical host)
--     - 'M0.Process' (Mero process)
--   Then we add all drives (storage devices) into the system, involving:
--     - 'Cas.StorageDevice' (Halon representation)
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
    let host = Cas.Host $! T.unpack m0h_fqdn
    Log.rcLog' Log.DEBUG $ "Adding host " ++ show host
    node <- M0.Node <$> newFidRC (Proxy :: Proxy M0.Node)
    Just root <- getRoot
    modifyGraph $ G.connect Cluster Has host
              >>> G.connect host Has Cas.HA_M0SERVER
              >>> G.connect root M0.IsParentOf node
              >>> G.connect host Runs node
    if null m0h_devices
    then
      mapM_ (addProcess node []) m0h_processes
    else do
      ctrl <- M0.Controller <$> newFidRC (Proxy :: Proxy M0.Controller)
      rg <- getGraph
      let (m0enc, enc) = fromMaybe (error "loadMeroServers: Cannot find enclosure") $ do
            e <- G.connectedFrom Has host rg :: Maybe Cas.Enclosure
            m0e <- G.connectedFrom M0.At e rg :: Maybe M0.Enclosure
            return (m0e, e)
      devs <- mapM (goDev enc ctrl) (zip m0h_devices [hostIdx..])
      mapM_ (addProcess node devs) m0h_processes
      modifyGraph $ G.connect m0enc M0.IsParentOf ctrl
                >>> G.connect ctrl M0.At host
                >>> G.connect node M0.IsOnHardware ctrl

  goDev :: Cas.Enclosure -> M0.Controller -> (CI.M0Device, Int)
        -> PhaseM RC l M0.SDev
  goDev encl ctrl (CI.M0Device{..}, idx) = do
    let mkSDev fid = M0.SDev fid (fromIntegral idx) m0d_size m0d_bsize m0d_path
        sdev = Cas.StorageDevice m0d_serial
        slot = Cas.Slot encl m0d_slot
    StorageDevice.identify sdev [Cas.DIWWN m0d_wwn, Cas.DIPath m0d_path]
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

-- | Try to find 'Cas.StorageDevice' which 'CI.M0DeviceRef' points at.
dereference :: G.Graph -> CI.M0DeviceRef -> Either String Cas.StorageDevice
dereference rg ref@CI.M0DeviceRef{..} = do
    let ds = [ d
             | d@(Cas.StorageDevice serial) <- G.connectedTo Cluster Has rg
             , let ids = G.connectedTo d Has rg :: [Cas.DeviceIdentifier]
             , maybe True (T.pack serial ==) dr_serial
             , maybe True ((flip elem) ids . Cas.DIWWN . T.unpack) dr_wwn
             , maybe True ((flip elem) ids . Cas.DIPath . T.unpack) dr_path
             ]
    case ds of
        [d] -> Right d
        []  -> Left $ "No target: " ++ show ref
        _   -> Left $ "Multiple targets: " ++ show ref

disksFromRefs :: [CI.M0DeviceRef] -> G.Graph -> Either String [M0.Disk]
disksFromRefs refs rg = case partitionEithers (dereference rg <$> refs) of
    ([], sdevs) ->
        let mm :: MultiMap Cas.StorageDevice CI.M0DeviceRef
            mm = MMap.fromList (zip sdevs refs)

            manyElems = not . null . drop 1

            overReferenced :: [Cas.StorageDevice]
            overReferenced = Map.keys $ Map.filter manyElems (MMap.toMap mm)

            mkErr :: Cas.StorageDevice -> String
            mkErr sdev = printf "%s is referred to by several M0DeviceRefs: %s"
                (show sdev) (intercalate ", " $ show <$> mm MMap.! sdev)

            linkedDisk :: Cas.StorageDevice -> M0.Disk
            linkedDisk sdev = fromJust (G.connectedFrom M0.At sdev rg)
        in
            if null overReferenced
            then Right $ map linkedDisk sdevs
            else Left $ intercalate "\n" (mkErr <$> overReferenced)
    (errs, _) -> Left $ intercalate "\n" errs

-- | Add pools and profiles to the resource graph.
loadMeroPools :: [CI.M0Pool] -> PhaseM RC l (Map T.Text M0.Pool)
loadMeroPools ipools = do
    let args_XXX = zip ipools (True:repeat False)  -- XXX-MULTIPOOLS QnD
    snsPools <- mapM createSNSPool args_XXX
    createDIXPool
    pure (Map.fromList snsPools)

data PoolCreationError = PoolCreationError T.Text String
  deriving Show
instance Exception PoolCreationError

-- | Add an SNS pool to the resource graph.
--
--   This function creates:
--   - an actual ("base") pool version;
--   - formulaic pool versions;
--   - a meta-data pool version.
createSNSPool :: (CI.M0Pool, Bool) -> PhaseM RC l (T.Text, M0.Pool)
createSNSPool (CI.M0Pool{..}, metadata_p_XXX) = do
    let throw' :: String -> PhaseM RC l a
        throw' = throwM . PoolCreationError pool_id

    Just root <- getRoot
    pool <- M0.Pool <$> newFidRC (Proxy :: Proxy M0.Pool)
    modifyGraph $ G.connect pool Has (M0.PoolId pool_id)
              >>> G.connect root M0.IsParentOf pool

    disks <- getGraph >>=
        either throw' pure . disksFromRefs pool_device_refs
    base <- newPVerRC Nothing pool_pdclust_attrs Nothing disks
    modifyGraph $ G.connect pool M0.IsParentOf base
    mapM_ (modifyGraph . addPVerFormulaic pool base) pool_allowed_failures

    -- Meta-data pool version.
    when metadata_p_XXX $ do  -- XXX-MULTIPOOLS QnD
        rg <- getGraph
        let disks1 = Set.toList . Set.fromList $
                     [ d1
                     | disk <- disks
                     , let Just (ctrl :: M0.Controller) =
                            G.connectedFrom M0.IsParentOf disk rg
                     , d1 :: M0.Disk <- take 1 $ G.connectedTo ctrl M0.IsParentOf rg
                     ]
            attrs = CI.PDClustAttrs0
              { pa0_data_units = fromIntegral (length disks1)
              , pa0_parity_units = 0
              , pa0_unit_size = 4096
              , pa0_seed = Word128 101 101
              }
            tolerance = CI.Failures 0 0 0 1 0
            mdpool = M0.Pool (M0.rt_mdpool root)  -- XXX-MULTIPOOLS QnD
        md <- newPVerRC Nothing attrs (Just tolerance) disks1
        modifyGraph $ G.connect md Cas.Is M0.MetadataPVer
                  >>> G.connect mdpool M0.IsParentOf md
                  >>> G.connect root M0.IsParentOf mdpool
    pure (pool_id, pool)

-- | Create a pool containing imeta_pver.
--
--   If there are 'CST_CAS' services, this will create:
--   - a fake 'M0.SDev' for each CAS service in the graph;
--   - a fake 'M0.Disk' for each CAS service in the graph;
--   - a single pool for the imeta service;
--   - a single (actual) pool version in this pool containing all above disks.
--
--   Since the disks created here are fake, they will not have an associated
--   'Cas.StorageDevice'.
--
--   If there are no CAS services in the graph, then we have a slight
--   problem, since it is invalid to have a zero-width pver (e.g. a pver with
--   no associated devices). In this case, we use the special FID 'M0_FID0'
--   in the 'rt_imeta_pver' field. This should validate correctly in Mero
--   iff there are no CAS services.
--
-- NOTE: 'createDIXPool' must not be called before 'createSNSPool'.
--       Otherwise fake 'M0.Disk's, created by 'createDIXPool', will be
--       added to SNS pool, and we don't want that.
createDIXPool :: PhaseM RC l ()
createDIXPool = do
    let attrs = CI.PDClustAttrs0
          { CI.pa0_data_units = 1
            -- For CAS service N must always be equal to 1 as CAS records are
            -- indivisible pieces of data: the whole CAS record is always
            -- stored on one node.
          , CI.pa0_parity_units = 0
          , CI.pa0_unit_size = 4096
          , CI.pa0_seed = Word128 101 102
          }
        tolerance = CI.Failures 0 0 0 1 0
    Just root <- getRoot
    rg <- getGraph
    let cas = [ (svc, ctrl)
              | node <- M0.getM0Nodes rg
              , proc :: M0.Process <- G.connectedTo node M0.IsParentOf rg
              , svc :: M0.Service <- G.connectedTo proc M0.IsParentOf rg
              , M0.s_type svc == CST_CAS
              , let Just (ctrl :: M0.Controller) =
                        G.connectedTo node M0.IsOnHardware rg
              ]
    if null cas
    then modifyGraph $ G.mergeResources head [ root {M0.rt_imeta_pver = m0_fid0}
                                             , root
                                             ]
    else do
        pool <- M0.Pool <$> newFidRC (Proxy :: Proxy M0.Pool)
        modifyGraph $ G.connect root M0.IsParentOf pool
        let maxDevIdx = maximum [M0.d_idx sdev | sdev <- Drive.getAllSDev rg]
        disks <- for (zip cas [1..]) $ \((svc, ctrl), idx :: Int) -> do
            sdev <- M0.SDev <$> newFidRC (Proxy :: Proxy M0.SDev)
                            <*> pure (maxDevIdx + fromIntegral idx)
                            <*> pure 1024
                            <*> pure 1
                            <*> pure "/dev/null"
            disk <- M0.Disk <$> newFidRC (Proxy :: Proxy M0.Disk)
            modifyGraph $ G.connect svc M0.IsParentOf sdev
                      >>> G.connect sdev M0.IsOnHardware disk
                      >>> G.connect ctrl M0.IsParentOf disk
            pure disk
        pver <- newPVerRC (Just $ M0.rt_imeta_pver root) attrs (Just tolerance)
            disks
        modifyGraph $ G.connect pool M0.IsParentOf pver

data ProfileCreationError = ProfileCreationError String
  deriving Show
instance Exception ProfileCreationError

-- | Add profiles to the resource graph.
loadMeroProfiles :: [CI.M0Profile] -> Map T.Text M0.Pool -> PhaseM RC l ()
loadMeroProfiles profiles pools = do
    Just root <- getRoot
    for_ profiles $ \CI.M0Profile{..} -> do
        profile <- M0.Profile <$> newFidRC (Proxy :: Proxy M0.Profile)
        modifyGraph $ G.connect root M0.IsParentOf profile
        for_ prof_pools $ \pool_id ->
            case Map.lookup pool_id pools of
                Nothing -> throwM . ProfileCreationError
                  $ printf "Profile '%s' points at non-existent pool '%s'"
                    (T.unpack prof_id) (T.unpack pool_id)
                Just pool -> modifyGraph $ G.connect profile Has pool
