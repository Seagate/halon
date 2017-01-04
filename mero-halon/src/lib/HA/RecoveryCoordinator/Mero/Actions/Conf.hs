{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}
-- |
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
module HA.RecoveryCoordinator.Mero.Actions.Conf
  ( -- * Initialization
    initialiseConfInRG
  , loadMeroServers
  , createMDPoolPVer
  , createIMeta
    -- ** Get all objects of type
  , getProfile
  , getFilesystem
  , getPool
  , getSDevPool
  , getPoolSDevs
  , getPoolSDevsWithState
  , getM0ServicesRC
  , getChildren
  , getParents
    -- ** Lookup objects based on another
  , lookupConfObjByFid
  , lookupStorageDevice
  , lookupStorageDeviceSDev
  , lookupStorageDeviceOnHost
  , lookupDiskSDev
  , lookupEnclosureM0
  , lookupHostHAAddress
  , lookupSDevDisk
    -- ** Other things
  , getPrincipalRM
  , isPrincipalRM
  , setPrincipalRMIfUnset
  , pickPrincipalRM
  , markSDevReplaced
  , unmarkSDevReplaced
  , attachStorageDeviceToSDev
    -- * Low level graph API
  , rgGetPool
  , m0encToEnc
  , encToM0Enc
    -- * Other
  , associateLocationWithSDev
  , lookupLocationSDev
  ) where

import           Control.Category ((>>>))
import           Control.Monad (guard)
import           Data.Foldable (foldl')
import qualified Data.HashSet as S
import           Data.List (scanl')
import           Data.Maybe (listToMaybe, fromMaybe, mapMaybe)
import           Data.Proxy
import qualified Data.Set as Set
import           Data.Traversable (for)
import           Data.Typeable (Typeable)
import           HA.RecoveryCoordinator.Actions.Hardware
import qualified HA.RecoveryCoordinator.Hardware.StorageDevice.Actions as StorageDevice
import           HA.RecoveryCoordinator.Mero.Actions.Core
import           HA.RecoveryCoordinator.Mero.Failure.Internal
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..), Has(..), Runs(..))
import           HA.Resources.Castor
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           Mero.ConfC
  ( Fid
  , PDClustAttr(..)
  , ServiceType(..)
  , Word128(..)
  , bitmapFromArray
  )
import           Network.CEP
import           Text.Regex.TDFA ((=~))

-- | Lookup a configuration object by its Mero FID.
lookupConfObjByFid :: (G.Resource a, M0.ConfObj a, Typeable a)
                   => Fid
                   -> PhaseM RC l (Maybe a)
lookupConfObjByFid f =
    fmap (M0.lookupConfObjByFid f) getLocalGraph

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
         x | x < 0 -> M0.PLNoBoot
         99 -> M0.PLM0t1fs
         x -> M0.PLBootLevel $ M0.BootLevel (fromIntegral x)
    in do
      proc <- mkProc <$> newFidRC (Proxy :: Proxy M0.Process)
      mapM_ (goSrv proc devs) m0p_services

      modifyGraph $ G.connect node M0.IsParentOf proc
                >>> G.connect proc Has procLabel

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
      StorageDevice.identify sdev devIds
      -- XXX: we can't insert via location, as we don't have enough info for that
      -- currently, once halon_facts will have that we may move.
      -- Log.rcLog' Log.DEBUG $ show (enc, sdev)
      locateStorageDeviceInEnclosure enc sdev
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
    phaseLog "info" $ "Creating PVer in metadata pool: " ++ show pver
    modifyGraph $ createPoolVersionsInPool fs mdpool [pver] False

-- | Create an imeta_pver along with all associated structures. This should
--   create:
--   - A (fake) disk entity for each CAS service in the graph.
--   - A single top-level pool for the imeta service.
--   - A single (actual) pool version in this pool containing all above disks.
--   Since the disks created here are fake, they will not have an associated
--   'StorageDevice'.
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
  fids <- for (zip cas [0.. length cas]) $ \((rack, encl, ctrl, srv), idx) -> do
    sdev <- M0.SDev <$> newFidRC (Proxy :: Proxy M0.SDev)
                    <*> return (fromIntegral idx)
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

  modifyGraph
      $ G.connect fs M0.IsParentOf pool
    >>> createPoolVersionsInPool fs pool [pver] False

--------------------------------------------------------------------------------
-- Querying conf in RG
--------------------------------------------------------------------------------

