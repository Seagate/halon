{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DoAndIfThenElse       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE FlexibleInstances     #-}
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
import HA.RecoveryCoordinator.Actions.Service (lookupRunningService)
import HA.RecoveryCoordinator.Events.Drive

import HA.Resources
import HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.ResourceGraph as G
import HA.Services.SSPL
#ifdef USE_MERO
import Control.Applicative
import Control.Category ((>>>))
import HA.Resources.TH
import HA.EventQueue.Producer
import HA.Services.Mero
import HA.Services.Mero.CEP (meroChannel)
import qualified Mero.Spiel as Spiel
import HA.RecoveryCoordinator.Actions.Mero
import HA.RecoveryCoordinator.Actions.Mero.Failure
import HA.RecoveryCoordinator.Rules.Castor.SpielQuery
import HA.Resources.Mero hiding (Enclosure, Node, Process, Rack, Process)
import HA.Resources.Mero.Note
import qualified HA.Resources.Mero as M0
import HA.RecoveryCoordinator.Events.Mero
import HA.RecoveryCoordinator.Rules.Castor.Server
import Mero.Notification hiding (notifyMero)
import Mero.Notification.HAState (Note(..))
import Control.Exception (SomeException)
import Data.UUID.V4 (nextRandom)
import Data.Proxy (Proxy(..))
import System.Posix.SysInfo
import Data.Hashable
import Control.Distributed.Process.Closure (mkClosure)
#endif
import Data.Foldable


import Control.Monad
import Data.Maybe
import Data.Binary (Binary)
import Data.Monoid ((<>))
import Data.Text (Text, pack)
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Network.CEP
import Prelude hiding (id)

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
castorRules = sequence_
  [ ruleInitialDataLoad
#ifdef USE_MERO
  , ruleMeroNoteSet
  , ruleGetEntryPoint
  , ruleNewMeroClient
  , ruleNewMeroServer
#endif
  , ruleResetAttempt
  , ruleDriveFailed
  , ruleDriveRemoved
  , ruleDriveInserted
  ]

ruleInitialDataLoad :: Definitions LoopState ()
ruleInitialDataLoad = defineSimple "Initial-data-load" $ \(HAEvent eid CI.InitialData{..} _) -> do
      mapM_ goRack id_racks
      syncGraphBlocking
#ifdef USE_MERO
      filesystem <- initialiseConfInRG
      loadMeroGlobals id_m0_globals
      loadMeroServers filesystem id_m0_servers
      graph <- getLocalGraph
      syncGraphBlocking
      Just strategy <- getCurrentStrategy
      let update = onInit strategy graph
      forM_ update $ \updateGraph -> do
        graph' <- updateGraph $ \rg -> do
          putLocalGraph rg
          syncGraphBlocking
          getLocalGraph
        putLocalGraph graph'
        syncGraphBlocking
      (if isJust update then liftProcess else syncGraph) $
        say "Loaded initial data"
#else
      syncGraph $ say "Loaded initial data"
#endif
#ifdef USE_MERO
      rg' <- getLocalGraph
      let clientHosts =
            [ host | host <- G.getResourcesOfType rg'    :: [Host] -- all hosts
                   , not  $ G.isConnected host Has HA_M0CLIENT rg' -- and not already a client
                   , not  $ G.isConnected host Has HA_M0SERVER rg' -- and not already a server
                   ]

          hostsToNodes = mapMaybe (\h -> listToMaybe $ G.connectedTo h Runs rg')
          serverHosts = [ host | host <- G.getResourcesOfType rg' :: [Host]
                               , G.isConnected host Has HA_M0SERVER rg' ]

          serverNodes = hostsToNodes serverHosts
          clientNodes = hostsToNodes clientHosts
      phaseLog "post-initial-load" $ "Sending messages about these new mero nodes: "
                                  ++ show ((clientNodes, clientHosts), (serverNodes, serverHosts))
      forM_ clientNodes $ liftProcess . promulgateWait . NewMeroClient
      forM_ serverNodes $ liftProcess . promulgateWait . NewMeroServer
#endif
      messageProcessed eid


#ifdef USE_MERO
ruleMeroNoteSet :: Definitions LoopState ()
ruleMeroNoteSet = do
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
                      updateDriveManagerWithFailure Nothing sdev
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
                      promulgateRC $ ResetAttempt sdev

                    syncGraph $ say "mero-note-set synchronized"
                _ -> do
                  phaseLog "warning" $ "Cannot find all entities attached to M0"
                                    ++ " storage device: "
                                    ++ show m0sdev
                                    ++ ": "
                                    ++ show msdev
          M0_NC_ONLINE -> lookupConfObjByFid mfid >>= \case
            Nothing -> return ()
            Just pool -> getPoolRepairStatus pool >>= \case
              Nothing -> phaseLog "warning" $ "Got M0_NC_ONLINE for a pool but "
                                           ++ "no pool repair status was found."
              Just (M0.PoolRepairStatus prt _)
                | prt == M0.Rebalance -> do
                phaseLog "repair" $ "Got M0_NC_ONLINE for a pool that is rebalancing."
                queryStartHandling pool prt
              _ -> phaseLog "repair" $ "Got M0_NC_ONLINE but pool is repairing now."
          M0_NC_REPAIRED -> lookupConfObjByFid mfid >>= \case
            Nothing -> return ()
            Just pool -> getPoolRepairStatus pool >>= \case
              Nothing -> phaseLog "warning" $ "Got M0_NC_REPAIRED for a pool but "
                                           ++ "no pool repair status was found."
              Just (M0.PoolRepairStatus prt _)
                | prt == M0.Failure -> do
                phaseLog "repair" $ "Got M0_NC_REPAIRED for a pool that is repairing."
                queryStartHandling pool prt
              _ -> phaseLog "repair" $ "Got M0_NC_REPAIRED but pool is rebalancing now."

          _ -> return ()
      messageProcessed uid

    querySpiel
    querySpielHourly
#endif

ruleResetAttempt :: Definitions LoopState ()
ruleResetAttempt = define "reset-attempt" $ do
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
            updateDriveManagerWithFailure Nothing sdev
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
            updateDriveManagerWithFailure Nothing sdev
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
          updateDriveManagerWithFailure Nothing sdev
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


data CommitDriveRemoved = CommitDriveRemoved NodeId InterestingEventMessage UUID
  deriving (Typeable, Generic)

instance Binary CommitDriveRemoved

-- | Removing drive:
-- We need to notify mero about drive state change and then send event to the logger.
ruleDriveRemoved :: Definitions LoopState ()
ruleDriveRemoved = define "drive-removed" $ do
   pinit   <- phaseHandle "init"
   pcommit <- phaseHandle "commit"
   setPhase pinit $ \(DriveRemoved uuid (HA.Resources.Node nid) enc disk) -> do
      let msg = InterestingEventMessage
              $  "Drive was removed: \n\t"
               <> pack (show enc)
               <> "\n\t"
               <> pack (show disk)
      markStorageDeviceRemoved disk
#ifdef USE_MERO
      sd <- lookupStorageDeviceSDev disk
      phaseLog "debug" $ "Associated storage device: " ++ show sd
      forM_ sd $ \m0sdev -> do
        phaseLog "mero" $ "Notifying M0_NC_TRANSIENT for device."
        updateDriveState m0sdev M0_NC_TRANSIENT
        msa <- getSpielAddressRC
        forM_ msa $ \_ -> -- verify that info about mero exists.
          (void $ withSpielRC $ \sp -> withRConfRC sp $
             liftIO $ Spiel.deviceDetach sp (d_fid m0sdev))
            `catch` (\e -> phaseLog "mero" $ "failure in spiel: " ++ show (e::SomeException))
#endif
      syncGraphProcess $ \self -> do
        usend self (CommitDriveRemoved nid msg uuid)
      continue pcommit

   setPhase pcommit $ \(CommitDriveRemoved nid msg uuid) -> do
      sendInterestingEvent nid msg
      messageProcessed uuid
   start pinit ()

-- | Inserting new drive
ruleDriveInserted :: Definitions LoopState ()
ruleDriveInserted = define "drive-inserted" $ do
      handle     <- phaseHandle "drive-inserted"
#ifdef USE_MERO
      format_add <- phaseHandle "handle-sync"
#endif
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
                 syncGraphProcessMsg uuid
               Just cand -> do
                 actualizeStorageDeviceReplacement cand
#ifdef USE_MERO
                 -- XXX: implement internal notification mechanism about
                 -- end of the sync. It's also nice to not redo this operation
                 -- if possible.
                 request <- liftIO $ nextRandom
                 put Local $ Just (uuid, request, disk)
                 syncGraphProcess $ \self -> do
                   usend self (request, SyncToConfdServersInRG)
                 continue format_add
#else
                 syncGraph $ return ()
                 continue commit
#endif

#ifdef USE_MERO
      setPhase format_add $ \(SyncComplete request) -> do
        Just (_, req, _disk) <- get Local
        when (req /= request) $ continue format_add
        continue commit
#endif

      directly commit $ do
        Just (uuid, _, disk) <- get Local
#ifdef USE_MERO
        -- XXX: if mero is not ready then we should not unmark disk, I suppose?
        sd <- lookupStorageDeviceSDev disk
        forM_ sd $ \m0sdev -> do
          msa <- getSpielAddressRC
          forM_ msa $ \_ -> do
            _ <- withSpielRC $ \sp -> withRConfRC sp $
               liftIO $ Spiel.deviceAttach sp (d_fid m0sdev)
            pools <- getSDevPools m0sdev
            traverse_ startRebalanceOperation pools
#endif
        unmarkStorageDeviceRemoved disk
        syncGraphProcessMsg uuid

      start handle Nothing

-- | Mark drive as failed
ruleDriveFailed :: Definitions LoopState ()
ruleDriveFailed = defineSimple "drive-failed" $ \(DriveFailed uuid (HA.Resources.Node nid) enc disk) -> do
      let msg = InterestingEventMessage
              $  "Drive powered off: \n\t"
               <> pack (show enc)
               <> "\n\t"
               <> pack (show disk)
      sendInterestingEvent nid msg
      messageProcessed uuid

#ifdef USE_MERO
-- | New mero client rule is capable provisioning new mero client.
-- In order to do that following steps are applies:
--   1. for each new connected node 'NewMeroClient' message is emitted by 'ruleNodeUp'.
--   2. for each new client that is known to be mero-client, but have no confd information,
--      that information is generated and synchronized with confd servers
--   3. once confd have all required information available start mero service on the node,
--      that will lead provision process.
--
-- Once host is provisioned 'NewMeroClient' event is published
ruleNewMeroClient :: Definitions LoopState ()
ruleNewMeroClient = define "new-mero-client" $ do
    mainloop <- phaseHandle "mainloop"
    msgNewMeroClient <- phaseHandle "new-mero-client"
    msgClientInfo    <- phaseHandle "client-info-update"
    msgClientStoreInfo <- phaseHandle "client-store-update"
    msgClientNodeBootstrapped <- phaseHandle "node-provisioned"
    svc_up_now <- phaseHandle "svc_up_now"
    svc_up_already <- phaseHandle "svc_up_already"

    directly mainloop $
      switch [ msgNewMeroClient
             , msgClientInfo
             , msgClientStoreInfo
             , msgClientNodeBootstrapped
             ]

    setPhase msgNewMeroClient $ \(HAEvent eid (NewMeroClient node@(Node nid)) _) -> do
       mhost <- findNodeHost node
       case mhost of
         Just host -> do
           isServer <- hasHostAttr HA_M0SERVER host
           isClient <- hasHostAttr HA_M0CLIENT host
           mlnid    <- listToMaybe . G.connectedTo host Has <$> getLocalGraph
           case mlnid of
             -- Host is a server, bootstrap is done in a separate procedure.
             _ | isServer -> do
                   phaseLog "info" $ show host ++ " is mero server, skipping provision"
                   messageProcessed eid
             -- Host is client with all required info beign loaded .
             Just LNid{}
               | isClient -> do
                   phaseLog "info" $ show host ++ " is mero client. Configuration was generated - starting mero service"
                   startMeroService host node
                   messageProcessed eid
             -- Host is client but not all information was loaded.
             _  -> do
                   phaseLog "info" $ show host ++ " is mero client. No configuration - generating"
                   startMeroClientProvisioning host eid
                   getProvisionHardwareInfo host >>= \case
                     Nothing -> do
                       liftProcess $ void $ spawnLocal $
                         void $ spawnAsync nid $ $(mkClosure 'getUserSystemInfo) node
                     Just info -> selfMessage (NewClientStoreInfo host info)
         Nothing -> do
           phaseLog "error" $ "Can't find host for node " ++ show node
           messageProcessed eid

    setPhase msgClientInfo $ \(HAEvent eid (SystemInfo nid info) _) -> do
      phaseLog "info" $ "Recived information about " ++ show nid
      mhost <- findNodeHost nid
      case mhost of
        Just host -> do
          putProvisionHardwareInfo host info
          syncGraphProcessMsg eid
          selfMessage $ NewClientStoreInfo host info
        Nothing -> do
          phaseLog "error" $ "Received information from node on unknown host " ++ show nid
          messageProcessed eid

    setPhase msgClientStoreInfo $ \(NewClientStoreInfo host info) -> do
       getFilesystem >>= \case
          Nothing -> do
            phaseLog "warning" "Configuration data was not loaded yet, skipping"
          Just fs -> do
            (node:_) <- nodesOnHost host
            createMeroClientConfig fs host info
            startMeroService host node
            -- TODO start m0t1fs
            put Local $ Just (node, host)
            switch [svc_up_now, timeout 5000000 svc_up_already]

    setPhaseIf svc_up_now onNode $ \(host, chan) -> do
      -- Legitimate to avoid the event id as it should be handled by the default
      -- 'declare-mero-channel' rule.
      startNodeProcesses host chan PLM0t1fs False

    -- Service is already up
    directly svc_up_already $ do
      Just (node, _) <- get Local
      rg <- getLocalGraph
      m0svc <- lookupRunningService node m0d
      mhost <- findNodeHost node
      case (,) <$> mhost <*> (m0svc >>= meroChannel rg) of
        Just (host, chan) -> do
          startNodeProcesses host chan PLConfdBoot True
        Nothing -> switch [svc_up_now, timeout 5000000 svc_up_already]

    setPhase msgClientNodeBootstrapped $ \(HAEvent eid (ProcessControlResultMsg node _) _) -> do
       finishMeroClientProvisioning node
       messageProcessed eid

    start mainloop Nothing
  where
    startMeroClientProvisioning host uuid =
      modifyLocalGraph $ \rg -> do
        let pp  = ProvisionProcess host
            rg' = G.newResource pp
              >>> G.connect pp OnHost host
              >>> G.connect pp TriggeredBy uuid
                $ rg
        return rg'

    finishMeroClientProvisioning nid = do
      rg <- getLocalGraph
      let mpp = listToMaybe
                  [ pp | host <- G.connectedFrom Runs (Node nid) rg :: [Host]
                       , pp <- G.connectedFrom OnHost host rg :: [ProvisionProcess]
                       ]
      forM_ mpp $ \pp -> do
        let uuids = G.connectedTo pp TriggeredBy rg :: [UUID]
        forM_ uuids messageProcessed
        modifyGraph $ G.disconnectAllFrom pp OnHost (Proxy :: Proxy Host)
                  >>> G.disconnectAllFrom pp TriggeredBy (Proxy :: Proxy UUID)

    getProvisionHardwareInfo host = do
       let pp = ProvisionProcess host
       rg <- getLocalGraph
       return . listToMaybe $ (G.connectedTo pp Has rg :: [HostHardwareInfo])
    putProvisionHardwareInfo host info = do
       let pp = ProvisionProcess host
       modifyGraph $ G.connectUnique pp Has (info :: HostHardwareInfo)
       publish $ NewMeroClientProcessed host

    onNode _ _ Nothing = return Nothing
    onNode (HAEvent _ (DeclareMeroChannel sp _ cc) _) ls (Just (node, _)) =
      let
        rg = lsGraph ls
        mhost = G.connectedFrom Runs node rg
        rightNode = G.isConnected node Runs sp rg
      in case (rightNode, mhost) of
        (True, [host]) -> return $ Just (host, cc)
        (_, _) -> return Nothing
#endif

#ifdef USE_MERO
-- | Load information that is required to complete transaction from
-- resource graph.
ruleGetEntryPoint :: Definitions LoopState ()
ruleGetEntryPoint = defineSimple "castor-entry-point-request" $
  \(HAEvent uuid (GetSpielAddress pid) _) -> do
    phaseLog "info" $ "Spiel Address requested by " ++ show pid
    liftProcess . usend pid =<< getSpielAddressRC
    messageProcessed uuid
#endif

goRack :: CI.Rack -> PhaseM LoopState l ()
goRack (CI.Rack{..}) = let rack = Rack rack_idx in do
  registerRack rack
  mapM_ (goEnc rack) rack_enclosures

goEnc :: Rack -> CI.Enclosure -> PhaseM LoopState l ()
goEnc rack (CI.Enclosure{..}) = let
    enclosure = Enclosure enc_id
  in do
    registerEnclosure rack enclosure
    mapM_ (registerBMC enclosure) enc_bmc
    mapM_ (goHost enclosure) enc_hosts

goHost :: Enclosure -> CI.Host -> PhaseM LoopState l ()
goHost enc (CI.Host{..}) = let
    host = Host h_fqdn
    mem = fromIntegral h_memsize
    cpucount = fromIntegral h_cpucount
    attrs = [HA_MEMSIZE_MB mem, HA_CPU_COUNT cpucount, HA_M0SERVER]
  in do
    registerHost host
    locateHostInEnclosure host enc
    mapM_ (setHostAttr host) attrs
    mapM_ (registerInterface host) h_interfaces

#ifdef USE_MERO
data CommitNewMeroClient = CommitNewMeroClient Host UUID
  deriving (Eq, Show, Typeable, Generic)
instance Binary CommitNewMeroClient

data NewClientStoreInfo = NewClientStoreInfo Host HostHardwareInfo
  deriving (Eq, Show, Typeable, Generic)
instance Binary NewClientStoreInfo

data OnHost = OnHost
  deriving (Eq, Show, Typeable,Generic)
instance Binary OnHost
instance Hashable OnHost

data TriggeredBy = TriggeredBy
  deriving (Eq, Show, Typeable, Generic)
instance Binary TriggeredBy
instance Hashable TriggeredBy

data ProvisionProcess = ProvisionProcess Host
  deriving (Eq, Show, Typeable, Generic)
instance Binary ProvisionProcess
instance Hashable ProvisionProcess

$(mkDicts
  [ ''OnHost, ''ProvisionProcess ]
  [ (''ProvisionProcess, ''OnHost, ''Host)
  , (''ProvisionProcess, ''TriggeredBy, ''UUID)
  , (''ProvisionProcess, ''Has, ''HostHardwareInfo)
  ]
  )

$(mkResRel
  [ ''OnHost, ''ProvisionProcess ]
  [ (''ProvisionProcess, ''OnHost, ''Host)
  , (''ProvisionProcess, ''TriggeredBy, ''UUID)
  , (''ProvisionProcess, ''Has, ''HostHardwareInfo)
  ] [])
#endif
