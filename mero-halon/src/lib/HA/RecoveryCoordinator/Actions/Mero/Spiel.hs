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
  ( haAddress
  , getSpielAddressRC
  , withRootRC
  , withSpielRC
  , withRConfRC
  , abortRebalanceOperation
  , abortRepairOperation
  , continueRebalanceOperation
  , continueRepairOperation
  , quiesceRebalanceOperation
  , quiesceRepairOperation
  , startRepairOperation
  , statusOfRepairOperation
  , startRebalanceOperation
  , statusOfRebalanceOperation
  , syncAction
  , syncToBS
  , syncToConfd
  , validateTransactionCache
    -- * Pool repair information
  , getPoolRepairInformation
  , getPoolRepairStatus
  , getTimeUntilQueryHourlyPRI
  , incrementOnlinePRSResponse
  , modifyPoolRepairInformation
  , possiblyInitialisePRI
  , setPoolRepairInformation
  , setPoolRepairStatus
  , unsetPoolRepairStatus
  , unsetPoolRepairStatusWithUUID
  , updatePoolRepairStatusTime
  ) where

import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Mero.Conf
import HA.RecoveryCoordinator.Actions.Mero.Core
import qualified HA.ResourceGraph as G
import HA.Resources (Has(..), Cluster(..))
import HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import HA.Resources.Mero (SyncToConfd(..))
import qualified HA.Resources.Mero as M0
import HA.Resources.Mero.Note (ConfObjectState(..))
import HA.Services.Mero (notifyMero, notifyMeroBlocking)

import Mero.ConfC
  ( PDClustAttr(..)
  , Root
  , withConf
  , initHASession
  , finiHASession
  )
import Mero.Notification hiding (notifyMero)
import Mero.Spiel hiding (start)
import qualified Mero.Spiel

import Control.Applicative
import Control.Category ((>>>))
import qualified Control.Distributed.Process as DP
import Control.Monad (forM_, void, join)
import Control.Monad.Catch

import qualified Data.ByteString as BS
import Data.Foldable (traverse_)
import Data.IORef (writeIORef)
import Data.List (sortOn)
import Data.Maybe (catMaybes, listToMaybe)
import Data.Proxy (Proxy(..))
import Data.UUID (UUID)
import Data.UUID.V4 (nextRandom)

import Network.CEP
import Network.HostName (getHostName)
import Network.RPC.RPCLite (getRPCMachine_se, rpcAddress, RPCAddress(..))

import System.IO
import System.Directory

import Text.Printf (printf)

import Prelude hiding (id)

haAddress :: String
haAddress = ":12345:34:101"

-- | Find a confd server in the cluster and run the given function on
-- the configuration tree. Returns no result if no confd servers are
-- found in the cluster.
--
-- It does nothing if 'lsRPCAddress' has not been set.
withRootRC :: (Root -> IO a) -> PhaseM LoopState l (Maybe a)
withRootRC f = do
 rpca <- getRPCAddress
 getConfdServers >>= \case
  [] -> return Nothing
  confdServer:_ -> withServerEndpoint rpca $ \se ->
    liftM0RC $ do
      rpcm <- getRPCMachine_se se
      return <$> withConf rpcm (rpcAddress confdServer) f

-- | Try to connect to spiel and run the 'PhaseM' on the
-- 'SpielContext'.
--
-- The user is responsible for making sure that inner 'IO' actions run
-- on the global m0 worker if needed.
withSpielRC :: (SpielContext -> PhaseM LoopState l a)
            -> PhaseM LoopState l (Either SomeException a)
withSpielRC f = withResourceGraphCache $ do
  rpca <- getRPCAddress
  try $ withServerEndpoint rpca $ \se -> do
     conn <- liftM0RC $ initHASession se rpca
     sc <- liftM0RC $ getRPCMachine_se se >>= \rpcm -> Mero.Spiel.start rpcm
     f sc `sfinally`  liftM0RC (Mero.Spiel.stop sc >> finiHASession conn)