-- | Fetch the Mero Profile in the system. Currently, we
--   only support a single profile, though in future there
--   might be multiple profiles and this function will need
--   to change.
getProfile :: PhaseM RC l (Maybe M0.Profile)
getProfile =
    G.connectedTo Cluster Has <$> getLocalGraph

-- | Fetch the Mero filesystem in the system. Currently, we
--   only support a single filesystem, though in future there
--   might be multiple filesystems and this function will need
--   to change.
getFilesystem :: PhaseM RC l (Maybe M0.Filesystem)
getFilesystem = getLocalGraph >>= \rg -> do
  return . listToMaybe
    $ [ fs | Just p <- [G.connectedTo Cluster Has rg :: Maybe M0.Profile]
           , fs <- G.connectedTo p M0.IsParentOf rg :: [M0.Filesystem]
      ]

-- | Fetch all (non-metadata) pools in the system.
getPool :: PhaseM RC l [M0.Pool]
getPool = rgGetPool <$> getLocalGraph

-- | Find all 'M0.Pool's in the RG that aren't metadata pools. See
-- also 'getPool'.
rgGetPool :: G.Graph -> [M0.Pool]
rgGetPool rg =
  [ pl
  | Just p <- [G.connectedTo Cluster Has rg :: Maybe M0.Profile]
  , fs <- G.connectedTo p M0.IsParentOf rg :: [M0.Filesystem]
  , pl <- G.connectedTo fs M0.IsParentOf rg
  , M0.fid pl /= M0.f_mdpool_fid fs
  ]

-- | RC wrapper for 'getM0Services'.
getM0ServicesRC :: PhaseM RC l [M0.Service]
getM0ServicesRC = M0.getM0Services <$> getLocalGraph

-- | Find 'StorageDevice' associated with the given 'M0.SDev'.
lookupStorageDevice :: M0.SDev -> PhaseM RC l (Maybe StorageDevice)
lookupStorageDevice sdev = do
    rg <- getLocalGraph
    return $ do
      dev  <- G.connectedTo sdev M0.IsOnHardware rg
      G.connectedTo (dev :: M0.Disk) M0.At rg

-- | Return the Mero SDev associated with the given storage device
lookupStorageDeviceSDev :: StorageDevice -> PhaseM RC l (Maybe M0.SDev)
lookupStorageDeviceSDev sdev = do
  rg <- getLocalGraph
  return $ do
    disk <- G.connectedFrom M0.At sdev rg
    G.connectedFrom M0.IsOnHardware (disk :: M0.Disk) rg

-- | Connect 'StorageDevice' with corresponcing 'M0.SDev'.
attachStorageDeviceToSDev :: StorageDevice -> M0.SDev -> PhaseM RC l ()
attachStorageDeviceToSDev sdev m0sdev = do
  rg <- getLocalGraph
  case G.connectedTo m0sdev M0.IsOnHardware rg of
    Nothing -> return ()
    Just disk -> modifyGraph $ G.connect (disk::M0.Disk) M0.At sdev
  

-- | Find 'M0.Disk' associated with the given 'M0.SDev'.
lookupSDevDisk :: M0.SDev -> PhaseM RC l (Maybe M0.Disk)
lookupSDevDisk sdev =
    G.connectedTo sdev M0.IsOnHardware <$> getLocalGraph

-- | Given a 'M0.Disk', find the 'M0.SDev' attached to it.
lookupDiskSDev :: M0.Disk -> PhaseM RC l (Maybe M0.SDev)
lookupDiskSDev disk =
    G.connectedFrom M0.IsOnHardware disk <$> getLocalGraph

-- | Find a pool the given 'M0.SDev' belongs to.
--
-- Fails if multiple pools are found. Metadata pool are ignored.
getSDevPool :: M0.SDev -> PhaseM RC l M0.Pool
getSDevPool sdev = do
    rg <- getLocalGraph
    let ps =
          [ p
          | Just d  <- [G.connectedTo sdev M0.IsOnHardware rg :: Maybe M0.Disk]
          , dv <- G.connectedTo d M0.IsRealOf rg :: [M0.DiskV]
          , Just (ct :: M0.ControllerV) <- [G.connectedFrom M0.IsParentOf dv rg]
          , Just (ev :: M0.EnclosureV) <- [G.connectedFrom M0.IsParentOf ct rg]
          , Just rv <- [G.connectedFrom M0.IsParentOf ev rg :: Maybe M0.RackV]
          , Just pv <- [G.connectedFrom M0.IsParentOf rv rg :: Maybe M0.PVer]
          , Just (p :: M0.Pool) <- [G.connectedFrom M0.IsRealOf pv rg]
          , Just (fs :: M0.Filesystem) <- [G.connectedFrom M0.IsParentOf p rg]
          , M0.fid p /= M0.f_mdpool_fid fs
          ]
    case ps of
      -- TODO throw a better exception
      [] -> error "getSDevPool: No pool found for sdev."
      x:[] -> return x
      x:_ -> do
        phaseLog "error" $ "Multiple pools found for sdev!"
        return x


