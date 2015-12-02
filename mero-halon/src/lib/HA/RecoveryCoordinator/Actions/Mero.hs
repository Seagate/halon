-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE LambdaCase                 #-}

module HA.RecoveryCoordinator.Actions.Mero
  ( getFilesystem
  , getProfile
  , getM0Globals
  , loadConfData
  , lookupConfObjByFid
  , txOpen
  , txOpenContext
  , txSyncToConfd
  , txDumpToFile
  , txPopulate
  , getSpielAddress
  , withRootRC
  , withSpielRC
  , syncToConfd
  , rgLookupConfObjByFid
  , getSDevPools
  , startRepairOperation
  , startRebalanceOperation
  , lookupStorageDevice
  , lookupStorageDeviceSDev
  , lookupSDevDisk
  , actualizeStorageDeviceReplacement
  )
where

import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Hardware
import qualified HA.ResourceGraph as G
import HA.Resources (Cluster(..), Has(..))
import HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0

import Mero.ConfC (Fid, PDClustAttr(..), Word128(..), withConf, Root, ServiceType(..))
import Mero.M0Worker (liftM0)
import Mero.Notification
import Mero.Spiel hiding (start)
import qualified Mero.Spiel

import qualified Control.Distributed.Process as DP
import Control.Exception (SomeException)
import Control.Monad (forM_)
import Control.Monad.Catch (catch)
import Control.Applicative
import Control.Category ((>>>))

import Data.Foldable (traverse_)
import Data.List (nub)
import Data.Maybe (catMaybes, listToMaybe)

import Network.CEP
import Network.RPC.RPCLite (getRPCMachine_se, rpcAddress, RPCAddress(..))

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

getProfile :: PhaseM LoopState l (Maybe M0.Profile)
getProfile = getLocalGraph >>= \rg -> do
  phaseLog "rg-query" $ "Looking for Mero profile."
  return . listToMaybe
    $ G.connectedTo Cluster Has rg

getFilesystem :: PhaseM LoopState l (Maybe M0.Filesystem)
getFilesystem = getLocalGraph >>= \rg -> do
  phaseLog "rg-query" $ "Looking for Mero filesystem."
  return . listToMaybe
    $ [ fs | p <- G.connectedTo Cluster Has rg :: [M0.Profile]
           , fs <- G.connectedTo p M0.IsParentOf rg :: [M0.Filesystem]
      ]

getM0Globals :: PhaseM LoopState l (Maybe CI.M0Globals)
getM0Globals = getLocalGraph >>= \rg -> do
  phaseLog "rg-query" $ "Looking for Mero globals."
  return . listToMaybe
    $ G.connectedTo Cluster Has rg

---------------------------------------------------------------
-- Splicing configuration trees                              --
---------------------------------------------------------------

-- | Open a transaction. Ultimately this should not need a
--   spiel context.
txOpenContext :: SpielContext -> PhaseM LoopState l SpielTransaction
txOpenContext = liftM0 . openTransactionContext

txOpen :: PhaseM LoopState l SpielTransaction
txOpen = liftM0 openTransaction

txSyncToConfd :: SpielTransaction -> PhaseM LoopState l ()
txSyncToConfd t = do
  phaseLog "spiel" "Committing transaction to confd"
  liftM0 $ commitTransaction t
  phaseLog "spiel" "Transaction committed."
  liftM0 $ closeTransaction t
  phaseLog "spiel" "Transaction closed."

txDumpToFile :: FilePath -> SpielTransaction -> PhaseM LoopState l ()
txDumpToFile fp t = do
  phaseLog "spiel" $ "Writing transaction to " ++ fp
  liftM0 $ dumpTransaction t fp
  phaseLog "spiel" "Transaction written."
  liftM0 $ closeTransaction t
  phaseLog "spiel" "Transaction closed."

data TxConfData = TxConfData M0.M0Globals M0.Profile M0.Filesystem

loadConfData :: PhaseM LoopState l (Maybe TxConfData)
loadConfData = liftA3 TxConfData
            <$> getM0Globals
            <*> getProfile
            <*> getFilesystem