-- | Try to start rconf sesion and run 'PhaseM' on the 'SpielContext' this
-- call is required for running management commands.
--
-- The user is responsible for making sure that inner 'IO' actions run
-- on the global m0 worker if needed.
withRConfRC :: SpielContext -> PhaseM LoopState l a -> PhaseM LoopState l a
withRConfRC spiel action = do
  rg <- getLocalGraph
  let mp = listToMaybe $ G.getResourcesOfType rg :: Maybe M0.Profile
  liftM0RC $ do
     Mero.Spiel.setCmdProfile spiel (fmap (\(M0.Profile p) -> show p) mp)
     Mero.Spiel.rconfStart spiel
  x <- action `sfinally` liftM0RC (Mero.Spiel.rconfStop spiel)
  return x

-- | Start the repair operation on the given 'M0.Pool'. Notifies mero
-- with the 'M0_NC_REPAIR' status.
startRepairOperation :: M0.Pool
                     -> PhaseM LoopState l ()
startRepairOperation pool = go `catch`
    (\e -> do
      phaseLog "error" $ "Error starting repair operation: "
                      ++ show (e :: SomeException)
                      ++ " on pool "
                      ++ show (M0.fid pool)
    )
  where
    go = do
      phaseLog "spiel" $ "Starting repair on pool " ++ show pool
      m0sdevs <- getPoolSDevsWithState pool M0_NC_FAILED
      disks <- fmap M0.AnyConfObj . catMaybes <$> mapM lookupSDevDisk m0sdevs
      res <- notifyMeroBlocking (M0.AnyConfObj pool : disks) M0_NC_REPAIR
      case res of
        True -> do
          _ <- withSpielRC $ \sc -> withRConfRC sc $ liftM0RC $ poolRepairStart sc (M0.fid pool)
          uuid <- DP.liftIO nextRandom
          setPoolRepairStatus pool $ M0.PoolRepairStatus M0.Failure uuid Nothing
          phaseLog "spiel" $ "startRepairOperation for " ++ show pool ++ " done."
        False -> do
          phaseLog "error" $ "Unable to notify Mero; cannot start repair"

-- | Retrieves the repair 'SnsStatus' of the given 'M0.Pool'.
statusOfRepairOperation :: M0.Pool
                        -> PhaseM LoopState l (Either SomeException [SnsStatus])
statusOfRepairOperation pool = catch go
  (\e -> do
    phaseLog "error" $ "Error in pool status repair operation: "
                    ++ show e
                    ++ " on pool "
                    ++ show (M0.fid pool)
    return $ Left e
  )
  where
    go :: PhaseM LoopState l (Either SomeException [SnsStatus])
    go = do
      phaseLog "spiel" $ "Starting status on pool " ++ show pool
      withSpielRC $ \sc -> withRConfRC sc $ liftM0RC $ poolRepairStatus sc (M0.fid pool)

-- | Continue the rebalance operation.
continueRepairOperation :: M0.Pool -> PhaseM LoopState l (Maybe SomeException)
continueRepairOperation pool = catch go
  (\e -> do
    phaseLog "error" $ "Error in continue repair operation: "
                    ++ show e
                    ++ " on pool "
                    ++ show (M0.fid pool)
    return $ Just e
  )
  where
    go = do
      phaseLog "spiel" $ "Continuing repair on " ++ show pool
      _ <- withSpielRC $ \sc -> withRConfRC sc $ liftM0RC $ poolRepairContinue sc (M0.fid pool)
      return Nothing

-- | Quiesces the repair operation on the given pool
quiesceRepairOperation :: M0.Pool -> PhaseM LoopState l (Maybe SomeException)
quiesceRepairOperation pool = catch go
  (\e -> do
    phaseLog "error" $ "Error in repair quiesce operation: "
                    ++ show e
                    ++ " on pool "
                    ++ show (M0.fid pool)
    return $ Just e
  )
  where
    go :: PhaseM LoopState l (Maybe SomeException)
    go = do
      phaseLog "spiel" $ "Quiescing repair on pool " ++ show pool
      _ <- withSpielRC $ \sc -> withRConfRC sc $ liftM0RC $ poolRepairQuiesce sc (M0.fid pool)
      return Nothing