-- | Get all 'M0.SDev's that belong to the given 'M0.Pool'.
--
-- Works on the assumption that every disk belonging to the pool
-- appears in at least one pool version belonging to the pool. In
-- other words,
--
-- "If pool doesn't contain a disk in some pool version => disk
-- doesn't belong to the pool." See discussion at
-- https://seagate.slack.com/archives/mero-halon/p1457632533003295 for
-- details.
getPoolSDevs :: M0.Pool -> PhaseM RC l [M0.SDev]
getPoolSDevs pool = getLocalGraph >>= \rg -> do
  -- Find SDevs for every single pool version belonging to the disk.
  let sdevs =
        [ sd
        | pv <- G.connectedTo pool M0.IsRealOf rg :: [M0.PVer]
        , rv <- G.connectedTo pv M0.IsParentOf rg :: [M0.RackV]
        , ev <- G.connectedTo rv M0.IsParentOf rg :: [M0.EnclosureV]
        , ct <- G.connectedTo ev M0.IsParentOf rg :: [M0.ControllerV]
        , dv <- G.connectedTo ct M0.IsParentOf rg :: [M0.DiskV]
        , Just d <- [G.connectedFrom M0.IsRealOf dv rg :: Maybe M0.Disk]
        , Just sd <- [G.connectedFrom M0.IsOnHardware d rg :: Maybe M0.SDev]
        ]
  -- Find the largest sdev set, that is the set holding all disks.
  return . S.toList . S.fromList $ sdevs

-- | Get all 'M0.SDev's in the given 'M0.Pool' with the given
-- 'M0.ConfObjState'.
getPoolSDevsWithState :: M0.Pool -> M0.ConfObjectState
                       -> PhaseM RC l [M0.SDev]
getPoolSDevsWithState pool st = getPoolSDevs pool >>= \devs -> do
  rg <- getLocalGraph
  let sts = (\d -> (M0.getConfObjState d rg, d)) <$> devs
  return . map snd . filter ((== st) . fst) $ sts

-- | Find 'M0.Enclosure' object associated with 'Enclosure'.
lookupEnclosureM0 :: Enclosure -> PhaseM RC l (Maybe M0.Enclosure)
lookupEnclosureM0 enc =
    G.connectedFrom M0.At enc <$> getLocalGraph

-- | Lookup the HA endpoint to be used for the node. This is stored as the
--   endpoint for the HA service hosted by processes on that node. Whilst in
--   theory different processes might have different HA endpoints, in
--   practice this should not happen.
lookupHostHAAddress :: Host -> PhaseM RC l (Maybe String)
lookupHostHAAddress host = getLocalGraph >>= \rg -> return $ listToMaybe
  [ ep | node <- G.connectedTo host Runs rg :: [M0.Node]
        , ps <- G.connectedTo node M0.IsParentOf rg :: [M0.Process]
        , svc <- G.connectedTo ps M0.IsParentOf rg :: [M0.Service]
        , M0.s_type svc == CST_HA
        , ep <- M0.s_endpoints svc
        ]

-- | Get all children of the conf object.
getChildren :: forall a b l. G.Relation M0.IsParentOf a b
            => a -> PhaseM RC l [b]
getChildren obj = G.connectedToList obj M0.IsParentOf <$> getLocalGraph

-- | Get parents of the conf objects.
getParents :: forall a b l. G.Relation M0.IsParentOf a b
           => b -> PhaseM RC l [a]
getParents obj = G.connectedFromList M0.IsParentOf obj <$> getLocalGraph

-- | Test if a service is the principal RM service
isPrincipalRM :: M0.Service
              -> PhaseM RC l Bool
isPrincipalRM svc = getLocalGraph >>=
  return . G.isConnected svc Is M0.PrincipalRM

