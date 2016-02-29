{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DoAndIfThenElse       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TupleSections         #-}
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

import HA.Resources
import HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.ResourceGraph as G
import HA.Services.SSPL
import HA.RecoveryCoordinator.Rules.Castor.Reset
#ifdef USE_MERO
import Control.Applicative
import Control.Category ((>>>))
import HA.Resources.TH
import HA.EventQueue.Producer
import HA.Services.Mero
import HA.Services.Mero.CEP (meroChannel)
import HA.Services.SSPL.CEP (updateDriveManagerWithFailure)
import HA.RecoveryCoordinator.Actions.Service (lookupRunningService)
import qualified Mero.Spiel as Spiel
import HA.RecoveryCoordinator.Actions.Mero
import HA.RecoveryCoordinator.Actions.Mero.Failure
import HA.RecoveryCoordinator.Rules.Castor.Repair
import HA.Resources.Mero hiding (Enclosure, Node, Process, Rack, Process)
import qualified HA.Resources.Mero as M0
import HA.Resources.Mero.Note
import HA.RecoveryCoordinator.Events.Mero
import HA.RecoveryCoordinator.Rules.Castor.Server
import Mero.Notification hiding (notifyMero)
import Mero.Notification.HAState (Note(..))
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

lookupStorageDevicePathsInGraph :: StorageDevice -> G.Graph -> [String]
lookupStorageDevicePathsInGraph sd g =
    mapMaybe extractPath $ ids
  where
    ids = G.connectedTo sd Has g
    extractPath (DIPath x) = Just x
    extractPath _ = Nothing

-- | Time to allow for SSPL reply on a smart test request.
smartTestTimeout :: Int
smartTestTimeout = 15*60


-- | States of the Timeout rule.OB
data TimeoutState = TimeoutNormal | ResetAttemptSent

onCommandAck :: (Text -> NodeCmd)
           -> HAEvent CommandAck
           -> g
           -> Maybe (StorageDevice, Text, Node, UUID)
           -> Process (Maybe UUID)
onCommandAck _ _ _ Nothing = return Nothing
onCommandAck k (HAEvent eid cmd _) _ (Just (_, serial, _, _)) =
  case commandAckType cmd of
    Just x | (k serial) == x -> return $ Just eid
           | otherwise       -> return Nothing
    _ -> return Nothing

onSmartSuccess :: HAEvent CommandAck
               -> g
               -> Maybe (StorageDevice, Text, Node, UUID)
               -> Process (Maybe UUID)
onSmartSuccess (HAEvent eid cmd _) _ (Just (_, serial, _, _)) =
    case commandAckType cmd of
      Just (SmartTest x)
        | serial == x ->
          case commandAck cmd of
            AckReplyPassed -> return $ Just eid
            _              -> return Nothing
        | otherwise -> return Nothing
      _ -> return Nothing
onSmartSuccess _ _ _ = return Nothing

onSmartFailure :: HAEvent CommandAck
               -> g
               -> Maybe (StorageDevice, Text, Node, UUID)
               -> Process (Maybe UUID)
onSmartFailure (HAEvent eid cmd _) _ (Just (_, serial, _, _)) =
    case commandAckType cmd of
      Just (SmartTest x)
        | serial == x ->
          case commandAck cmd of
            AckReplyFailed  -> return $ Just eid
            AckReplyError _ -> return $ Just eid
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
  defineSimple "mero-note-set" $ \(HAEvent uid noteSet _) -> do
    handleNotes noteSet
    messageProcessed uid

  querySpiel
  querySpielHourly

-- | Extract information about drives from the given set of
-- notifications and update the state in RG accordingly.
updateDriveStates :: Set -> PhaseM LoopState l ()
updateDriveStates (Set ns) = catMaybes <$> mapM noteToSDev ns
                             >>= mapM_ (\(typ, sd) -> updateDriveState sd typ)

handleNotes :: Set -> PhaseM LoopState l ()
handleNotes noteSet = do
  -- Before we do anything else, write the state of the drives into
  -- the RG so that rest of the rule can query updated info
  updateDriveStates noteSet

  -- Progress repair based on the messages
  handleRepair noteSet

-- | Notify ourselves about a state change of the 'M0.SDev'.
--
-- Internally, build a note 'Set' and pass it it 'handleNotes' which
-- will both set the new state and decide what to do with respect to
-- repair and any other rules that need to act on state changes.
--
-- It's important to understand that this function does not replace
-- 'updateDriveState' which performs the actual update, it simply
-- tells 'handleNotes' to deal with it, which for 'M0.SDev' sets the
-- state.
notifyDriveStateChange :: M0.SDev -> ConfObjectState -> PhaseM LoopState l ()
notifyDriveStateChange m0sdev st = handleNotes (Set [Note (M0.fid m0sdev) st])
#endif

ruleResetAttempt :: Definitions LoopState ()
ruleResetAttempt = define "reset-attempt" $ do
      home          <- phaseHandle "home"
      reset         <- phaseHandle "reset"
      resetComplete <- phaseHandle "reset-complete"
      smart         <- phaseHandle "smart"
      smartSuccess  <- phaseHandle "smart-success"
      smartFailure  <- phaseHandle "smart-failure"
      failure       <- phaseHandle "failure"
      end           <- phaseHandle "end"

      setPhase home $ \(HAEvent uid (ResetAttempt sdev) _) -> fork NoBuffer $ do
        nodes <- getSDevNode sdev
        node <- case nodes of
          node:_ -> return node
          [] -> do
             -- XXX: send IEM message
             phaseLog "warning" $ "Can't perform query to SSPL as node can't be found"
             messageProcessed uid
             stop
        paths <- lookupStorageDeviceSerial sdev
        case paths of
          serial:_ -> do
            put Local (Just (sdev, pack serial, node, uid))
            unlessM (isStorageDevicePowered sdev) $
              switch [resetComplete, timeout driveResetTimeout failure]
            whenM (isStorageDeviceRunningSmartTest sdev) $
              switch [smartSuccess, smartFailure, timeout smartTestTimeout failure]
            markOnGoingReset sdev
            continue reset
          [] -> do
            -- XXX: send IEM message
            phaseLog "warning" $ "Cannot perform reset attempt for drive "
                              ++ show sdev
                              ++ " as it has no device paths associated."
            messageProcessed uid
            stop

      directly reset $ do
        Just (sdev, serial, Node nid, _) <- get Local
        i <- getDiskResetAttempts sdev
        if i <= resetAttemptThreshold
        then do
          incrDiskResetAttempts sdev
          sendNodeCmd nid Nothing (DriveReset serial)
          markDiskPowerOff sdev
          switch [resetComplete, timeout driveResetTimeout failure]
        else continue failure

      setPhaseIf resetComplete (onCommandAck DriveReset) $ \eid -> do
        Just (sdev, _, _, _) <- get Local
        markDiskPowerOn sdev
        markResetComplete sdev
        messageProcessed eid
        continue smart

      directly smart $ do
        Just (sdev, serial, Node nid, _) <- get Local
        markSMARTTestIsRunning sdev
        sendNodeCmd nid Nothing (SmartTest serial)
        switch [smartSuccess, smartFailure, timeout smartTestTimeout failure]

      setPhaseIf smartSuccess onSmartSuccess $ \eid -> do
        Just (sdev, _, _, _) <- get Local
        markSMARTTestComplete sdev
#ifdef USE_MERO
        sd <- lookupStorageDeviceSDev sdev
        forM_ sd $ \m0sdev ->
          notifyDriveStateChange m0sdev M0_NC_ONLINE
#endif
        messageProcessed eid
        continue end

      setPhaseIf smartFailure onSmartFailure $ \eid -> do
        Just (sdev, _, _, _) <- get Local
        markSMARTTestComplete sdev
        messageProcessed eid
        continue failure

      directly failure $ do
#ifdef USE_MERO
        Just (sdev, _, _, _) <- get Local
        sd <- lookupStorageDeviceSDev sdev
        forM_ sd $ \m0sdev -> do
          updateDriveManagerWithFailure sdev "HALON-FAILED" (Just "MERO-Timeout")
          -- Let note handler deal with repair logic
          notifyDriveStateChange m0sdev M0_NC_FAILED
#endif
        continue end

      directly end $ do
        Just (_, _, _, uid) <- get Local
        messageProcessed uid
        stop

      start home Nothing


data CommitDriveRemoved = CommitDriveRemoved NodeId InterestingEventMessage UUID
  deriving (Typeable, Generic)

instance Binary CommitDriveRemoved

driveRemovalTimeout :: Int
driveRemovalTimeout = 60

-- | Removing drive:
-- We need to notify mero about drive state change and then send event to the logger.
ruleDriveRemoved :: Definitions LoopState ()
ruleDriveRemoved = define "drive-removed" $ do
   pinit   <- phaseHandle "init"
#ifdef USE_MERO
   finish   <- phaseHandle "finish"
   reinsert <- phaseHandle "reinsert"
   removal  <- phaseHandle "removal"
#endif

   initWrapper pinit

   setPhase pinit $ \(DriveRemoved uuid _ _enc disk _loc) -> do
      markStorageDeviceRemoved disk
#ifdef USE_MERO
      sd <- lookupStorageDeviceSDev disk
      phaseLog "debug" $ "Associated storage device: " ++ show sd
      forM_ sd $ \m0sdev -> do
        fork CopyNewerBuffer $ do
          phaseLog "mero" $ "Notifying M0_NC_TRANSIENT for device."
          notifyDriveStateChange m0sdev M0_NC_TRANSIENT
          put Local $ Just (uuid, _enc, disk, _loc, m0sdev)
          switch [reinsert, timeout driveRemovalTimeout removal]
#else
      messageProcessed uuid
#endif

#ifdef USE_MERO
   setPhaseIf reinsert
     (\(DriveInserted _ disk _ loc) g (Just (uuid, enc', _, loc', _)) -> do
        if G.isConnected enc' Has disk (lsGraph g) && loc == loc'
           then return (Just uuid)
           else return Nothing
        )
     $ \uuid -> do
        phaseLog "debug" "cancel drive removal procedure"
        messageProcessed uuid
        continue finish

   directly finish $ stop

   directly removal $ do
     Just (uuid, _, _, _, m0sdev) <- get Local
     -- msa <- getSpielAddressRC
     -- forM_ msa $ \_ -> -- verify that info about mero exists.
     --   (void $ withSpielRC $ \sp -> withRConfRC sp $
     --      liftIO $ Spiel.deviceDetach sp (d_fid m0sdev))
     --     `catch` (\e -> phaseLog "mero" $ "failure in spiel: " ++ show (e::SomeException))
     notifyDriveStateChange m0sdev M0_NC_FAILED
     messageProcessed uuid
     stop
#endif

   start pinit Nothing
  where
    initWrapper ginit = do
       wrapper_init <- phaseHandle "wrapper_init"
       wrapper_clear <- phaseHandle "wrapper_clear"
       directly wrapper_init $ switch [ginit, wrapper_clear]

       directly wrapper_clear $ do
         fork NoBuffer $ continue wrapper_init
         stop


-- | Inserting new drive
ruleDriveInserted :: Definitions LoopState ()
ruleDriveInserted = define "drive-inserted" $ do
      handle     <- phaseHandle "drive-inserted"
#ifdef USE_MERO
      format_add <- phaseHandle "handle-sync"
#endif
      commit     <- phaseHandle "commit"

      setPhase handle $ \(DriveInserted uuid disk sn _) -> do
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
            -- Notify about drive coming up online: this will allow
            -- any repair to continue and rebalance to eventually
            -- start if nothing else goes wrong
            notifyDriveStateChange m0sdev M0_NC_ONLINE
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
          startNodeProcesses host chan (PLBootLevel 0) True
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