txPopulate :: TxConfData -> SpielTransaction -> PhaseM LoopState l SpielTransaction
txPopulate (TxConfData CI.M0Globals{..} (M0.Profile pfid) fs@M0.Filesystem{..}) t = do
  g <- getLocalGraph
  -- Profile, FS, pool
  liftM0 $ do
    addProfile t pfid
    addFilesystem t f_fid pfid m0_md_redundancy pfid f_mdpool_fid []
    addPool t f_mdpool_fid f_fid 0
  phaseLog "spiel" "Added profile, filesystem, mdpool objects."
  -- Racks, encls, controllers, disks
  let racks = G.connectedTo fs M0.IsParentOf g :: [M0.Rack]
  forM_ racks $ \rack -> do
    liftM0 $ addRack t (M0.fid rack) f_fid
    let encls = G.connectedTo rack M0.IsParentOf g :: [M0.Enclosure]
    forM_ encls $ \encl -> do
      liftM0 $ addEnclosure t (M0.fid encl) (M0.fid rack)
      let ctrls = G.connectedTo encl M0.IsParentOf g :: [M0.Controller]
      forM_ ctrls $ \ctrl -> do
        -- Get node fid
        let (Just node) = listToMaybe
                        $ (G.connectedFrom M0.IsOnHardware ctrl g :: [M0.Node])
        liftM0 $ addController t (M0.fid ctrl) (M0.fid encl) (M0.fid node)
        let disks = G.connectedTo ctrl M0.IsParentOf g :: [M0.Disk]
        forM_ disks $ \disk -> do
          liftM0 $ addDisk t (M0.fid disk) (M0.fid ctrl)
  -- Nodes, processes, services, sdevs
  let nodes = G.connectedTo fs M0.IsParentOf g :: [M0.Node]
  forM_ nodes $ \node -> do
    let attrs =
          [ a | ctrl <- G.connectedTo node M0.IsOnHardware g :: [M0.Controller]
              , host <- G.connectedTo ctrl M0.At g :: [Host]
              , a <- G.connectedTo host Has g :: [HostAttr]]
        defaultMem = 1024
        defCPUCount = 1
        memsize = maybe defaultMem fromIntegral
                $ listToMaybe . catMaybes $ fmap getMem attrs
        cpucount = maybe defCPUCount fromIntegral
                 $ listToMaybe . catMaybes $ fmap getCpuCount attrs
        getMem (HA_MEMSIZE_MB x) = Just x
        getMem _ = Nothing
        getCpuCount (HA_CPU_COUNT x) = Just x
        getCpuCount _ = Nothing
    liftM0 $ addNode t (M0.fid node) f_fid memsize cpucount 0 0 f_mdpool_fid
    let procs = G.connectedTo node M0.IsParentOf g :: [M0.Process]
    forM_ procs $ \(proc@M0.Process{..}) -> do
      liftM0 $ addProcess t r_fid (M0.fid node) r_cores
                            r_mem_as r_mem_rss r_mem_stack r_mem_memlock
                            r_endpoint
      let servs = G.connectedTo proc M0.IsParentOf g :: [M0.Service]
      forM_ servs $ \(serv@M0.Service{..}) -> do
        liftM0 $ addService t s_fid r_fid (ServiceInfo s_type s_endpoints s_params)
        let sdevs = G.connectedTo serv M0.IsParentOf g :: [M0.SDev]
        forM_ sdevs $ \(sdev@M0.SDev{..}) -> do
          let (Just disk) = listToMaybe
                          $ (G.connectedTo sdev M0.IsOnHardware g :: [M0.Disk])
          liftM0 $ addDevice t d_fid s_fid (M0.fid disk) M0_CFG_DEVICE_INTERFACE_SATA
                      M0_CFG_DEVICE_MEDIA_DISK d_bsize d_size 0 0 d_path
  phaseLog "spiel" "Finished adding concrete entities."
  -- Pool versions
  (Just (pool :: M0.Pool)) <- lookupConfObjByFid f_mdpool_fid
  let pdca = PDClustAttr {
          _pa_N = m0_data_units
        , _pa_K = m0_parity_units
        , _pa_P = m0_pool_width
        , _pa_unit_size = 4096
        , _pa_seed = Word128 123 456
      }
      pvers = G.connectedTo pool M0.IsRealOf g :: [M0.PVer]
  forM_ pvers $ \pver -> do
    liftM0 $ addPVer t (M0.fid pver) f_mdpool_fid (M0.v_failures pver) pdca
    let rackvs = G.connectedTo pver M0.IsParentOf g :: [M0.RackV]
    forM_ rackvs $ \rackv -> do
      let (Just (rack :: M0.Rack)) = listToMaybe
                                   $ G.connectedFrom M0.IsRealOf rackv g
      liftM0 $ addRackV t (M0.fid rackv) (M0.fid pver) (M0.fid rack)
      let enclvs = G.connectedTo rackv M0.IsParentOf g :: [M0.EnclosureV]
      forM_ enclvs $ \enclv -> do
        let (Just (encl :: M0.Enclosure)) = listToMaybe
                                          $ G.connectedFrom M0.IsRealOf enclv g
        liftM0 $ addEnclosureV t (M0.fid enclv) (M0.fid rackv) (M0.fid encl)
        let ctrlvs = G.connectedTo enclv M0.IsParentOf g :: [M0.ControllerV]
        forM_ ctrlvs $ \ctrlv -> do
          let (Just (ctrl :: M0.Controller)) = listToMaybe
                                             $ G.connectedFrom M0.IsRealOf ctrlv g
          liftM0 $ addControllerV t (M0.fid ctrlv) (M0.fid enclv) (M0.fid ctrl)
          let diskvs = G.connectedTo ctrlv M0.IsParentOf g :: [M0.DiskV]
          forM_ diskvs $ \diskv -> do
            let (Just (disk :: M0.Disk)) = listToMaybe
                                         $ G.connectedFrom M0.IsRealOf diskv g

            liftM0 $ addDiskV t (M0.fid diskv) (M0.fid ctrlv) (M0.fid disk)
    liftM0 $ poolVersionDone t (M0.fid pver)
    phaseLog "spiel" "Finished adding virtual entities."
  return t

