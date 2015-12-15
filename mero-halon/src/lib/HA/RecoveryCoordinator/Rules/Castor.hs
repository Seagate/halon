{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DoAndIfThenElse       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE LambdaCase            #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Rules specific to Castor install of Mero.

module HA.RecoveryCoordinator.Rules.Castor where

import Control.Distributed.Process
import HA.EventQueue.Types

import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Hardware
import HA.RecoveryCoordinator.Events.Drive
import HA.RecoveryCoordinator.Events.Mero
import HA.Resources
import HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.ResourceGraph as G
import HA.Services.SSPL
import HA.EventQueue.Producer
#ifdef USE_MERO
import Control.Category ((>>>))
import HA.Service
import HA.Services.Mero
import Mero.ConfC (ServiceType(..), ServiceParams(..), bitmapFromArray)
import qualified Mero.Spiel as Spiel
import HA.Resources.Mero hiding (Node, Process, Enclosure, Rack)
import qualified HA.Resources.Mero as M0
import HA.Resources.Mero.Note
import HA.RecoveryCoordinator.Actions.Mero
import Mero.Notification hiding (notifyMero)
import Mero.Notification.HAState
import Control.Exception (SomeException)
import Data.List (unfoldr)
import Data.UUID.V4 (nextRandom)
import Data.Proxy (Proxy(..))
#endif
import Data.Foldable

import Control.Distributed.Process.Closure (mkClosure)

import Control.Applicative (liftA2)
import Control.Monad
import Data.Maybe (mapMaybe, listToMaybe)
import Data.Binary (Binary)
import Data.Monoid ((<>))
import Data.Text (Text, pack)
import Data.Typeable (Typeable)
import System.Posix.SysInfo

import GHC.Generics (Generic)

import Network.CEP
import Prelude hiding (id)

-- | RMS service address.
rmsAddress :: String
rmsAddress = "@tcp:12345:41:301"

-- | Halon service addres.
haAddress :: String
haAddress = "@tcp:12345:35:101"

-- | Event sent when to many failures has been sent for a 'Disk'.
data ResetAttempt = ResetAttempt StorageDevice
  deriving (Eq, Generic, Show, Typeable)

instance Binary ResetAttempt

-- | Event sent when a ResetAttempt were successful.
newtype ResetSuccess =
    ResetSuccess StorageDevice
    deriving (Eq, Show, Binary)

-- | Event sent when a ResetAttempt failed.
newtype ResetFailure =
    ResetFailure StorageDevice
    deriving (Eq, Show, Binary)

lookupStorageDevicePathsInGraph :: StorageDevice -> G.Graph -> [String]
lookupStorageDevicePathsInGraph sd g =
    mapMaybe extractPath $ ids
  where
    ids = G.connectedTo sd Has g
    extractPath (DIPath x) = Just x
    extractPath _ = Nothing

-- | When the number of reset attempts is greater than this threshold, a 'Disk'
--   should be in 'DiskFailure' status.
resetAttemptThreshold :: Int
resetAttemptThreshold = 10

-- | Time to allow for SSPL to reply.
ssplTimeout :: Int
ssplTimeout = 1

-- | States of the Timeout rule.OB
data TimeoutState = TimeoutNormal | ResetAttemptSent

onCommandAck :: (Text -> NodeCmd)
           -> HAEvent CommandAck
           -> g
           -> Maybe (StorageDevice, String, UUID)
           -> Process (Maybe CommandAck)
onCommandAck _ _ _ Nothing = return Nothing
onCommandAck k (HAEvent _ cmd _) _ (Just (_, path, _)) =
  case commandAckType cmd of
    Just x | (k . pack $ path) == x -> return $ Just cmd
           | otherwise      -> return Nothing
    _ -> return Nothing

onSmartSuccess :: HAEvent CommandAck
               -> g
               -> Maybe (StorageDevice, String, UUID)
               -> Process (Maybe ())
onSmartSuccess (HAEvent _ cmd _) _ (Just (_, path, _)) =
    case commandAckType cmd of
      Just (SmartTest x)
        | pack path == x ->
          case commandAck cmd of
            AckReplyPassed -> return $ Just ()
            _              -> return Nothing
        | otherwise -> return Nothing
      _ -> return Nothing
onSmartSuccess _ _ _ = return Nothing

onSmartFailure :: HAEvent CommandAck
               -> g
               -> Maybe (StorageDevice, String, UUID)
               -> Process (Maybe (Maybe Text))
onSmartFailure (HAEvent _ cmd _) _ (Just (_, path, _)) =
    case commandAckType cmd of
      Just (SmartTest x)
        | pack path == x ->
          case commandAck cmd of
            AckReplyFailed  -> return $ Just Nothing
            AckReplyError e -> return $ Just $ Just e
            _               -> return Nothing
        | otherwise -> return Nothing
      _ -> return Nothing
onSmartFailure _ _ _ = return Nothing

castorRules :: Definitions LoopState ()
castorRules = do
    defineSimple "Initial-data-load" $ \(HAEvent eid CI.InitialData{..} _) -> do
      mapM_ goRack id_racks
#ifdef USE_MERO
      rg <- getLocalGraph
      filesystem <- initialiseConfInRG
      loadMeroGlobals id_m0_globals
      loadMeroServers filesystem id_m0_servers
      failureSets <- case (CI.m0_failure_set_gen id_m0_globals) of
        CI.Dynamic -> return []
        CI.Preloaded x y z -> generateFailureSets x y z
      let
        poolVersions = fmap (failureSetToPoolVersion rg filesystem) failureSets
        chunks = flip unfoldr poolVersions $ \xs ->
          case xs of
            [] -> Nothing
            _  -> -- TODO: Take into account the size of failure sets to do
                  -- the spliting.
                  Just $ splitAt 5 xs
      forM_ chunks $ \chunk -> do
        createPoolVersions filesystem chunk
        syncGraph
#endif
      liftProcess $ say "Loaded initial data"
      rg' <- getLocalGraph
      let hosts = [ host | host <- G.getResourcesOfType rg'    :: [Host] -- all hosts
                         , not  $ G.isConnected host Has HA_M0CLIENT rg' -- and not already a client
                         , not  $ G.isConnected host Has HA_M0SERVER rg' -- and not already a server
                         ]
          nodes = mapMaybe (\host -> case G.connectedTo host Runs rg' of
                               (n:_) -> Just n
                               _     -> Nothing) hosts
      forM_ nodes $ liftProcess . promulgateWait . NewMeroClient
      messageProcessed eid

#ifdef USE_MERO
    defineSimple "mero-note-set" $ \(HAEvent uid (Set ns) _) -> do
      for_ ns $ \(Note mfid tpe) ->
        case tpe of
          M0_NC_FAILED -> do
            sdevm <- lookupConfObjByFid mfid
            for_ sdevm $ \m0sdev -> do
              msdev <- lookupStorageDevice m0sdev
              case msdev of
                Just sdev -> do
                  ongoing <- hasOngoingReset sdev
                  when (not ongoing) $ do
                    ratt <- getDiskResetAttempts sdev
                    let status = if ratt <= resetAttemptThreshold
                                 then M0_NC_TRANSIENT
                                 else M0_NC_FAILED

                    updateDriveState m0sdev status

                    when (status == M0_NC_FAILED) $ do
                      updateDriveManagerWithFailure sdev
                      nid <- liftProcess getSelfNode
                      diskids <- findStorageDeviceIdentifiers sdev
                      let iem = InterestingEventMessage . pack . unwords $ [
                                    "M0_NC_FAILED reported."
                                  , "fid=" ++ show mfid
                                ] ++ map show diskids
                      sendInterestingEvent nid iem
                      pools <- getSDevPools m0sdev
                      traverse_ startRepairOperation pools

                    when (status == M0_NC_TRANSIENT) $ do
                      nid <- liftProcess getSelfNode
                      liftProcess . void . promulgateEQ [nid]
                        $ ResetAttempt sdev
                _ -> do
                  phaseLog "warning" $ "Cannot find all entities attached to M0"
                                    ++ " storage device: "
                                    ++ show m0sdev
                                    ++ ": "
                                    ++ show msdev
          _ -> return ()
      messageProcessed uid

#endif

    define "reset-attempt" $ do
      home         <- phaseHandle "home"
      down         <- phaseHandle "powerdown"
      downComplete <- phaseHandle "powerdown-complete"
      on           <- phaseHandle "poweron"
      onComplete   <- phaseHandle "poweron-complete"
      smart        <- phaseHandle "smart"
      smartSuccess <- phaseHandle "smart-success"
      smartFailure <- phaseHandle "smart-failure"
      end          <- phaseHandle "end"

      setPhase home $ \(HAEvent uid (ResetAttempt sdev) _) -> fork NoBuffer $ do
        markOnGoingReset sdev
        paths <- lookupStorageDevicePaths sdev
        case paths of
          path:_ -> do
            put Local (Just (sdev, path, uid))
            unlessM (isStorageDevicePowered sdev) $
              continue on
            whenM (isStorageDeviceRunningSmartTest sdev) $
              switch [smartSuccess, smartFailure, timeout ssplTimeout down]
            continue down
          [] -> do
            phaseLog "warning" $ "Cannot perform reset attempt for drive "
                              ++ show sdev
                              ++ " as it has no device paths associated."
            messageProcessed uid

      directly down $ do
        Just (sdev, path, _) <- get Local
        nid <- liftProcess getSelfNode
        i <- getDiskPowerOffAttempts sdev
        if i <= resetAttemptThreshold
        then do
          incrDiskPowerOffAttempts sdev
          sendNodeCmd nid Nothing (DrivePowerdown $ pack path)
          switch [downComplete, timeout ssplTimeout down]
        else do
          markResetComplete sdev
#ifdef USE_MERO
          sd <- lookupStorageDeviceSDev sdev
          forM_ sd $ \m0sdev -> do
            updateDriveState m0sdev M0_NC_FAILED
            updateDriveManagerWithFailure sdev
            pools <- getSDevPools m0sdev
            traverse_ startRepairOperation pools
#endif
          continue end

      setPhaseIf downComplete (onCommandAck DrivePowerdown) $ \_ -> do
        Just (sdev, _, _) <- get Local
        markDiskPowerOff sdev
        continue on

      directly on $ do
        Just (sdev, path, _) <- get Local
        nid <- liftProcess getSelfNode
        i <- getDiskPowerOnAttempts sdev
        if i <= resetAttemptThreshold
        then do
          incrDiskPowerOnAttempts sdev
          sendNodeCmd nid Nothing (DrivePoweron $ pack path)
          switch [onComplete, timeout ssplTimeout on]
        else do
          markResetComplete sdev
#ifdef USE_MERO
          sd <- lookupStorageDeviceSDev sdev
          forM_ sd $ \m0sdev -> do
            updateDriveState m0sdev M0_NC_FAILED
            updateDriveManagerWithFailure sdev
            pools <- getSDevPools m0sdev
            traverse_ startRepairOperation pools
#endif
          continue end

      setPhaseIf onComplete (onCommandAck DrivePoweron) $ \_ -> do
        nid <- liftProcess getSelfNode
        Just (sdev, path, _) <- get Local
        markDiskPowerOn sdev
        incrDiskResetAttempts sdev
        markSMARTTestIsRunning sdev
        sendNodeCmd nid Nothing (SmartTest $ pack path)
        continue smart

      directly smart $ switch
        [smartSuccess, smartFailure, timeout ssplTimeout down]

      setPhaseIf smartSuccess onSmartSuccess $ \_ -> do
        Just (sdev, _, _) <- get Local
        markResetComplete sdev
        markSMARTTestComplete sdev
        markResetComplete sdev
#ifdef USE_MERO
        sd <- lookupStorageDeviceSDev sdev
        forM_ sd $ \m0sdev ->
          updateDriveState m0sdev M0_NC_ONLINE
#endif
        continue end

      setPhaseIf smartFailure onSmartFailure $ \_ -> do
        Just (sdev, _, _) <- get Local
        markResetComplete sdev
        markSMARTTestComplete sdev
        markResetComplete sdev
#ifdef USE_MERO
        sd <- lookupStorageDeviceSDev sdev
        forM_ sd $ \m0sdev -> do
          updateDriveState m0sdev M0_NC_FAILED
          updateDriveManagerWithFailure sdev
          pools <- getSDevPools m0sdev
          traverse_ startRepairOperation pools
#endif
        continue end

      directly end $ do
        Just (sdev, _, uid) <- get Local
        setDiskPowerOffAttempts sdev 0
        setDiskPowerOnAttempts sdev 0
        messageProcessed uid
        stop

      start home Nothing

    -- Removing drive:
    -- We need to notify mero about drive state change and then send event to the logger.
    defineSimple "drive-removed" $ \(DriveRemoved uuid (HA.Resources.Node nid) enc disk) -> do
      let msg = InterestingEventMessage
              $  "Drive was removed: \n\t"
               <> pack (show enc)
               <> "\n\t"
               <> pack (show disk)
      markStorageDeviceRemoved disk
#ifdef USE_MERO
      sd <- lookupStorageDeviceSDev disk
      forM_ sd $ \m0sdev -> do
        updateDriveState m0sdev M0_NC_TRANSIENT
        msa <- getSpielAddress
        forM_ msa $ \_ -> -- verify that info about mero exists.
          (void $ withSpielRC $ \sp -> withRConfRC sp $
             liftIO $ Spiel.deviceDetach sp (d_fid m0sdev))
            `catch` (\e -> phaseLog "mero" $ "failure in spiel: " ++ show (e::SomeException))
#endif
      syncGraph
      sendInterestingEvent nid msg
      messageProcessed uuid

    -- Inserting new drive
    define "drive-inserted" $ do
      handle     <- phaseHandle "drive-inserted"
      format_add <- phaseHandle "handle-sync"
      commit     <- phaseHandle "commit"

      setPhase handle $ \(DriveInserted uuid disk sn) -> do
        -- Check if we already have device that was inserted.
        -- In case it this is the same device, then we do not need to update confd.
        hasStorageDeviceIdentifier disk sn >>= \case
           True -> do
             put Local $ Just (uuid, uuid, disk)
             continue commit
           False -> do
             lookupStorageDeviceReplacement disk >>= \case
               Nothing -> do
                 phaseLog "warning" "No PHI information about new drive, skipping request for now"
                 markStorageDeviceWantsReplacement disk sn
                 syncGraph
                 messageProcessed uuid
               Just cand -> do
                 actualizeStorageDeviceReplacement cand
                 syncGraph
#ifdef USE_MERO
                 -- XXX: implement internal notification mechanism about
                 -- end of the sync. It's also nice to not redo this operation
                 -- if possible.
                 request <- liftIO $ nextRandom
                 put Local $ Just (uuid, request, disk)
                 selfMessage (request, SyncToConfdServersInRG)
                 continue format_add
#else
                 continue commit
#endif

      setPhase format_add $ \(SyncComplete request) -> do
        Just (_, req, _disk) <- get Local
        when (req /= request) $ continue format_add
        continue commit

      directly commit $ do
        Just (uuid, _, disk) <- get Local
#ifdef USE_MERO
        -- XXX: if mero is not ready then we should not unmark disk, I suppose?
        sd <- lookupStorageDeviceSDev disk
        forM_ sd $ \m0sdev -> do
          msa <- getSpielAddress
          forM_ msa $ \_ -> do
            _ <- withSpielRC $ \sp -> withRConfRC sp $
               liftIO $ Spiel.deviceAttach sp (d_fid m0sdev)
            updateDriveState m0sdev M0_NC_ONLINE
#endif
        unmarkStorageDeviceRemoved disk
        syncGraph
        messageProcessed uuid

      start handle Nothing

    -- Mark drive as failed
    defineSimple "drive-failed" $ \(DriveFailed uuid (HA.Resources.Node nid) enc disk) -> do
      let msg = InterestingEventMessage
              $  "Drive powered off: \n\t"
               <> pack (show enc)
               <> "\n\t"
               <> pack (show disk)
      sendInterestingEvent nid msg
      messageProcessed uuid

    -- Handle new mero node connection and try to start mero service on that node.
    -- Once mero service is started we add relevant information to RG and sync confd.
    -- If there is not enough information in place to proceed (for example there is
    -- no confd host information, or there is no Halon node running on that code),
    -- then message got discarded. Each entity that could add that information should
    -- emit 'NewMeroClient' event.
    define "new-mero-client" $ do
      new_client  <- phaseHandle "initial"
      client_info <- phaseHandle "update-client-info"
      sync_client <- phaseHandle "sync-client"

      -- Check if host is already provisioned and just ack message in that case.
      let provisionMeroClient eid host f =
           liftA2 (||) (hasHostAttr HA_M0CLIENT host)
                       (hasHostAttr HA_M0SERVER host) >>= \case
              True -> do phaseLog "info" $ show host ++ " is already processed."
                         messageProcessed eid
              False -> f

      -- Receive event about new client that have connected to cluster.
      -- Check if we need to continue provision process.
      setPhase new_client $ \(HAEvent eid (NewMeroClient node) _) -> do
         host <- do
           mhost <- findNodeHost node
           case mhost of
             Just host -> return host
             Nothing -> do
               -- impossible path, as RC setup host in
               -- prior to sending NewMeroClient, we can't do
               -- much about it - just send log and process message.
               phaseLog "error" $ "Can't find host for node " ++ show node
               messageProcessed eid
               continue new_client
         provisionMeroClient eid host $ do
           rg <- getLocalGraph
           let attrs = G.connectedTo host Has rg
               memsize = listToMaybe
                 $ mapMaybe (\x -> case x of HA_MEMSIZE_MB m -> Just m ; _ -> Nothing)
                 $ attrs
               cpucount = listToMaybe
                 $ mapMaybe (\x -> case x of HA_CPU_COUNT m -> Just m ; _ -> Nothing)
                 $ attrs
           put Local $ Just (eid, host, node, liftA2 (,) memsize cpucount)
           continue sync_client

      setPhase client_info $ \(HAEvent uuid (ClientInfo nid memsize cpucnt) _) -> do
        Just (eid, host, node, _) <- get Local
        messageProcessed uuid
        provisionMeroClient eid host $ do
          setHostAttr host $ HA_MEMSIZE_MB memsize
          setHostAttr host $ HA_CPU_COUNT cpucnt
          put Local $ Just (eid, host, node, Just (memsize, cpucnt))
          if nid == node
             then continue sync_client
             else continue client_info

      directly sync_client $ do
        Just (eid, host, node@(Node nid), minfo) <- get Local
        -- Check that we have loaded all required node information.
        _meminfo <- case minfo of
           Nothing -> do
             liftProcess $ void $ spawnLocal $ do
               _ <- spawnAsync nid $ $(mkClosure 'getUserSystemInfo) node
               return ()
             continue client_info
           Just mc -> return mc
        -- Check that we have loaded initial configuration.
#ifdef USE_MERO
        let (Host ip) = host
        fs <- getFilesystem >>= \case
                Nothing -> do
                  phaseLog "warning" "Configuration data was not loaded yet, skipping"
                  messageProcessed eid
                  continue new_client
                Just fs -> return fs
        -- Start mero service
        liftProcess $
          promulgateWait $ encodeP $ ServiceStartRequest Start (Node nid) m0d
            (MeroConf (ip ++ haAddress) (ip ++ rmsAddress)) []
#endif
        -- Update RG
        modifyLocalGraph $ \rg -> do
#ifdef USE_MERO
          let (memsize, cpucnt) = _meminfo
              memsize' = fromIntegral memsize
          -- Check if node is already defined in RG
          m0node <- case listToMaybe [ n | (c :: M0.Controller) <- G.connectedFrom M0.At host rg
                                         , (n :: M0.Node) <- G.connectedFrom M0.IsOnHardware c rg
                                         ] of
            Just nd -> return nd
            Nothing -> M0.Node <$> newFid (Proxy :: Proxy M0.Node)
          -- Check if process is already defined in RG
          let mprocess = listToMaybe
                $ filter (\(M0.Process _ _ _ _ _ _ a) -> a == ip ++ rmsAddress)
                $ G.connectedTo m0node M0.IsParentOf rg
          process <- case mprocess of
            Just process -> return process
            Nothing -> M0.Process <$> newFid (Proxy :: Proxy M0.Process)
                                  <*> pure memsize'
                                  <*> pure memsize'
                                  <*> pure memsize'
                                  <*> pure memsize'
                                  <*> pure (bitmapFromArray (replicate cpucnt True))
                                  <*> pure (ip ++ rmsAddress)
          -- Check if RMS service is already defined in RG
          let mrmsService = listToMaybe
                $ filter (\(M0.Service _ x _ _) -> x == CST_RMS)
                $ G.connectedTo process M0.IsParentOf rg
          rmsService <- case mrmsService of
            Just service -> return service
            Nothing -> M0.Service <$> newFid (Proxy :: Proxy M0.Service)
                                  <*> pure CST_RMS
                                  <*> pure [ip ++ rmsAddress]
                                  <*> pure SPUnused
          -- Check if HA service is already defined in RG
          let mhaService = listToMaybe
                $ filter (\(M0.Service _ x _ _) -> x == CST_HA)
                $ G.connectedTo process M0.IsParentOf rg
          haService <- case mhaService of
            Just service -> return service
            Nothing -> M0.Service <$> newFid (Proxy :: Proxy M0.Service)
                                  <*> pure CST_HA
                                  <*> pure [ip ++ haAddress]
                                  <*> pure SPUnused
          -- Create graph
          let rg' = G.newResource m0node
                >>> G.newResource process
                >>> G.newResource rmsService
                >>> G.newResource haService
                >>> G.connect m0node M0.IsParentOf process
                >>> G.connect process M0.IsParentOf rmsService
                >>> G.connect process M0.IsParentOf haService
                >>> G.connect fs M0.IsParentOf m0node
                >>> G.connect host Has HA_M0CLIENT
                  $ rg
#else
          let rg' = G.connect host Has HA_M0CLIENT rg
#endif
          return rg'
        syncGraph
        -- It's on if we will never receive reply, we already know that
        -- graph was synchronized and we will eventually sync to confd
#ifdef USE_MERO
        liftProcess $ promulgateWait SyncToConfdServersInRG
#endif
        messageProcessed eid
        publish $ NewMeroClientProcessed host

      start new_client Nothing

  where
    goRack (CI.Rack{..}) = let rack = Rack rack_idx in do
      registerRack rack
      mapM_ (goEnc rack) rack_enclosures
    goEnc rack (CI.Enclosure{..}) = let
        enclosure = Enclosure enc_id
      in do
        registerEnclosure rack enclosure
        mapM_ (registerBMC enclosure) enc_bmc
        mapM_ (goHost enclosure) enc_hosts
    goHost enc (CI.Host{..}) = let
        host = Host h_fqdn
        mem = fromIntegral h_memsize
        cpucount = fromIntegral h_cpucount
        attrs = [HA_MEMSIZE_MB mem, HA_CPU_COUNT cpucount]
      in do
        registerHost host
        locateHostInEnclosure host enc
        mapM_ (setHostAttr host) attrs
        mapM_ (registerInterface host) h_interfaces