-- | Quiesces the repair operation on the given pool
abortRepairOperation :: M0.Pool -> PhaseM LoopState l (Maybe SomeException)
abortRepairOperation pool = catch go
  (\e -> do
    phaseLog "error" $ "Error in repair abort operation: "
                    ++ show e
                    ++ " on pool "
                    ++ show (M0.fid pool)
    return $ Just e
  )
  where
    go :: PhaseM LoopState l (Maybe SomeException)
    go = do
      phaseLog "spiel" $ "Aborting repair on pool " ++ show pool
      _ <- withSpielRC $ \sc -> withRConfRC sc $ liftM0RC $ poolRepairAbort sc (M0.fid pool)
      return Nothing

-- | Starts a rebalance operation on the given 'M0.Pool'. Notifies
-- mero with the 'M0_NC_FAILED' status.
startRebalanceOperation :: M0.Pool -> PhaseM LoopState l ()
startRebalanceOperation pool = catch go
    (\e -> do
      phaseLog "error" $ "Error starting rebalance operation: "
                      ++ show (e :: SomeException)
                      ++ " on pool "
                      ++ show (M0.fid pool)
    )
  where
    go = do
      phaseLog "spiel" $ "Starting rebalance on pool " ++ show pool
      m0sdevs <- getPoolSDevsWithState pool M0_NC_REPAIRED
      disks <- fmap M0.AnyConfObj . catMaybes <$> mapM lookupSDevDisk m0sdevs
      notifyMero (M0.AnyConfObj pool : disks) M0_NC_REBALANCE
      _ <- withSpielRC $ \sc -> withRConfRC sc $ liftM0RC $ poolRebalanceStart sc (M0.fid pool)
      uuid <- DP.liftIO nextRandom
      setPoolRepairStatus pool $ M0.PoolRepairStatus M0.Rebalance uuid Nothing

-- | Retrieves the rebalance 'SnsStatus' of the given pool.
statusOfRebalanceOperation :: M0.Pool
                           -> PhaseM LoopState l (Either SomeException [SnsStatus])
statusOfRebalanceOperation pool = catch go
  (\e -> do
    phaseLog "error" $ "Error in pool status rebalance operation: "
                    ++ show e
                    ++ " on pool "
                    ++ show (M0.fid pool)
    return $ Left e
  )
  where
    go :: PhaseM LoopState l (Either SomeException [SnsStatus])
    go = do
      phaseLog "spiel" $ "Starting status on pool " ++ show pool
      withSpielRC $ \sc -> withRConfRC sc $ liftM0RC $ poolRebalanceStatus sc (M0.fid pool)

-- | Continue the rebalance operation.
continueRebalanceOperation :: M0.Pool -> PhaseM LoopState l (Maybe SomeException)
continueRebalanceOperation pool = catch go
  (\e -> do
    phaseLog "error" $ "Error in continue rebalance operation: "
                    ++ show e
                    ++ " on pool "
                    ++ show (M0.fid pool)
    return $ Just e
  )
  where
    go = do
      phaseLog "spiel" $ "Continuing rebalance on " ++ show pool
      _ <- withSpielRC $ \sc -> withRConfRC sc $ liftM0RC $ poolRebalanceContinue sc (M0.fid pool)
      return Nothing

-- | Quiesces the rebalance operation on the given pool
quiesceRebalanceOperation :: M0.Pool -> PhaseM LoopState l (Maybe SomeException)
quiesceRebalanceOperation pool = catch go
  (\e -> do
    phaseLog "error" $ "Error in rebalance quiesce operation: "
                    ++ show e
                    ++ " on pool "
                    ++ show (M0.fid pool)
    return $ Just e
  )
  where
    go :: PhaseM LoopState l (Maybe SomeException)
    go = do
      phaseLog "spiel" $ "Starting status on pool " ++ show pool
      _ <- withSpielRC $ \sc -> withRConfRC sc $ liftM0RC $ poolRebalanceQuiesce sc (M0.fid pool)
      return Nothing