-- | Creates an RPCAddress suitable for 'withServerEndpoint'
-- and friends. 'getSelfNode' is used and endpoint of
-- @tcp:12345:34:100@ is assumed.
getRPCAddress :: DP.Process RPCAddress
getRPCAddress = rpcAddress . mkAddress <$> DP.getSelfNode
  where
    mkAddress = (++ "@tcp:12345:34:100") . takeWhile (/= ':')
                . drop (length ("nid://" :: String)) . show

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

getSpielAddress :: PhaseM LoopState l (Maybe M0.SpielAddress)
getSpielAddress = do
  phaseLog "rg-query" "Looking up confd and RM services for spiel address."
  svs <- getM0Services
  let confds = nub $ concat
        [ eps | (M0.Service { s_type = CST_MGS, s_endpoints = eps }) <- svs ]
      mrm = listToMaybe . nub $ concat
        [ eps | (M0.Service { s_type = CST_MDS, s_endpoints = eps }) <- svs ]
  return $ fmap (\rm -> M0.SpielAddress confds rm) mrm

-- | List of addresses to known confd servers on the cluster.
getConfdServers :: PhaseM LoopState l [String]
getConfdServers = getSpielAddress >>= return . maybe [] M0.sa_confds

-- | Find a confd server in the cluster and run the given function on
-- the configuration tree. Returns no result if no confd servers are
-- found in the cluster.
--
-- It does nothing if 'lsRPCAddress' has not been set.
withRootRC :: (Root -> IO a) -> PhaseM LoopState l (Maybe a)
withRootRC f = do
 rpca <- liftProcess getRPCAddress
 getConfdServers >>= \case
  [] -> return Nothing
  confdServer:_ -> withServerEndpoint rpca $ \se ->
    liftM0 $ do
      rpcm <- getRPCMachine_se se
      return <$> withConf rpcm (rpcAddress confdServer) f