-- | Get the 'M0.Service' that's serving as the current 'M0.PrincipalRM'.
getPrincipalRM :: PhaseM RC l (Maybe M0.Service)
getPrincipalRM = getLocalGraph >>= \rg ->
  return . listToMaybe
    . filter (\x -> M0.getState x rg == M0.SSOnline)
    $ G.connectedFrom Is M0.PrincipalRM rg

-- | Set the given 'M0.Service' to be the 'M0.PrincipalRM' if one is
-- not yet set. Returns the principal RM which becomes current: old
-- one if already set, new one otherwise.
setPrincipalRMIfUnset :: M0.Service
                      -> PhaseM RC l M0.Service
setPrincipalRMIfUnset svc = getPrincipalRM >>= \case
  Just rm -> return rm
  Nothing -> do
    modifyGraph $ G.connect Cluster Has M0.PrincipalRM
              >>> G.connect svc Is M0.PrincipalRM
    return svc

-- | Pick a Principal RM out of the available RM services.
pickPrincipalRM :: PhaseM RC l (Maybe M0.Service)
pickPrincipalRM = getLocalGraph >>= \g ->
  let rms =
        [ rm
        | Just (prof :: M0.Profile) <-
            [G.connectedTo Cluster Has g]
        , (fs :: M0.Filesystem) <-
            G.connectedTo prof M0.IsParentOf g
        , (node :: M0.Node) <- G.connectedTo fs M0.IsParentOf g
        , (proc :: M0.Process) <-
            G.connectedTo node M0.IsParentOf g
        , G.isConnected proc Is M0.PSOnline g
        , let srv_types = M0.s_type <$>
                (G.connectedTo proc M0.IsParentOf g)
        , CST_MGS `elem` srv_types
        , rm <- G.connectedTo proc M0.IsParentOf g :: [M0.Service]
        , G.isConnected proc Is M0.PSOnline g
        , M0.s_type rm == CST_RMS
        ]
  in traverse setPrincipalRMIfUnset $ listToMaybe rms

-- | Lookup enclosure corresponding to Mero enclosure.
m0encToEnc :: M0.Enclosure -> G.Graph -> Maybe R.Enclosure
m0encToEnc m0enc rg = G.connectedTo m0enc M0.At rg

-- | Lookup Mero enclosure corresponding to enclosure.
encToM0Enc :: R.Enclosure -> G.Graph -> Maybe M0.Enclosure
encToM0Enc enc rg = G.connectedFrom M0.At enc rg

-- | Update link from 'StorageDeviceLocation' to corresponding storage
-- device, this link is needed to properly process drive updates.
--
-- In case if 'M0.SDev' is already attached - this is noop.
associateLocationWithSDev :: R.Slot -> PhaseM RC l ()
associateLocationWithSDev loc = modifyGraph $ \g -> case G.connectedFrom M0.At loc g of
    Just  (_::M0.SDev) -> g
    Nothing -> fromMaybe g $ do
      sdev   :: StorageDevice <- G.connectedFrom Has loc g
      m0disk :: M0.Disk     <- G.connectedFrom M0.At sdev g
      m0sdev <- G.connectedFrom M0.IsOnHardware m0disk g
      path   <- listToMaybe . mapMaybe getPath $ G.connectedTo sdev Has g
      guard  $ path == M0.d_path m0sdev
      return $ G.connect m0sdev M0.At loc g
  where
    getPath (DIPath p) = Just p
    getPath _ = Nothing

-- | Find 'M0.SDev' that associated with a given location.
lookupLocationSDev :: R.Slot -> PhaseM RC l (Maybe M0.SDev)
lookupLocationSDev loc = G.connectedFrom M0.At loc <$> getLocalGraph

-- | Mark 'M0.SDev' as replaced, so it could be rebalanced if needed.
markSDevReplaced :: M0.SDev -> PhaseM RC l ()
markSDevReplaced sdev = modifyGraph $ \rg ->
  maybe rg (\disk -> G.connect (disk::M0.Disk) Is M0.Replaced rg)
  $ G.connectedTo sdev M0.IsOnHardware rg

-- | Mark 'M0.SDev' as replaced, so it could be rebalanced if needed.
unmarkSDevReplaced :: M0.SDev -> PhaseM RC l ()
unmarkSDevReplaced sdev = modifyGraph $ \rg ->
  maybe rg (\disk -> G.disconnect (disk::M0.Disk) Is M0.Replaced rg)
  $ G.connectedTo sdev M0.IsOnHardware rg