-- | Quiesces the rebalance operation on the given pool
abortRebalanceOperation :: M0.Pool -> PhaseM LoopState l (Maybe SomeException)
abortRebalanceOperation pool = catch go
  (\e -> do
    phaseLog "error" $ "Error in rebalance abort operation: "
                    ++ show e
                    ++ " on pool "
                    ++ show (M0.fid pool)
    return $ Just e
  )
  where
    go :: PhaseM LoopState l (Maybe SomeException)
    go = do
      phaseLog "spiel" $ "Aborting rebalance on pool " ++ show pool
      _ <- withSpielRC $ \sc -> withRConfRC sc $ liftM0RC $ poolRebalanceAbort sc (M0.fid pool)
      return Nothing

-- | Synchronize graph to confd.
-- Currently all Exceptions during this operation are caught, this is required in because
-- there is no good exception handling in RC and uncaught exception will lead to RC failure.
-- Also it's behaviour of RC in case of mero exceptions is not specified.
syncAction :: Maybe UUID -> SyncToConfd -> PhaseM LoopState l ()
syncAction meid sync =
   flip catch (\e -> phaseLog "error" $ "Exception during sync: "++show (e::SomeException))
       $ do
    case sync of
      SyncToConfdServersInRG -> flip catch (handler (const $ return ())) $ do
        phaseLog "info" "Syncing RG to confd servers in RG."
        void $ syncToConfd
      SyncDumpToBS pid -> flip catch (handler $ failToBS pid) $ do
        bs <- syncToBS
        liftProcess . DP.usend pid . M0.SyncDumpToBSReply $ Right bs
    traverse_ messageProcessed meid
  where
    failToBS :: DP.ProcessId -> SomeException -> DP.Process ()
    failToBS pid = DP.usend pid . M0.SyncDumpToBSReply . Left . show

    handler :: (SomeException -> DP.Process ())
            -> SomeException
            -> PhaseM LoopState l ()
    handler act e = do
      phaseLog "error" $ "Exception during sync: " ++ show e
      liftProcess $ act e

-- | Dump the conf into a file, read it back and return the conf in
-- form of a 'BS.ByteString'. Users which want this config but aren't
-- the RC should use 'syncAction' with 'M0.SyncDumpToBS' instead which
-- will catch exceptions and forward the result to the given
-- 'DP.ProcessId'.
syncToBS :: PhaseM LoopState l BS.ByteString
syncToBS = do
  fp <- DP.liftIO $ do
    tmpdir <- getTemporaryDirectory
    (fp, h) <- openTempFile tmpdir "conf.xc"
    hClose h >> return fp
  phaseLog "info" $ "Dumping conf in RG to: " ++ show fp
  loadConfData >>= traverse_ (\x -> txOpenLocalContext >>= txPopulate x
                                    >>= txDumpToFile fp)
  bs <- DP.liftIO $ BS.readFile fp
  DP.liftIO $ removeFile fp
  return bs

-- | Helper functions for backward compatibility.
syncToConfd :: PhaseM LoopState l (Either SomeException ())
syncToConfd = do
  withSpielRC $ \sc -> do
     loadConfData >>= traverse_ (\x -> txOpenContext sc >>= txPopulate x >>= txSyncToConfd)

-- | Open a transaction. Ultimately this should not need a
--   spiel context.
txOpenContext :: SpielContext -> PhaseM LoopState l SpielTransaction
txOpenContext = liftM0RC . openTransaction

txOpenLocalContext :: PhaseM LoopState l SpielTransaction
txOpenLocalContext = liftM0RC openLocalTransaction

txSyncToConfd :: SpielTransaction -> PhaseM LoopState l ()
txSyncToConfd t = do
  phaseLog "spiel" "Committing transaction to confd"
  liftM0RC (commitTransaction t) >>= \case
    Nothing -> do
      -- spiel increases conf version here so we should too; alternative
      -- would be querying spiel after transaction for the new version
      modifyConfUpdateVersion (\(M0.ConfUpdateVersion i) -> M0.ConfUpdateVersion $ i + 1)
      phaseLog "spiel" "Transaction committed."
    Just err ->
      phaseLog "spiel" $ "Transaction commit failed with cache failure:" ++ err
  liftM0RC $ closeTransaction t
  phaseLog "spiel" "Transaction closed."

