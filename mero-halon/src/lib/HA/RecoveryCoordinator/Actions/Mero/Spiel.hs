-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE LambdaCase                 #-}

module HA.RecoveryCoordinator.Actions.Mero.Spiel
  ( getSpielAddress
  , withRootRC
  , withSpielRC
  , withRConfRC
  , startRepairOperation
  , startRebalanceOperation
  , syncAction
  , syncToConfd
  ) where

import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Mero.Conf
import HA.RecoveryCoordinator.Actions.Mero.Core
import qualified HA.ResourceGraph as G
import HA.Resources (Has(..))
import HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import HA.Resources.Mero (SyncToConfd(..))
import qualified HA.Resources.Mero as M0

import Mero.ConfC
  ( PDClustAttr(..)
  , Word128(..)
  , Root
  , ServiceType(..)
  , withConf
  )
import Mero.M0Worker (liftM0)
import Mero.Notification
import Mero.Spiel hiding (start)
import qualified Mero.Spiel

import Control.Applicative
import qualified Control.Distributed.Process as DP
import Control.Exception (SomeException)
import Control.Monad (forM_, void)
import Control.Monad.Catch (catch, throwM)

import Data.Foldable (traverse_)
import Data.List (nub)
import Data.Maybe (catMaybes, listToMaybe)
import Data.UUID (UUID)

import Network.CEP
import Network.RPC.RPCLite (getRPCMachine_se, rpcAddress, RPCAddress(..))

import Prelude hiding (id)

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
withSpielRC :: (SpielContext -> PhaseM LoopState l a)
            -> PhaseM LoopState l (Maybe a)
withSpielRC f = do
  rpca <- liftProcess getRPCAddress
  withServerEndpoint rpca $ \se -> do
    sc <- liftM0 $ getRPCMachine_se se >>= \rpcm -> Mero.Spiel.start rpcm
    f sc >>= \v -> liftM0 (Mero.Spiel.stop sc) >> return (Just v)

-- | Try to start rconf sesion and run 'PhaseM' on the 'SpielContext' this
-- call is required for running management commands.
--
-- The user is responsible for making sure that inner 'IO' actions run
-- on the global m0 worker if needed.
withRConfRC :: SpielContext -> PhaseM LoopState l a -> PhaseM LoopState l a
withRConfRC spiel action = do
  rg <- getLocalGraph
  let mp = listToMaybe $ G.getResourcesOfType rg :: Maybe M0.Profile
  liftProcess $ liftM0 $ do 
     Mero.Spiel.rconfStart spiel
     Mero.Spiel.setCmdProfile spiel (fmap (\(M0.Profile p) -> show p) mp)
  x <- action `catch` (\e -> liftProcess $ do
         liftM0 $ Mero.Spiel.rconfStop spiel
         throwM (e::SomeException))
  liftProcess (liftM0 $ Mero.Spiel.rconfStop spiel)
  return x

startRepairOperation :: M0.Pool -> PhaseM LoopState l ()
startRepairOperation pool = catch
    (getSpielAddress >>= traverse_ (const go))
    (\e -> do
      phaseLog "error" $ "Error starting repair operation: "
                      ++ show (e :: SomeException)
                      ++ " on pool "
                      ++ show (M0.fid pool)
    )
  where
    go = do
      phaseLog "spiel" $ "Starting repair on pool " ++ show pool
      withSpielRC $ \sc -> withRConfRC sc $ liftM0 $ poolRepairStart sc (M0.fid pool)

startRebalanceOperation :: M0.Pool -> PhaseM LoopState l ()
startRebalanceOperation pool = catch
    (getSpielAddress >>= traverse_ (const go))
    (\e -> do
      phaseLog "error" $ "Error starting rebalance operation: "
                      ++ show (e :: SomeException)
                      ++ " on pool "
                      ++ show (M0.fid pool)
    )
  where
    go = do
      phaseLog "spiel" $ "Starting rebalance on pool " ++ show pool
      withSpielRC $ \sc -> withRConfRC sc $ liftM0 $ poolRebalanceStart sc (M0.fid pool)

syncAction :: Maybe UUID -> SyncToConfd -> PhaseM LoopState l ()
syncAction meid sync = do
  case sync of
    SyncToConfdServersInRG -> do
      phaseLog "info" "Syncing RG to confd servers in RG."
      msa <- getSpielAddress
      case msa of
        Nothing -> phaseLog "warning" $ "No spiel address found in RG."
        Just{}  -> void $ withSpielRC $ \sc -> do
          loadConfData >>= traverse_ (\x -> txOpenContext sc >>= txPopulate x >>= txSyncToConfd)
    SyncDumpToFile filename -> do
      phaseLog "info" $ "Dumping conf in RG to this file: " ++ show filename
      loadConfData >>= traverse_ (\x -> txOpenLocalContext >>= txPopulate x >>= txDumpToFile filename)
  traverse_ messageProcessed meid

-- | Helper functions for backward compatibility.
syncToConfd :: M0.SpielAddress -> PhaseM LoopState l (Maybe ())
syncToConfd _ = withSpielRC $ \sc -> do
  loadConfData >>= traverse_ (\x -> txOpenContext sc >>= txPopulate x >>= txSyncToConfd)

-- | Open a transaction. Ultimately this should not need a
--   spiel context.
txOpenContext :: SpielContext -> PhaseM LoopState l SpielTransaction
txOpenContext = liftM0 . openTransaction

txOpenLocalContext :: PhaseM LoopState l SpielTransaction
txOpenLocalContext = liftM0 openLocalTransaction

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
