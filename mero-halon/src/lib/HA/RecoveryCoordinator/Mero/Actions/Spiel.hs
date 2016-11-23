-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE MagicHash                  #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE LambdaCase                 #-}

module HA.RecoveryCoordinator.Mero.Actions.Spiel
  ( haAddress
  , getSpielAddressRC
  , LiftRC
  , withSpielRC
  , withSpielIO
  , withRConfIO
    -- * SNS operations
  , mkRepairStartOperation
  , mkRepairContinueOperation
  , mkRepairQuiesceOperation
  , mkRepairStatusRequestOperation
  , mkRepairAbortOperation
  , mkRebalanceStartOperation
  , mkRebalanceContinueOperation
  , mkRebalanceQuiesceOperation
  , mkRebalanceAbortOperation
  , mkRebalanceStatusRequestOperation
    -- * Sync operation
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

import HA.RecoveryCoordinator.RC.Actions
import HA.RecoveryCoordinator.Mero.Actions.Conf
import HA.RecoveryCoordinator.Mero.Actions.Core
import HA.RecoveryCoordinator.Actions.Hardware
import qualified HA.ResourceGraph as G
import HA.Resources (Has(..), Cluster(..))
import HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import HA.Resources.Mero (SyncToConfd(..))
import qualified HA.Resources.Mero as M0

import Mero.ConfC
  ( PDClustAttr(..)
  , confPVerLvlDisks
  )
import Mero.Notification hiding (notifyMero)
import Mero.Spiel
import Mero.ConfC (Fid)
import Mero.M0Worker

import Control.Applicative
import Control.Category ((>>>))
import qualified Control.Distributed.Process as DP
import Control.Monad (void, join)
import Control.Monad.Catch

import Data.Binary
import qualified Data.ByteString as BS
import Data.Foldable (traverse_, for_)
import Data.Typeable
import Data.Hashable (hash)
import Data.IORef (writeIORef)
import Data.List (sortOn)
import Data.Maybe (catMaybes, listToMaybe)
import Data.UUID (UUID)
import Data.UUID.V4 (nextRandom)
import Data.Bifunctor

import Network.CEP

import System.IO

import Text.Printf (printf)
import GHC.Generics
import GHC.TypeLits
import GHC.Exts

import Prelude hiding (id)

haAddress :: String
haAddress = ":12345:34:101"

-- | Try to connect to spiel and run the 'PhaseM' on the
-- 'SpielContext'.
--
-- The user is responsible for making sure that inner 'IO' actions run
-- on the global m0 worker if needed.
withSpielRC :: (LiftRC -> PhaseM RC l a)
            -> PhaseM RC l (Either SomeException a)
withSpielRC f = withResourceGraphCache $ try $ withM0RC f

-- | Try to connect to spiel and run the 'IO' action in the 'SpielContext'.
--
-- All internal actions are run on m0 thread.
withSpielIO :: IO ()
            -> PhaseM RC l (Either SomeException ())
withSpielIO = withResourceGraphCache . try . withM0RC . flip m0asynchronously_

-- | Try to start rconf sesion and run 'IO' action in the 'SpielContext'.
-- This call is required for running spiel management commands.
--
-- Internal action will be running in mero thread allocated to RC service.
withRConfIO :: Maybe M0.Profile -> IO a -> IO a
withRConfIO mp action = do
  Mero.Spiel.setCmdProfile (fmap (\(M0.Profile p) -> show p) mp)
  Mero.Spiel.rconfStart
  action `finally` Mero.Spiel.rconfStop

-------------------------------------------------------------------------------
-- Generic operations helpers.
-------------------------------------------------------------------------------

data GenericSNSOperationResult (k::Symbol) a = GenericSNSOperationResult M0.Pool (Either String a)
  deriving (Generic, Typeable)
instance Binary a => Binary (GenericSNSOperationResult k a)

-- | Helper for implementation call to generic spiel operation. This
-- call is done asynchronously.
mkGenericSNSOperation :: (Typeable a, Binary a, KnownSymbol k, Typeable k)
  => Proxy# k -- ^ Operation name
  -> (M0.Pool -> Either SomeException a -> GenericSNSOperationResult k a)
  -- ^ Handler
  -> (M0.Pool -> IO a)
  -- ^ SNS action
  -> M0.Pool
  -- ^ Pool of interest
  -> PhaseM RC l ()
mkGenericSNSOperation operation_name operation_reply operation_action pool = do
  phaseLog "spiel"    $ symbolVal' operation_name
  phaseLog "pool.fid" $ show (M0.fid pool)
  unlift <- mkUnliftProcess
  next <- liftProcess $ do
    rc <- DP.getSelfPid
    return $ DP.usend rc . operation_reply pool
  mp <- G.connectedTo Cluster Has <$> getLocalGraph
  er <- withSpielIO $
          withRConfIO mp $ try (operation_action pool) >>= unlift . next
  case er of
    Right () -> return ()
    Left e -> liftProcess $ next $ Left e

-- | 'mkGenericSpielOperation' specialized for the most common case.
mkGenericSNSOperationSimple :: (Binary a, Typeable a, Typeable k, KnownSymbol k)
  => Proxy# k
  -> (Fid -> IO a)
  -> M0.Pool
  -> PhaseM RC l ()
mkGenericSNSOperationSimple n f = mkGenericSNSOperation n
  (\pool eresult -> GenericSNSOperationResult pool (first show eresult))
  (\pool -> f (M0.fid pool))

-- | Helper for implementation call to generic spiel operation.
mkGenericSNSReplyHandler :: forall a b c k l . (Show c, Binary c, Typeable c, Typeable b, Typeable k, KnownSymbol k)
  => Proxy# k                                               -- ^ Rule name
  -> (String -> M0.Pool -> PhaseM RC l (Either a b)) -- ^ Error result converter.
  -> (c      -> M0.Pool -> PhaseM RC l (Either a b)) -- ^ Success result onverter.
  -> (M0.Pool -> (Either a b) -> PhaseM RC l ())     -- ^ Handler
  -> RuleM RC l (Jump PhaseHandle)
mkGenericSNSReplyHandler n onError onSuccess action = do
  ph <- phaseHandle $ symbolVal' n ++ " reply"
  setPhase ph $ \(GenericSNSOperationResult pool er :: GenericSNSOperationResult k c) -> do
    phaseLog "pool.fid" $ show (M0.fid pool)
    result <- case er of
      Left s -> do phaseLog "result" "ERROR"
                   phaseLog "error" s
                   onError s pool
      Right x -> do phaseLog "result" (show x)
                    onSuccess x pool
    action pool result
  return ph

-- | 'mkGenericSpielReplyHandler' specialized for the most common case.
mkGenericSNSReplyHandlerSimple :: (Typeable b, Binary b, KnownSymbol k, Typeable k, Show b)
  => Proxy# k
  -> (M0.Pool -> String  -> PhaseM RC l ()) -- ^ Error handler
  -> (M0.Pool -> b -> PhaseM RC l ())       -- ^ Result handler
  -> RuleM RC l (Jump PhaseHandle)
mkGenericSNSReplyHandlerSimple n onError onResult =
  mkGenericSNSReplyHandler n (const . return . Left) (const . return . Right)
    (\pool-> either (onError pool) (onResult pool))

-- Tier 2

-- | Generate function for the very simple case when there is no logic
-- rather than send request and receive reply.
mkSimpleSNSOperation :: forall a l n . (KnownSymbol n, Typeable a, Typeable n, Binary a, Show a)
                     => Proxy n
                     -> (Fid -> IO a)
                     -> (M0.Pool -> String -> PhaseM RC l ())
                     -> (M0.Pool -> a -> PhaseM RC l ())
                     -> RuleM RC l (Jump PhaseHandle, M0.Pool -> PhaseM RC l ())
mkSimpleSNSOperation _ action onFailure onResult = do
  phase <- handleReply onFailure onResult
  return ( phase
         , mkGenericSNSOperationSimple p action)
  where
    p :: Proxy# n
    p = proxy#
    handleReply :: (M0.Pool -> String -> PhaseM RC l ())
                -> (M0.Pool -> a      -> PhaseM RC l ())
                -> RuleM RC l (Jump PhaseHandle)
    handleReply = mkGenericSNSReplyHandlerSimple p

-- Tier 3

-- | Generate function that query status until operation will complete.
mkStatusCheckingSNSOperation :: forall l n . (KnownSymbol n, Typeable n)
  => Proxy n
  -> (    (M0.Pool -> String -> PhaseM RC l ())
       -> (M0.Pool -> [SnsStatus] -> PhaseM RC l ())
       -> RuleM RC l (Jump PhaseHandle, M0.Pool -> PhaseM RC l ()))
  -> (Fid -> IO ())
  -> [SnsCmStatus]
  -> Int                        -- ^ Timeout between retries (in seconds).
  -> (l -> M0.Pool)             -- ^ Getter of the pool.
  -> (M0.Pool -> String -> PhaseM RC l ()) -- ^ Handler on Failure.
  -> (M0.Pool -> [(Fid, SnsCmStatus)] -> PhaseM RC l ()) -- ^ Handler on success.
  -> RuleM RC l (Jump PhaseHandle, M0.Pool -> PhaseM RC l ())
mkStatusCheckingSNSOperation name mk action interesting n getter onFailure onSuccess = do
  next_request <- phaseHandle $ symbolVal name ++ "::next request"
  (status_received, statusRequest) <- mk onFailure $ \pool xs -> do
     if all (`elem` interesting) (map _sss_state xs)
     then onSuccess pool (map ((,) <$> _sss_fid <*> _sss_state) xs)
     else continue (timeout n next_request)
  operation_done <- handleReply onFailure $ \pool _ -> do
    statusRequest pool
    continue status_received
  directly next_request $ do
    pool <- gets Local getter
    statusRequest pool
    continue status_received
  return ( operation_done
         , mkGenericSNSOperationSimple p action)
  where
    p :: Proxy# n
    p = proxy#
    handleReply :: (M0.Pool -> String -> PhaseM RC l ())
                -> (M0.Pool -> ()     -> PhaseM RC l ())
                -> RuleM RC l (Jump PhaseHandle)
    handleReply = mkGenericSNSReplyHandlerSimple p

-------------------------------------------------------------------------------
-- SNS Operations
-------------------------------------------------------------------------------

-- | Start the repair operation on the given 'M0.Pool' asynchronously.
mkRepairStartOperation ::
  (M0.Pool -> Either String UUID -> PhaseM RC l ()) -- ^ Result handler.
  -> RuleM RC l (Jump PhaseHandle, M0.Pool -> PhaseM RC l ())
mkRepairStartOperation handler = do
  operation_started <- mkRepairOperationStarted handler
  return ( operation_started
         , mkGenericSNSOperationSimple p poolRepairStart
         )
  where
    p :: Proxy# "Repair start"
    p = proxy#
    -- | Create a phase to handle pool repair operation start result.
    mkRepairOperationStarted ::
           (M0.Pool -> Either String UUID -> PhaseM RC l ())
        -> RuleM RC l (Jump PhaseHandle)
    mkRepairOperationStarted = mkGenericSNSReplyHandler p
      (const . return . Left)
      (\() pool -> do
         uuid <- DP.liftIO nextRandom
         setPoolRepairStatus pool $ M0.PoolRepairStatus M0.Failure uuid Nothing
         return (Right uuid))

-- | Start the rebalance operation on the given 'M0.Pool' asynchronously.
mkRebalanceStartOperation ::
  (M0.Pool -> Either String UUID -> PhaseM RC l ()) -- ^ Result handler.
  -> RuleM RC l (Jump PhaseHandle, M0.Pool -> [M0.Disk] -> PhaseM RC l ())
mkRebalanceStartOperation handler = do
  operation_started <- handleReply handler
  return ( operation_started
         , \pool disks -> do
             phaseLog "spiel" $ "Starting rebalance on pool"
             phaseLog "pool"  $ show pool
             phaseLog "disks" $ show disks
             -- XXX: is it really safe to do that here?
             for_ disks $ \d -> do
               mt <- lookupDiskSDev d
               for_ mt $ \t -> do
                 msd <- lookupStorageDevice t
                 for_ msd unmarkStorageDeviceReplaced
             mkGenericSNSOperationSimple p poolRebalanceStart pool
         )
  where
    p :: Proxy# "Rebalance start"
    p = proxy#
    handleReply :: (M0.Pool -> Either String UUID -> PhaseM RC l ())
                -> RuleM RC l (Jump PhaseHandle)
    handleReply = mkGenericSNSReplyHandler p
      (const . return . Left)
      (\() pool -> do
         uuid <- DP.liftIO nextRandom
         setPoolRepairStatus pool $ M0.PoolRepairStatus M0.Rebalance uuid Nothing
         return (Right uuid))


-- | Create a phase to handle pool repair operation start result.
mkRepairStatusRequestOperation ::
     (M0.Pool -> String -> PhaseM RC l ())
  -> (M0.Pool -> [SnsStatus] -> PhaseM RC l ())
  -> RuleM RC l (Jump PhaseHandle, M0.Pool -> PhaseM RC l ())
mkRepairStatusRequestOperation =
  mkSimpleSNSOperation  (Proxy :: Proxy "Repair status request") poolRepairStatus

-- | Continue the rebalance operation.
mkRepairContinueOperation ::
     (M0.Pool -> String -> PhaseM RC l ())
  -> (M0.Pool -> () -> PhaseM RC l ())
  -> RuleM RC l (Jump PhaseHandle, M0.Pool -> PhaseM RC l ())
mkRepairContinueOperation =
  mkSimpleSNSOperation (Proxy :: Proxy "Repair continue") poolRepairContinue


-- | Continue the rebalance operation.
mkRebalanceContinueOperation ::
     (M0.Pool -> String -> PhaseM RC l ())
  -> (M0.Pool -> ()     -> PhaseM RC l ())
  -> RuleM RC l (Jump PhaseHandle, M0.Pool -> PhaseM RC l ())
mkRebalanceContinueOperation = do
  mkSimpleSNSOperation (Proxy :: Proxy "Rebalance continue") poolRebalanceContinue

-- | Create a phase to handle pool repair operation start result.
mkRebalanceStatusRequestOperation ::
     (M0.Pool -> String      -> PhaseM RC l ())
  -> (M0.Pool -> [SnsStatus] -> PhaseM RC l ())
  -> RuleM RC l (Jump PhaseHandle, M0.Pool -> PhaseM RC l ())
mkRebalanceStatusRequestOperation = do
  mkSimpleSNSOperation (Proxy :: Proxy "Rebalance status request") poolRebalanceStatus

-- | Create code that allow to quisce repair operation.
mkRepairQuiesceOperation ::
     Int                        -- ^ Timeout between retries (in seconds).
  -> (l -> M0.Pool)             -- ^ Getter of the pool.
  -> (M0.Pool -> String -> PhaseM RC l ()) -- ^ Handler on Failure.
  -> (M0.Pool -> [(Fid, SnsCmStatus)] -> PhaseM RC l ()) -- ^ Handler on success.
  -> RuleM RC l (Jump PhaseHandle, M0.Pool -> PhaseM RC l ())
mkRepairQuiesceOperation =
  mkStatusCheckingSNSOperation
    (Proxy :: Proxy "Repair quiesce")
    mkRepairStatusRequestOperation
    poolRepairQuiesce
    [ Mero.Spiel.M0_SNS_CM_STATUS_FAILED
    , Mero.Spiel.M0_SNS_CM_STATUS_PAUSED
    , Mero.Spiel.M0_SNS_CM_STATUS_IDLE]

-- | Create an action and helper phases that will allow to abort SNS operation
-- and wait until it will be really aborted.
mkRepairAbortOperation ::
     Int
  -> (l -> M0.Pool)
  -> (M0.Pool -> String -> PhaseM RC l ()) -- ^ Handler on Failure
  -> (M0.Pool -> [(Fid, SnsCmStatus)] -> PhaseM RC l ()) -- ^ Handler on success
  -> RuleM RC l (Jump PhaseHandle, M0.Pool -> PhaseM RC l ())
mkRepairAbortOperation =
  mkStatusCheckingSNSOperation
    (Proxy :: Proxy "Repair abort")
    mkRepairStatusRequestOperation
    poolRepairAbort
    [ Mero.Spiel.M0_SNS_CM_STATUS_FAILED
    , Mero.Spiel.M0_SNS_CM_STATUS_PAUSED
    , Mero.Spiel.M0_SNS_CM_STATUS_IDLE]

-- | Create code that allow to quisce repair operation.
mkRebalanceQuiesceOperation ::
     Int                        -- ^ Timeout between retries (in seconds).
  -> (l -> M0.Pool)             -- ^ Getter of the pool.
  -> (M0.Pool -> String -> PhaseM RC l ()) -- ^ Handler on Failure.
  -> (M0.Pool -> [(Fid, SnsCmStatus)] -> PhaseM RC l ()) -- ^ Handler on success.
  -> RuleM RC l (Jump PhaseHandle, M0.Pool -> PhaseM RC l ())
mkRebalanceQuiesceOperation = do
  mkStatusCheckingSNSOperation
    (Proxy :: Proxy "Rebalance quiesce")
    mkRebalanceStatusRequestOperation
    poolRebalanceQuiesce
    [ Mero.Spiel.M0_SNS_CM_STATUS_FAILED
    , Mero.Spiel.M0_SNS_CM_STATUS_PAUSED
    , Mero.Spiel.M0_SNS_CM_STATUS_IDLE]

-- | Generate code to call abort operation.
mkRebalanceAbortOperation ::
     Int
  -> (l -> M0.Pool)
  -> (M0.Pool -> String -> PhaseM RC l ()) -- ^ Handler on Failure
  -> (M0.Pool -> [(Fid, SnsCmStatus)] -> PhaseM RC l ()) -- ^ Handler on success
  -> RuleM RC l (Jump PhaseHandle, M0.Pool -> PhaseM RC l ())
mkRebalanceAbortOperation = do
  mkStatusCheckingSNSOperation
    (Proxy :: Proxy "Rebalance abort")
    mkRebalanceStatusRequestOperation
    poolRebalanceAbort
    [ Mero.Spiel.M0_SNS_CM_STATUS_FAILED
    , Mero.Spiel.M0_SNS_CM_STATUS_PAUSED
    , Mero.Spiel.M0_SNS_CM_STATUS_IDLE]

-- | Synchronize graph to confd.
-- Currently all Exceptions during this operation are caught, this is required in because
-- there is no good exception handling in RC and uncaught exception will lead to RC failure.
-- Also it's behaviour of RC in case of mero exceptions is not specified.
syncAction :: Maybe UUID -> SyncToConfd -> PhaseM RC l ()
syncAction meid sync =
   flip catch (\e -> phaseLog "error" $ "Exception during sync: "++show (e::SomeException))
       $ do
    case sync of
      SyncToConfdServersInRG -> flip catch (handler (const $ return ())) $ do
        phaseLog "info" "Syncing RG to confd servers in RG."
        void syncToConfd
      SyncDumpToBS pid -> flip catch (handler $ failToBS pid) $ do
        bs <- syncToBS
        liftProcess . DP.usend pid . M0.SyncDumpToBSReply $ Right bs
    traverse_ messageProcessed meid
  where
    failToBS :: DP.ProcessId -> SomeException -> DP.Process ()
    failToBS pid = DP.usend pid . M0.SyncDumpToBSReply . Left . show

    handler :: (SomeException -> DP.Process ())
            -> SomeException
            -> PhaseM RC l ()
    handler act e = do
      phaseLog "error" $ "Exception during sync: " ++ show e
      liftProcess $ act e

-- | Dump the conf into a 'BS.ByteString'.
--
--   Note that this uses a local worker, because it may be invoked before
--   `ha_interface` is loaded and hence no Spiel context is available.
syncToBS :: PhaseM RC l BS.ByteString
syncToBS = loadConfData >>= \case
  Just tx -> do
    M0.ConfUpdateVersion verno _ <- getConfUpdateVersion
    wrk <- DP.liftIO $ newM0Worker
    bs <- txOpenLocalContext (mkLiftRC wrk)
      >>= txPopulate (mkLiftRC wrk) tx
      >>= m0synchronously (mkLiftRC wrk) .flip txToBS verno
    DP.liftIO $ terminateM0Worker wrk
    return bs
  Nothing -> error "Cannot load configuration data from graph."

-- | Helper functions for backward compatibility.
syncToConfd :: PhaseM RC l (Either SomeException ())
syncToConfd = do
  withSpielRC $ \lift -> do
     setProfileRC lift
     loadConfData >>= traverse_ (\x -> txOpenContext lift >>= txPopulate lift x >>= txSyncToConfd lift)

-- | Open a transaction. Ultimately this should not need a
--   spiel context.
txOpenContext :: LiftRC -> PhaseM RC l SpielTransaction
txOpenContext lift = m0synchronously lift openTransaction

txOpenLocalContext :: LiftRC -> PhaseM RC l SpielTransaction
txOpenLocalContext lift = m0synchronously lift openLocalTransaction

txSyncToConfd :: LiftRC -> SpielTransaction -> PhaseM RC l ()
txSyncToConfd lift t = do
  phaseLog "spiel" "Committing transaction to confd"
  M0.ConfUpdateVersion v h <- getConfUpdateVersion
  h' <- return . hash <$> m0synchronously lift (txToBS t v)
  if h /= h'
  then m0synchronously lift (commitTransactionForced t False v) >>= \case
    Right () -> do
      -- spiel increases conf version here so we should too; alternative
      -- would be querying spiel after transaction for the new version
      modifyConfUpdateVersion (\(M0.ConfUpdateVersion i _) -> M0.ConfUpdateVersion (succ i) h')
      phaseLog "spiel" $ "Transaction committed, new hash: " ++ show h'
    Left err ->
      phaseLog "spiel" $ "Transaction commit failed with cache failure:" ++ err
  else phaseLog "spiel" $ "Conf unchanged with hash " ++ show h' ++ ", not committing"
  m0asynchronously_ lift $ closeTransaction t
  phaseLog "spiel" "Transaction closed."

data TxConfData = TxConfData M0.M0Globals M0.Profile M0.Filesystem

loadConfData :: PhaseM RC l (Maybe TxConfData)
loadConfData = liftA3 TxConfData
            <$> getM0Globals
            <*> getProfile
            <*> getFilesystem

-- | Gets the current 'ConfUpdateVersion' used when dumping
-- 'SpielTransaction' out. If this is not set, it's set to the default of @1@.
getConfUpdateVersion :: PhaseM RC l M0.ConfUpdateVersion
getConfUpdateVersion = do
  g <- getLocalGraph
  case G.connectedTo Cluster Has g of
    Just ver -> return ver
    Nothing -> do
      let csu = M0.ConfUpdateVersion 1 Nothing
      modifyLocalGraph $ G.newResource csu >>> return . G.connect Cluster Has csu
      return csu

modifyConfUpdateVersion :: (M0.ConfUpdateVersion -> M0.ConfUpdateVersion)
                        -> PhaseM RC l ()
modifyConfUpdateVersion f = do
  csu <- getConfUpdateVersion
  let fcsu = f csu
  phaseLog "rg" $ "Setting ConfUpdateVersion to " ++ show fcsu
  modifyLocalGraph $ return . G.connect Cluster Has fcsu

txPopulate :: LiftRC -> TxConfData -> SpielTransaction -> PhaseM RC l SpielTransaction
txPopulate lift (TxConfData CI.M0Globals{..} (M0.Profile pfid) fs@M0.Filesystem{..}) t = do
  g <- getLocalGraph
  -- Profile, FS, pool
  -- Top-level pool width is number of devices in existence
  let m0_pool_width = length [ disk
                             | rack :: M0.Rack <- G.connectedTo fs M0.IsParentOf g
                             , encl :: M0.Enclosure <- G.connectedTo rack M0.IsParentOf g
                             , cntr :: M0.Controller <- G.connectedTo encl M0.IsParentOf g
                             , disk :: M0.Disk <- G.connectedTo cntr M0.IsParentOf g
                             ]
      fsParams = printf "%d %d %d" m0_pool_width m0_data_units m0_parity_units
  m0synchronously lift $ do
    addProfile t pfid
    addFilesystem t f_fid pfid m0_md_redundancy pfid f_mdpool_fid [fsParams]
  phaseLog "spiel" "Added profile, filesystem, mdpool objects."
  -- Racks, encls, controllers, disks
  let racks = G.connectedTo fs M0.IsParentOf g :: [M0.Rack]
  for_ racks $ \rack -> do
    m0synchronously lift $ addRack t (M0.fid rack) f_fid
    let encls = G.connectedTo rack M0.IsParentOf g :: [M0.Enclosure]
    for_ encls $ \encl -> do
      m0synchronously lift $ addEnclosure t (M0.fid encl) (M0.fid rack)
      let ctrls = G.connectedTo encl M0.IsParentOf g :: [M0.Controller]
      for_ ctrls $ \ctrl -> do
        -- Get node fid
        let Just node = G.connectedFrom M0.IsOnHardware ctrl g :: Maybe M0.Node
        m0synchronously lift $ addController t (M0.fid ctrl) (M0.fid encl) (M0.fid node)
        let disks = G.connectedTo ctrl M0.IsParentOf g :: [M0.Disk]
        for_ disks $ \disk -> do
          m0synchronously lift $ addDisk t (M0.fid disk) (M0.fid ctrl)
  -- Nodes, processes, services, sdevs
  let nodes = G.connectedTo fs M0.IsParentOf g :: [M0.Node]
  for_ nodes $ \node -> do
    let attrs =
          [ a | Just ctrl <- [G.connectedTo node M0.IsOnHardware g :: Maybe M0.Controller]
              , Just host <- [G.connectedTo ctrl M0.At g :: Maybe Host]
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
    m0synchronously lift $ addNode t (M0.fid node) f_fid memsize cpucount 0 0 f_mdpool_fid
    let procs = G.connectedTo node M0.IsParentOf g :: [M0.Process]
    for_ procs $ \(proc@M0.Process{..}) -> do
      m0synchronously lift $ addProcess t r_fid (M0.fid node) r_cores
                            r_mem_as r_mem_rss r_mem_stack r_mem_memlock
                            r_endpoint
      let servs = G.connectedTo proc M0.IsParentOf g :: [M0.Service]
      for_ servs $ \(serv@M0.Service{..}) -> do
        m0synchronously lift $ addService t s_fid r_fid (ServiceInfo s_type s_endpoints s_params)
        let sdevs = G.connectedTo serv M0.IsParentOf g :: [M0.SDev]
        for_ sdevs $ \(sdev@M0.SDev{..}) -> do
          let disk = G.connectedTo sdev M0.IsOnHardware g :: Maybe M0.Disk
          m0synchronously lift $ addDevice t d_fid s_fid (fmap M0.fid disk) d_idx
                   M0_CFG_DEVICE_INTERFACE_SATA
                   M0_CFG_DEVICE_MEDIA_DISK d_bsize d_size 0 0 d_path
  phaseLog "spiel" "Finished adding concrete entities."
  -- Pool versions
  let pools = G.connectedTo fs M0.IsParentOf g :: [M0.Pool]
      pvNegWidth pver = case pver of
                         M0.PVer _ a@M0.PVerActual{}    -> negate . _pa_P . M0.v_attrs $ a
                         M0.PVer _ M0.PVerFormulaic{} -> 0
  for_ pools $ \pool -> do
    m0synchronously lift $ addPool t (M0.fid pool) f_fid 0
    let pvers = sortOn pvNegWidth $ G.connectedTo pool M0.IsRealOf g :: [M0.PVer]
    for_ pvers $ \pver -> do
      case M0.v_type pver of
        pva@M0.PVerActual{} -> do
          m0synchronously lift $ addPVerActual t (M0.fid pver) (M0.fid pool) (M0.v_attrs pva) (M0.v_tolerance pva)
          let rackvs = G.connectedTo pver M0.IsParentOf g :: [M0.RackV]
          for_ rackvs $ \rackv -> do
            let (Just (rack :: M0.Rack)) = G.connectedFrom M0.IsRealOf rackv g
            m0synchronously lift $ addRackV t (M0.fid rackv) (M0.fid pver) (M0.fid rack)
            let enclvs = G.connectedTo rackv M0.IsParentOf g :: [M0.EnclosureV]
            for_ enclvs $ \enclv -> do
              let (Just (encl :: M0.Enclosure)) = G.connectedFrom M0.IsRealOf enclv g
              m0synchronously lift $ addEnclosureV t (M0.fid enclv) (M0.fid rackv) (M0.fid encl)
              let ctrlvs = G.connectedTo enclv M0.IsParentOf g :: [M0.ControllerV]
              for_ ctrlvs $ \ctrlv -> do
                let (Just (ctrl :: M0.Controller)) = G.connectedFrom M0.IsRealOf ctrlv g
                m0synchronously lift $ addControllerV t (M0.fid ctrlv) (M0.fid enclv) (M0.fid ctrl)
                let diskvs = G.connectedTo ctrlv M0.IsParentOf g :: [M0.DiskV]
                for_ diskvs $ \diskv -> do
                  let (Just (disk :: M0.Disk)) = G.connectedFrom M0.IsRealOf diskv g

                  m0synchronously lift $ addDiskV t (M0.fid diskv) (M0.fid ctrlv) (M0.fid disk)
          m0synchronously lift $ poolVersionDone t (M0.fid pver)
        pvf@M0.PVerFormulaic{} -> do
          base <- lookupConfObjByFid (M0.v_base pvf)
          case fmap M0.v_type base of
            Nothing -> phaseLog "warning" $ "Ignoring pool version " ++ show pvf
                   ++ " because base pver can't be found"
            Just (pva@M0.PVerActual{}) -> do
              let(PDClustAttr n k p _ _) = M0.v_attrs pva
              if (M0.v_allowance pvf !! confPVerLvlDisks <= p - (n + 2*k))
              then m0synchronously lift $ addPVerFormulaic t (M0.fid pver) (M0.fid pool)
                            (M0.v_id pvf) (M0.v_base pvf) (M0.v_allowance pvf)
              else phaseLog "warning" $ "Ignoring pool version " ++ show pvf
                     ++ " because it doesn't meet"
                     ++ " allowance[M0_CONF_PVER_LVL_DISKS] <=  P - (N+2K) criteria"
            Just _ ->
              phaseLog "warning" $ "Ignoring pool version " ++ show pvf
                 ++ " because base pver is not an actual pversion"
  return t

-- | Load the current conf data, create a transaction that we would
-- send to spiel and ask mero if the transaction cache is valid.
validateTransactionCache :: PhaseM RC l (Either SomeException (Maybe String))
validateTransactionCache = loadConfData >>= \case
  Nothing -> do
    phaseLog "spiel" "validateTransactionCache: loadConfData failed"
    return (Right Nothing)
  Just x -> do
    phaseLog "spiel" "validateTransactionCache: validating context"
    -- We can use withSpielRC because SpielRC require ha_interface to be started
    -- in order to read spiel context out of it. However we may not be able to
    -- start ha_interface because it require configuraion to be loaded. And this
    -- call can be run on unbootstrapped cluster.
    wrk <- DP.liftIO $ newM0Worker
    r <- try $ txOpenLocalContext (mkLiftRC wrk)
           >>= txPopulate (mkLiftRC wrk) x
           >>= m0synchronously (mkLiftRC wrk) . txValidateTransactionCache
    DP.liftIO $ terminateM0Worker wrk
    return r

-- | RC wrapper for 'getSpielAddress'.
getSpielAddressRC :: PhaseM RC l (Maybe M0.SpielAddress)
getSpielAddressRC = getSpielAddress True <$> getLocalGraph

-- | Store 'ResourceGraph' in 'globalResourceGraphCache' in order to avoid dead
-- lock conditions. RC performing all queries sequentially, thus it can't reply
-- to the newly arrived queries to 'ResourceGraph'. This opens a possiblity of
-- a deadlock if some internal operation that RC is performing creates a query
-- to RC, and such deadlock happens in spiel operations.
-- For this reason we store a graph projection in a variable and methods that
-- could be blocked should first query this cached value first.
withResourceGraphCache :: PhaseM RC l a -> PhaseM RC l a
withResourceGraphCache action = do
  g <- getLocalGraph
  liftProcess $ DP.liftIO $ writeIORef globalResourceGraphCache (Just g)
  x <- action
  liftProcess $ DP.liftIO $ writeIORef globalResourceGraphCache Nothing
  return x

----------------------------------------------------------
-- Pool repair information functions                    --
----------------------------------------------------------

-- | Return the 'M0.PoolRepairStatus' structure. If one is not in
-- the graph, it means no repairs are going on
getPoolRepairStatus :: M0.Pool
                    -> PhaseM RC l (Maybe M0.PoolRepairStatus)
getPoolRepairStatus pool = G.connectedTo pool Has <$> getLocalGraph

-- | Set the given 'M0.PoolRepairStatus' in the graph. Any
-- previously connected @PRI@s are disconnected.
setPoolRepairStatus :: M0.Pool -> M0.PoolRepairStatus -> PhaseM RC l ()
setPoolRepairStatus pool prs =
  modifyLocalGraph $ return . G.connect pool Has prs

-- | Remove all 'M0.PoolRepairStatus' connection to the given 'M0.Pool'.
unsetPoolRepairStatus :: M0.Pool -> PhaseM RC l ()
unsetPoolRepairStatus pool = do
  phaseLog "info" $ "Unsetting PRS from " ++ show pool
  modifyLocalGraph $ return . G.disconnectAllFrom pool Has (Proxy :: Proxy M0.PoolRepairStatus)

-- | Remove 'M0.PoolRepairStatus' connection to the given 'M0.Pool' as
-- long as it has the matching 'M0.prsRepairUUID'. This is useful if
-- we want to clean up but we're not sure if the 'M0.PoolRepairStatus'
-- belongs to the clean up handler.
unsetPoolRepairStatusWithUUID :: M0.Pool -> UUID -> PhaseM RC l ()
unsetPoolRepairStatusWithUUID pool uuid = getPoolRepairStatus pool >>= \case
  Just prs | M0.prsRepairUUID prs == uuid -> unsetPoolRepairStatus pool
  _ -> return ()

-- | Return the 'M0.PoolRepairInformation' structure. If one is not in
-- the graph, it means no repairs are going on.
getPoolRepairInformation :: M0.Pool
                         -> PhaseM RC l (Maybe M0.PoolRepairInformation)
getPoolRepairInformation pool =
    join . fmap M0.prsPri . G.connectedTo pool Has <$>
    getLocalGraph

-- | Set the given 'M0.PoolRepairInformation' in the graph. Any
-- previously connected @PRI@s are disconnected.
--
-- Does nothing if we haven't at least set 'M0.PoolRepairType'
-- already.
setPoolRepairInformation :: M0.Pool
                         -> M0.PoolRepairInformation
                         -> PhaseM RC l ()
setPoolRepairInformation pool pri = getPoolRepairStatus pool >>= \case
  Nothing -> return ()
  Just (M0.PoolRepairStatus prt uuid _) -> do
    let prs = M0.PoolRepairStatus prt uuid $ Just pri
    phaseLog "rg" $ "Setting PRR for " ++ show pool ++ " to " ++ show prs
    modifyLocalGraph $ return . G.connect pool Has prs

-- | Initialise 'M0.PoolRepairInformation' with some default values.
possiblyInitialisePRI :: M0.Pool
                      -> PhaseM RC l ()
possiblyInitialisePRI pool = getPoolRepairInformation pool >>= \case
  Nothing -> setPoolRepairInformation pool M0.defaultPoolRepairInformation
  Just _ -> return ()

-- | Modify the  'PoolRepairInformation' in the graph with the given function.
-- Any previously connected @PRI@s are disconnected.
modifyPoolRepairInformation :: M0.Pool
                            -> (M0.PoolRepairInformation -> M0.PoolRepairInformation)
                            -> PhaseM RC l ()
modifyPoolRepairInformation pool f = modifyLocalGraph $ \g ->
  case G.connectedTo pool Has $ g of
    Just (M0.PoolRepairStatus prt uuid (Just pri)) ->
      return $ G.connect pool Has (M0.PoolRepairStatus prt uuid (Just $ f pri)) g
    _ -> return g


-- | Increment 'priOnlineNotifications' field of the
-- 'PoolRepairInformation' in the graph. Also updates the
-- 'priTimeOfFirstCompletion' if it has not yet been set.
incrementOnlinePRSResponse :: M0.Pool
                           -> PhaseM RC l ()
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
updatePoolRepairStatusTime :: M0.Pool -> PhaseM RC l ()
updatePoolRepairStatusTime pool = getPoolRepairStatus pool >>= \case
  Just (M0.PoolRepairStatus _ _ (Just pr)) -> do
    t <- DP.liftIO M0.getTime
    setPoolRepairInformation pool $ pr { M0.priTimeLastHourlyRan = t }
  _ -> return ()

-- | Returns number of seconds until we have to run the hourly PRI
-- query.
getTimeUntilQueryHourlyPRI :: M0.Pool -> PhaseM RC l Int
getTimeUntilQueryHourlyPRI pool = getPoolRepairInformation pool >>= \case
  Nothing -> return 0
  Just pri -> do
    tn <- DP.liftIO M0.getTime
    let elapsed = tn - M0.priTimeLastHourlyRan pri
        untilHourPasses = M0.mkTimeSpec 3600 - elapsed
    return $ M0.timeSpecToSeconds untilHourPasses

-- | Set profile in current thread.
setProfileRC :: LiftRC -> PhaseM RC l ()
setProfileRC lift = do
  rg <- getLocalGraph
  let mp = G.connectedTo Cluster Has rg :: Maybe M0.Profile -- XXX: multiprofile is not supported
  phaseLog "spiel" $ "set command profile to" ++ show mp
  m0synchronously lift $ Mero.Spiel.setCmdProfile (fmap (\(M0.Profile p) -> show p) mp)