txDumpToFile :: FilePath -> SpielTransaction -> PhaseM LoopState l ()
txDumpToFile fp t = do
  M0.ConfUpdateVersion ver <- getConfUpdateVersion
  phaseLog "spiel" $ "Writing transaction to " ++ fp ++ " with ver " ++ show ver
  liftM0RC $ dumpTransaction t ver fp
  phaseLog "spiel" "Transaction written."
  liftM0RC $ closeTransaction t
  phaseLog "spiel" "Transaction closed."
  modifyConfUpdateVersion $ const (M0.ConfUpdateVersion $ ver + 1)

data TxConfData = TxConfData M0.M0Globals M0.Profile M0.Filesystem

loadConfData :: PhaseM LoopState l (Maybe TxConfData)
loadConfData = liftA3 TxConfData
            <$> getM0Globals
            <*> getProfile
            <*> getFilesystem

-- | Gets the current 'ConfUpdateVersion' used when dumping
-- 'SpielTransaction' out. If this is not set, it's set to the default of @1@.
getConfUpdateVersion :: PhaseM LoopState l M0.ConfUpdateVersion
getConfUpdateVersion = do
  phaseLog "rg-query" "Looking for ConfUpdateVersion"
  g <- getLocalGraph
  case listToMaybe $ G.connectedTo Cluster Has g of
    Just ver -> return ver
    Nothing -> do
      let csu = M0.ConfUpdateVersion 1
      modifyLocalGraph $ G.newResource csu >>> return . G.connect Cluster Has csu
      return csu

modifyConfUpdateVersion :: (M0.ConfUpdateVersion -> M0.ConfUpdateVersion)
                        -> PhaseM LoopState l ()
modifyConfUpdateVersion f = do
  csu <- getConfUpdateVersion
  let fcsu = f csu
  phaseLog "rg" $ "Setting ConfUpdateVersion to " ++ show fcsu
  modifyLocalGraph $ return . G.connectUniqueFrom Cluster Has fcsu