-- | Try to connect to spiel and run the 'PhaseM' on the
-- 'SpielContext'.
--
-- The user is responsible for making sure that inner 'IO' actions run
-- on the global m0 worker if needed.
withSpielRC :: M0.SpielAddress
            -> (SpielContext -> PhaseM LoopState l a)
            -> PhaseM LoopState l (Maybe a)
withSpielRC (M0.SpielAddress confds rm) f = do
  rpca <- liftProcess getRPCAddress
  withServerEndpoint rpca $ \se -> do
    sc <- liftM0 $ getRPCMachine_se se >>= \rpcm ->
                   Mero.Spiel.start rpcm confds rm
    f sc >>= \v -> liftM0 (Mero.Spiel.stop sc) >> return (Just v)

-- | Helper functions for backward compatibility.
syncToConfd :: M0.SpielAddress -> PhaseM LoopState l (Maybe ())
syncToConfd sa = withSpielRC sa $ \sc -> do
  loadConfData >>= traverse_ (\x -> txOpenContext sc >>= txPopulate x >>= txSyncToConfd)

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

-- | Replace storage device node with its new version.
actualizeStorageDeviceReplacement :: StorageDevice -> PhaseM LoopState l ()
actualizeStorageDeviceReplacement sdev = do
    phaseLog "rg" "Set disk candidate as an active disk"
    idents <- filter (\i -> case i of DIWWN{} -> True ; _ -> False)
                <$> findStorageDeviceIdentifiers sdev
    modifyLocalGraph $ \rg -> do
      let mr = do DIWWN wwn <- listToMaybe idents
                  (dev  :: StorageDevice) <- listToMaybe $ G.connectedFrom ReplacedBy sdev rg
                  (disk :: M0.Disk) <- listToMaybe $ G.connectedFrom M0.At dev rg
                  (mdev :: M0.SDev) <- listToMaybe $ G.connectedFrom M0.IsOnHardware disk rg
                  let (mwr  :: Maybe DeviceIdentifier) = listToMaybe $ G.connectedTo sdev WantsReplacement rg
                  return (dev, mwr, mdev, wwn)
          mkPathByWWN :: String -> String
          mkPathByWWN wwn = "/dev/disk/by-uuid/" ++ wwn
      case mr of
        Nothing -> do
          phaseLog "rg" "failed to find disk that was attached"
          return rg
        Just (dev, mwr, mdev, wwn) -> do
          let mdev' = mdev{M0.d_path=mkPathByWWN wwn}
              rwm = case mwr of
                Nothing -> id
                Just wr -> G.disconnect dev WantsReplacement wr
              rg' = G.mergeResources (const mdev') [mdev]
                >>> G.disconnect dev ReplacedBy sdev
                >>> G.disconnect dev Has SDRemovedAt
                >>> rwm
                  $ rg
          return rg'

startRepairOperation :: M0.Pool -> PhaseM LoopState l ()
startRepairOperation pool = catch
    (getSpielAddress >>= traverse_ go)
    (\e -> do
      phaseLog "error" $ "Error starting repair operation: "
                      ++ show (e :: SomeException)
                      ++ " on pool "
                      ++ show (M0.fid pool)
    )
  where
    go sa = do
      phaseLog "spiel" $ "Starting repair on pool " ++ show pool
      withSpielRC sa $ \sc -> liftM0 $ poolRepairStart sc (M0.fid pool)

startRebalanceOperation :: M0.Pool -> PhaseM LoopState l ()
startRebalanceOperation pool = catch
    (getSpielAddress >>= traverse_ go)
    (\e -> do
      phaseLog "error" $ "Error starting rebalance operation: "
                      ++ show (e :: SomeException)
                      ++ " on pool "
                      ++ show (M0.fid pool)
    )
  where
    go sa = do
      phaseLog "spiel" $ "Starting rebalance on pool " ++ show pool
      withSpielRC sa $ \sc -> liftM0 $ poolRebalanceStart sc (M0.fid pool)
