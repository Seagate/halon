-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE LambdaCase                 #-}

module HA.RecoveryCoordinator.Actions.Mero.Conf
  ( -- * Initialization
    initialiseConfInRG
    -- * Queries
  , queryObjectStatus
  , setObjectStatus
    -- ** Get all objects of type
  , getProfile
  , getFilesystem
  , getSDevPools
  , getM0ServicesRC
  , getChildren
  , getParents
  , loadMeroServers
    -- ** Lookup objects based on another
  , lookupConfObjByFid
  , lookupStorageDevice
  , lookupStorageDeviceSDev
  , lookupStorageDeviceOnHost
  , lookupEnclosureM0
  , lookupHostHAAddress
  ) where

import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Hardware
import HA.RecoveryCoordinator.Actions.Mero.Core
import qualified HA.ResourceGraph as G
import HA.Resources (Cluster(..), Has(..), Runs(..))
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

import Data.Foldable (foldl')
import Data.Maybe (listToMaybe)
import Data.Proxy
import Data.UUID.V4 (nextRandom)

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
      root    <- M0.Root    <$> newFidRC (Proxy :: Proxy M0.Root)
      profile <- M0.Profile <$> newFidRC (Proxy :: Proxy M0.Profile)
      pool <- M0.Pool <$> newFidRC (Proxy :: Proxy M0.Pool)
      fs <- M0.Filesystem <$> newFidRC (Proxy :: Proxy M0.Filesystem)
                          <*> return (M0.fid pool)
      modifyGraph
          $ G.newResource root
        >>> G.newResource profile
        >>> G.newResource fs
        >>> G.newResource pool
        >>> G.connectUniqueFrom Cluster Has profile
        >>> G.connectUniqueFrom profile M0.IsParentOf fs
        >>> G.connect fs M0.IsParentOf pool
        >>> G.connectUniqueFrom Cluster Has root
        >>> G.connect root M0.IsParentOf profile

      rg <- getLocalGraph
      let re = [ (r, G.connectedTo r Has rg)
               | r <- G.connectedTo Cluster Has rg
               ]
      mapM_ (mirrorRack fs) re
      return fs
  where
    mirrorRack :: M0.Filesystem -> (Rack, [Enclosure]) -> PhaseM LoopState l ()
    mirrorRack fs (r, encls) = do
      m0r <- M0.Rack <$> newFidRC (Proxy :: Proxy M0.Rack)
      m0e <- mapM mirrorEncl encls
      modifyGraph
          $ G.newResource m0r
        >>> G.connectUnique m0r M0.At r
        >>> G.connect fs M0.IsParentOf m0r
        >>> ( foldl' (.) id
              $ fmap (G.connect m0r M0.IsParentOf) m0e)
    mirrorEncl :: Enclosure -> PhaseM LoopState l M0.Enclosure
    mirrorEncl r = lookupEnclosureM0 r >>= \case
      Just k -> return k
      Nothing -> do
         m0r <- M0.Enclosure <$> newFidRC (Proxy :: Proxy M0.Enclosure)
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
      ctrl <- M0.Controller <$> newFidRC (Proxy :: Proxy M0.Controller)
      node <- M0.Node <$> newFidRC (Proxy :: Proxy M0.Node)

      devs <- mapM (goDev host ctrl) (zip m0h_devices [1..length m0h_devices + 1])
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
                >>> G.connect host Runs node

  goProc node devs CI.M0Process{..} = let
      cores = bitmapFromArray
        . fmap (> 0)
        $ m0p_cores
      mkProc fid = M0.Process fid m0p_mem_as m0p_mem_rss
                              m0p_mem_stack m0p_mem_memlock
                              cores m0p_endpoint
      procLabel = if
          elem CST_MGS $ fmap CI.m0s_type m0p_services
        then M0.PLConfdBoot
        else M0.PLRegularBoot
    in do
      proc <- mkProc <$> newFidRC (Proxy :: Proxy M0.Process)
      mapM_ (goSrv proc devs) m0p_services

      modifyGraph $ G.newResource proc
                >>> G.newResource proc
                >>> G.newResource procLabel
                >>> G.connect node M0.IsParentOf proc
                >>> G.connectUniqueFrom proc Has procLabel

  goSrv proc devs CI.M0Service{..} = let
      mkSrv fid = M0.Service fid m0s_type m0s_endpoints m0s_params
      linkDrives svc = case m0s_type of
        CST_IOS -> foldl' (.) id
                    $ fmap (G.connect svc M0.IsParentOf) devs
        _ -> id
    in do
      svc <- mkSrv <$> newFidRC (Proxy :: Proxy M0.Service)
      modifyLocalGraph $ return
                       . (    G.newResource svc
                          >>> G.connect proc M0.IsParentOf svc
                          >>> linkDrives svc
                         )

  goDev host ctrl (CI.M0Device{..}, idx) = let
      mkSDev fid = M0.SDev fid (fromIntegral idx) m0d_size m0d_bsize m0d_path
      devIds = [ DIWWN m0d_wwn
               , DIPath m0d_path
               ]
    in do
      sdev <- lookupStorageDeviceOnHost host (DIWWN m0d_wwn) >>= \case
        Just sdev -> return sdev
        Nothing -> do
          sdev <- StorageDevice <$> liftIO nextRandom
          mapM_ (identifyStorageDevice sdev) devIds
          locateStorageDeviceOnHost host sdev
          return sdev
      m0sdev <- lookupStorageDeviceSDev sdev >>= \case
        Just m0sdev -> return m0sdev
        Nothing -> mkSDev <$> newFidRC (Proxy :: Proxy M0.SDev)
      m0disk <- lookupSDevDisk m0sdev >>= \case
        Just m0disk -> return m0disk
        Nothing -> M0.Disk <$> newFidRC (Proxy :: Proxy M0.Disk)
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

-- | RC wrapper for 'getM0Services'.
getM0ServicesRC :: PhaseM LoopState l [M0.Service]
getM0ServicesRC = do
  phaseLog "rg-query" "Looking for Mero services."
  M0.getM0Services <$> getLocalGraph

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
  phaseLog "rg-query" $ "Looking up M0.Disk objects attached to sdev " ++ show sdev
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

lookupEnclosureM0 :: Enclosure -> PhaseM LoopState l (Maybe M0.Enclosure)
lookupEnclosureM0 enc =
  listToMaybe . G.connectedFrom M0.At enc <$> getLocalGraph

-- | Lookup the HA endpoint to be used for the node. This is stored as the
--   endpoint for the HA service hosted by processes on that node. Whilst in
--   theory different processes might have different HA endpoints, in
--   practice this should not happen.
lookupHostHAAddress :: Host -> PhaseM LoopState l (Maybe String)
lookupHostHAAddress host = getLocalGraph >>= \rg -> return $ listToMaybe
  [ ep | node <- G.connectedTo host Runs rg :: [M0.Node]
        , ps <- G.connectedTo node M0.IsParentOf rg :: [M0.Process]
        , svc <- G.connectedTo ps M0.IsParentOf rg ::[M0.Service]
        , M0.s_type svc == CST_HA
        , ep <- M0.s_endpoints svc
        ]

-- | Get all children of the conf object.
getChildren :: G.Relation M0.IsParentOf a b => a -> PhaseM LoopState l [b]
getChildren obj = do
  phaseLog "rg-query" $ "Get all children of the " ++ show obj ++ " holds."
  G.connectedTo obj M0.IsParentOf <$> getLocalGraph

-- | Get parrents of the conf objects.
getParents :: G.Relation M0.IsParentOf a b => b -> PhaseM LoopState l [a]
getParents obj = do
  phaseLog "rg-query" $ "Get all parents of the " ++ show obj ++ " holds."
  G.connectedFrom M0.IsParentOf obj <$> getLocalGraph

-- | Query current status of the conf object.
queryObjectStatus :: (G.Relation Is a M0.ConfObjectState) => a
                  -> PhaseM LoopState l (Maybe M0.ConfObjectState)
queryObjectStatus obj = do
  phaseLog "rg-query" $ "Lookup status for " ++ show obj ++ " holds."
  listToMaybe . G.connectedTo obj Is <$> getLocalGraph
{-# INLINE queryObjectStatus #-}

-- | Set object in a new state.
setObjectStatus :: (G.Relation Is a M0.ConfObjectState) => a
                -> M0.ConfObjectState
                -> PhaseM LoopState l ()
setObjectStatus obj state = modifyGraph $ G.connectUnique obj Is state