txPopulate :: TxConfData -> SpielTransaction -> PhaseM LoopState l SpielTransaction
txPopulate (TxConfData CI.M0Globals{..} (M0.Profile pfid) fs@M0.Filesystem{..}) t = do
  g <- getLocalGraph
  -- Profile, FS, pool
  -- Top-level pool width is number of devices in existence
  let m0_pool_width = length (G.getResourcesOfType g :: [M0.Disk])
      fsParams = printf "%d %d %d" m0_pool_width m0_data_units m0_parity_units
  liftM0RC $ do
    addProfile t pfid
    addFilesystem t f_fid pfid m0_md_redundancy pfid f_mdpool_fid [fsParams]
    addPool t f_mdpool_fid f_fid 0
  phaseLog "spiel" "Added profile, filesystem, mdpool objects."
  -- Racks, encls, controllers, disks
  let racks = G.connectedTo fs M0.IsParentOf g :: [M0.Rack]
  forM_ racks $ \rack -> do
    liftM0RC $ addRack t (M0.fid rack) f_fid
    let encls = G.connectedTo rack M0.IsParentOf g :: [M0.Enclosure]
    forM_ encls $ \encl -> do
      liftM0RC $ addEnclosure t (M0.fid encl) (M0.fid rack)
      let ctrls = G.connectedTo encl M0.IsParentOf g :: [M0.Controller]
      forM_ ctrls $ \ctrl -> do
        -- Get node fid
        let (Just node) = listToMaybe
                        $ (G.connectedFrom M0.IsOnHardware ctrl g :: [M0.Node])
        liftM0RC $ addController t (M0.fid ctrl) (M0.fid encl) (M0.fid node)
        let disks = G.connectedTo ctrl M0.IsParentOf g :: [M0.Disk]
        forM_ disks $ \disk -> do
          liftM0RC $ addDisk t (M0.fid disk) (M0.fid ctrl)
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
    liftM0RC $ addNode t (M0.fid node) f_fid memsize cpucount 0 0 f_mdpool_fid
    let procs = G.connectedTo node M0.IsParentOf g :: [M0.Process]
    forM_ procs $ \(proc@M0.Process{..}) -> do
      liftM0RC $ addProcess t r_fid (M0.fid node) r_cores
                            r_mem_as r_mem_rss r_mem_stack r_mem_memlock
                            r_endpoint
      let servs = G.connectedTo proc M0.IsParentOf g :: [M0.Service]
      forM_ servs $ \(serv@M0.Service{..}) -> do
        liftM0RC $ addService t s_fid r_fid (ServiceInfo s_type s_endpoints s_params)
        let sdevs = G.connectedTo serv M0.IsParentOf g :: [M0.SDev]
        forM_ sdevs $ \(sdev@M0.SDev{..}) -> do
          let disk = listToMaybe
                   $ (G.connectedTo sdev M0.IsOnHardware g :: [M0.Disk])
          liftM0RC $ addDevice t d_fid s_fid (fmap M0.fid disk) d_idx
                      M0_CFG_DEVICE_INTERFACE_SATA
                      M0_CFG_DEVICE_MEDIA_DISK d_bsize d_size 0 0 d_path
  phaseLog "spiel" "Finished adding concrete entities."
  -- Pool versions
  (Just (pool :: M0.Pool)) <- lookupConfObjByFid f_mdpool_fid
  let pvNegWidth = negate . _pa_P . M0.v_attrs
      pvers = sortOn pvNegWidth $ G.connectedTo pool M0.IsRealOf g :: [M0.PVer]
  forM_ pvers $ \pver -> do
    liftM0RC $ addPVer t (M0.fid pver) f_mdpool_fid (M0.v_failures pver) (M0.v_attrs pver)
    let rackvs = G.connectedTo pver M0.IsParentOf g :: [M0.RackV]
    forM_ rackvs $ \rackv -> do
      let (Just (rack :: M0.Rack)) = listToMaybe
                                   $ G.connectedFrom M0.IsRealOf rackv g
      liftM0RC $ addRackV t (M0.fid rackv) (M0.fid pver) (M0.fid rack)
      let enclvs = G.connectedTo rackv M0.IsParentOf g :: [M0.EnclosureV]
      forM_ enclvs $ \enclv -> do
        let (Just (encl :: M0.Enclosure)) = listToMaybe
                                          $ G.connectedFrom M0.IsRealOf enclv g
        liftM0RC $ addEnclosureV t (M0.fid enclv) (M0.fid rackv) (M0.fid encl)
        let ctrlvs = G.connectedTo enclv M0.IsParentOf g :: [M0.ControllerV]
        forM_ ctrlvs $ \ctrlv -> do
          let (Just (ctrl :: M0.Controller)) = listToMaybe
                                             $ G.connectedFrom M0.IsRealOf ctrlv g
          liftM0RC $ addControllerV t (M0.fid ctrlv) (M0.fid enclv) (M0.fid ctrl)
          let diskvs = G.connectedTo ctrlv M0.IsParentOf g :: [M0.DiskV]
          forM_ diskvs $ \diskv -> do
            let (Just (disk :: M0.Disk)) = listToMaybe
                                         $ G.connectedFrom M0.IsRealOf diskv g

            liftM0RC $ addDiskV t (M0.fid diskv) (M0.fid ctrlv) (M0.fid disk)
    liftM0RC $ poolVersionDone t (M0.fid pver)
  phaseLog "spiel" "Finished adding virtual entities."
  return t

-- | Load the current conf data, create a transaction that we would
-- send to spiel and ask mero if the transaction cache is valid.
validateTransactionCache :: PhaseM LoopState l (Either SomeException (Maybe String))
validateTransactionCache = withSpielRC $ \sc -> loadConfData >>= \case
  Nothing -> do
    phaseLog "spiel" "validateTransactionCache: loadConfData failed"
    return Nothing
  Just x -> do
    phaseLog "spiel" "validateTransactionCache: validating context"
    txOpenContext sc >>= txPopulate x >>= DP.liftIO . txValidateTransactionCache

