-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE LambdaCase                 #-}

module HA.RecoveryCoordinator.Actions.Mero
  ( Failures(..)
  , FailureSet(..)
  , getFilesystem
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
  , generateFailureSets
  , createPoolVersions
  , loadMeroGlobals
  , loadMeroServers
  , syncAction
  , confInitialised
  , initialiseConfInRG
  )
where

import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Hardware
import qualified HA.ResourceGraph as G
import HA.Resources (Cluster(..), Has(..))
import HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import HA.Resources.Mero (SyncToConfd(..), SpielAddress(..))
import qualified HA.Resources.Mero as M0

import Mero.ConfC
  ( Fid
  , PDClustAttr(..)
  , Word128(..)
  , Root
  , ServiceType(..)
  , bitmapFromArray
  , withConf
  )
import Mero.M0Worker (liftM0)
import Mero.Notification
import Mero.Spiel hiding (start)
import qualified Mero.Spiel

import Control.Applicative
import Control.Category (id, (>>>))
import Control.Distributed.Process (liftIO)
import qualified Control.Distributed.Process as DP
import Control.Exception (SomeException)
import Control.Monad (forM_, void)
import Control.Monad.Catch (catch)

import Data.Foldable (foldl', traverse_)
import qualified Data.HashMap.Strict as M
import Data.List (nub, sort, (\\))
import Data.Maybe (catMaybes, listToMaybe)
import Data.Proxy
import qualified Data.Set as S
import Data.UUID (UUID)
import Data.UUID.V4 (nextRandom)
import Data.Word ( Word32, Word64 )

import Network.CEP
import Network.RPC.RPCLite (getRPCMachine_se, rpcAddress, RPCAddress(..))

import Prelude hiding (id)

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

syncAction :: Maybe UUID -> SyncToConfd -> PhaseM LoopState l ()
syncAction meid sync = do
  case sync of
    SyncToConfdServersInRG -> do
      phaseLog "info" "Syncing RG to confd servers in RG."
      msa <- getSpielAddress
      case msa of
        Nothing -> phaseLog "warning" $ "No spiel address found in RG."
        Just sa -> void $ withSpielRC sa $ \sc -> do
          loadConfData >>= traverse_ (\x -> txOpenContext sc >>= txPopulate x >>= txSyncToConfd)
    SyncToTheseServers (SpielAddress [] _) ->
      phaseLog "warning"
         $ "Requested to sync to specific list of confd servers, "
        ++ "but that list was empty."
    SyncToTheseServers sa -> do
      phaseLog "info" $ "Syncing RG to these confd servers: " ++ show sa
      void $ withSpielRC sa $ \sc -> do
        loadConfData >>= traverse_ (\x -> txOpenContext sc >>= txPopulate x >>= txSyncToConfd)
    SyncDumpToFile filename -> do
      phaseLog "info" $ "Dumping conf in RG to this file: " ++ show filename
      loadConfData >>= traverse_ (\x -> txOpen >>= txPopulate x >>= txDumpToFile filename)
  traverse_ messageProcessed meid

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
      cores = bitmapFromArray
        . fmap (\i -> if i > 0 then True else False)
        $ m0h_cores
      mkProc fid = M0.Process fid m0h_mem_as m0h_mem_rss
                              m0h_mem_stack m0h_mem_memlock
                              cores m0h_endpoint

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

-- ^ Allowed failures in each failure domain
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
                  -- failrue domain.
  deriving (Eq, Ord, Show)

failureSetToArray :: Failures -> [Word32]
failureSetToArray f = [f_pool f, f_rack f, f_encl f, f_ctrl f, f_disk f]

mapFS :: (S.Set Fid -> S.Set Fid) -> FailureSet -> FailureSet
mapFS f (FailureSet a b) = FailureSet (f a) b

-- | Create pool versions based upon failure sets.
createPoolVersions :: M0.Filesystem
                   -> [FailureSet]
                   -> PhaseM LoopState l ()
createPoolVersions fs = mapM_ createPoolVersion
  where
    pool = M0.Pool (M0.f_mdpool_fid fs)
    createPoolVersion :: FailureSet -> PhaseM LoopState l ()
    createPoolVersion (FailureSet failset failures) = do
      pver <- M0.PVer <$> newFid (Proxy :: Proxy M0.PVer)
                      <*> return (failureSetToArray failures)
      modifyGraph
          $ G.newResource pver
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
          let disk = listToMaybe
                   $ (G.connectedTo sdev M0.IsOnHardware g :: [M0.Disk])
          liftM0 $ addDevice t d_fid s_fid (fmap M0.fid disk) M0_CFG_DEVICE_INTERFACE_SATA
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