-- | Creates an RPCAddress suitable for 'withServerEndpoint'
-- and friends. If the information about the current node's endpoint
-- is not found in the RG, we construct an address using the default
-- 'haAddress'.
getRPCAddress :: PhaseM LoopState l RPCAddress
getRPCAddress = do
  h <- DP.liftIO getHostName
  lookupHostHAAddress (Host h) >>= \case
    Just addr -> return $ rpcAddress addr
    Nothing -> do
      phaseLog "warn" $ "Using default HA endpoint for " ++ show h
      liftProcess $ rpcAddress . mkAddress <$> DP.getSelfNode
  where
    mkAddress = (++ haAddress) . (++ "@tcp") . takeWhile (/= ':')
                . drop (length ("nid://" :: String)) . show

-- | RC wrapper for 'getSpielAddress'.
getSpielAddressRC :: PhaseM LoopState l (Maybe M0.SpielAddress)
getSpielAddressRC = do
  phaseLog "rg-query" "Looking up confd and RM services for spiel address."
  getSpielAddress <$> getLocalGraph

-- | List of addresses to known confd servers on the cluster.
getConfdServers :: PhaseM LoopState l [String]
getConfdServers = getSpielAddressRC >>= return . maybe [] M0.sa_confds_ep

-- | Store 'ResourceGraph' in 'globalResourceGraphCache' in order to avoid dead
-- lock conditions. RC performing all queries sequentially, thus it can't reply
-- to the newly arrived queries to 'ResourceGraph'. This opens a possiblity of
-- a deadlock if some internal operation that RC is performing creates a query
-- to RC, and such deadlock happens in spiel operations.
-- For this reason we store a graph projection in a variable and methods that
-- could be blocked should first query this cached value first.
withResourceGraphCache :: PhaseM LoopState l a -> PhaseM LoopState l a
withResourceGraphCache action = do
  g <- getLocalGraph
  liftProcess $ DP.liftIO $ writeIORef globalResourceGraphCache (Just g)
  x <- action
  liftProcess $ DP.liftIO $ writeIORef globalResourceGraphCache Nothing
  return x

sfinally :: forall m a b. (MonadProcess m, MonadThrow m, MonadCatch m) => m a -> m b -> m a
sfinally action finalizer = do
   ev <- try action
   _  <- finalizer
   either (throwM :: SomeException -> m a) return ev

----------------------------------------------------------
-- Pool repair information functions                    --
----------------------------------------------------------

-- | Return the 'M0.PoolRepairStatus' structure. If one is not in
-- the graph, it means no repairs are going on
getPoolRepairStatus :: M0.Pool
                    -> PhaseM LoopState l (Maybe M0.PoolRepairStatus)
getPoolRepairStatus pool = do
  phaseLog "rg-query" "Looking up pool repair status"
  getLocalGraph >>= \g ->
   return (listToMaybe [ p | p <- G.connectedTo pool Has g ])

-- | Set the given 'M0.PoolRepairStatus' in the graph. Any
-- previously connected @PRI@s are disconnected.
setPoolRepairStatus :: M0.Pool -> M0.PoolRepairStatus -> PhaseM LoopState l ()
setPoolRepairStatus pool prs =
  modifyLocalGraph $ return . G.connectUniqueFrom pool Has prs

-- | Remove all 'M0.PoolRepairStatus' connection to the given 'M0.Pool'.
unsetPoolRepairStatus :: M0.Pool -> PhaseM LoopState l ()
unsetPoolRepairStatus pool =
  modifyLocalGraph $ return . G.disconnectAllFrom pool Has (Proxy :: Proxy M0.PoolRepairStatus)

-- | Remove 'M0.PoolRepairStatus' connection to the given 'M0.Pool' as
-- long as it has the matching 'M0.prsRepairUUID'. This is useful if
-- we want to clean up but we're not sure if the 'M0.PoolRepairStatus'
-- belongs to the clean up handler.
unsetPoolRepairStatusWithUUID :: M0.Pool -> UUID -> PhaseM LoopState l ()
unsetPoolRepairStatusWithUUID pool uuid = getPoolRepairStatus pool >>= \case
  Just prs | M0.prsRepairUUID prs == uuid -> unsetPoolRepairStatus pool
  _ -> return ()

-- | Return the 'M0.PoolRepairInformation' structure. If one is not in
-- the graph, it means no repairs are going on.
getPoolRepairInformation :: M0.Pool
                         -> PhaseM LoopState l (Maybe M0.PoolRepairInformation)
getPoolRepairInformation pool = do
  r <- getLocalGraph >>= return . join . fmap M0.prsPri . listToMaybe . G.connectedTo pool Has
  phaseLog "rg-query" $
    "Lookup up pool repair information for " ++ show pool ++ ", got " ++ show r
  return r

-- | Set the given 'M0.PoolRepairInformation' in the graph. Any
-- previously connected @PRI@s are disconnected.
--
-- Does nothing if we haven't at least set 'M0.PoolRepairType'
-- already.
setPoolRepairInformation :: M0.Pool
                         -> M0.PoolRepairInformation
                         -> PhaseM LoopState l ()
setPoolRepairInformation pool pri = getPoolRepairStatus pool >>= \case
  Nothing -> return ()
  Just (M0.PoolRepairStatus prt uuid _) ->
    let prs = M0.PoolRepairStatus prt uuid $ Just pri
    in modifyLocalGraph $ return . G.connectUniqueFrom pool Has prs

-- | Initialise 'M0.PoolRepairInformation' with some default values.
possiblyInitialisePRI :: M0.Pool
                      -> PhaseM LoopState l ()
possiblyInitialisePRI pool = getPoolRepairInformation pool >>= \case
  Nothing -> setPoolRepairInformation pool M0.defaultPoolRepairInformation
  Just _ -> return ()

-- | Modify the  'PoolRepairInformation' in the graph with the given function.
-- Any previously connected @PRI@s are disconnected.
modifyPoolRepairInformation :: M0.Pool
                            -> (M0.PoolRepairInformation -> M0.PoolRepairInformation)
                            -> PhaseM LoopState l ()
modifyPoolRepairInformation pool f = modifyLocalGraph $ \g ->
  case listToMaybe . G.connectedTo pool Has $ g of
    Just (M0.PoolRepairStatus prt uuid (Just pri)) ->
      return $ G.connectUniqueFrom pool Has (M0.PoolRepairStatus prt uuid (Just $ f pri)) g
    _ -> return g


-- | Increment 'priOnlineNotifications' field of the
-- 'PoolRepairInformation' in the graph. Also updates the
-- 'priTimeOfFirstCompletion' if it has not yet been set.
incrementOnlinePRSResponse :: M0.Pool
                           -> PhaseM LoopState l ()
incrementOnlinePRSResponse pool =
  DP.liftIO M0.getTime >>= \tnow -> modifyPoolRepairInformation pool (go tnow)
  where
    go tnow pr = pr { M0.priOnlineNotifications = succ $ M0.priOnlineNotifications pr
                    , M0.priTimeOfFirstCompletion =
                      if M0.priOnlineNotifications pr > 0
                      then M0.priTimeOfFirstCompletion pr
                      else tnow
                    , M0.priTimeLastHourlyRan =
                      if M0.priTimeLastHourlyRan pr > 0
                      then M0.priTimeOfFirstCompletion pr
                      else tnow
                    }

-- | Updates 'priTimeLastHourlyRan' to current time.
updatePoolRepairStatusTime :: M0.Pool -> PhaseM LoopState l ()
updatePoolRepairStatusTime pool = getPoolRepairStatus pool >>= \case
  Just (M0.PoolRepairStatus _ _ (Just pr)) -> do
    t <- DP.liftIO M0.getTime
    setPoolRepairInformation pool $ pr { M0.priTimeLastHourlyRan = t }
  _ -> return ()

-- | Returns number of seconds until we have to run the hourly PRI
-- query.
getTimeUntilQueryHourlyPRI :: M0.Pool -> PhaseM LoopState l Int
getTimeUntilQueryHourlyPRI pool = getPoolRepairInformation pool >>= \case
  Nothing -> return 0
  Just pri -> do
    tn <- DP.liftIO M0.getTime
    let elapsed = tn - M0.priTimeLastHourlyRan pri
        untilHourPasses = fromIntegral (3600 :: Integer) - elapsed
    return $ M0.timeSpecToSeconds untilHourPasses
