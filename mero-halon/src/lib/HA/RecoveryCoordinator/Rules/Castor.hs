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
#ifdef USE_MERO
import Control.Applicative
import Control.Category ((>>>))
import HA.Resources.TH
import HA.EventQueue.Producer
import HA.Services.Mero
import HA.Services.Mero.CEP (meroChannel)
import HA.RecoveryCoordinator.Actions.Service (lookupRunningService)
import qualified Mero.Spiel as Spiel
import HA.RecoveryCoordinator.Actions.Mero
import HA.RecoveryCoordinator.Actions.Mero.Failure
import HA.RecoveryCoordinator.Rules.Castor.Repair
import HA.RecoveryCoordinator.Rules.Castor.Reset
import HA.Resources.Mero hiding (Enclosure, Node, Process, Rack, Process)
import qualified HA.Resources.Mero as M0
import HA.Resources.Mero.Note
import HA.RecoveryCoordinator.Events.Mero
import HA.RecoveryCoordinator.Rules.Castor.Server
import Mero.Notification hiding (notifyMero)
import Mero.Notification.HAState (Note(..))
import Data.UUID.V4 (nextRandom)
import qualified Data.UUID as UUID
import System.Posix.SysInfo
import Data.Hashable
import Control.Distributed.Process.Closure (mkClosure)
#endif
import Data.Proxy (Proxy(..))
import Data.Foldable


import Control.Monad
import Data.Maybe
import Data.Binary (Binary)
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

castorRules :: Definitions LoopState ()
castorRules = sequence_
  [ ruleInitialDataLoad
#ifdef USE_MERO
  , setStateChangeHandlers
  , ruleMeroNoteSet
  , ruleGetEntryPoint
  , ruleNewMeroClient
  , ruleNewMeroServer
  , ruleResetAttempt
#endif
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
      -- Pick a principal RM
      _ <- pickPrincipalRM
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

setStateChangeHandlers :: Definitions LoopState ()
setStateChangeHandlers = do
    define "set-state-change-handlers" $ do
      setThem <- phaseHandle "set"
      finish <- phaseHandle "finish"
      directly setThem $ do
        ls <- get Global
        put Global $ ls { lsStateChangeHandlers = stateChangeHandlers }
        continue finish

      directly finish stop

      start setThem Nothing
  where
    stateChangeHandlers = [
        updateDriveStatesFromSet
      , handleReset
      , handleRepair
      ]

ruleMeroNoteSet :: Definitions LoopState ()
ruleMeroNoteSet = do
  defineSimple "mero-note-set" $ \(HAEvent uid (Set ns) _) -> let
      resultState (Note f M0_NC_FAILED)
        | fidIsType (Proxy :: Proxy M0.SDev) f = Note f M0_NC_TRANSIENT
      resultState x = x
      noteSet = Set (resultState <$> ns)
    in do
      stateChangeHandlers <- lsStateChangeHandlers <$> get Global
      sequence_ $ (\x -> x noteSet) <$> stateChangeHandlers
      messageProcessed uid

  querySpiel
  querySpielHourly

#endif

data CommitDriveRemoved = CommitDriveRemoved NodeId InterestingEventMessage UUID
  deriving (Typeable, Generic)

instance Binary CommitDriveRemoved

#ifdef USE_MERO
driveRemovalTimeout :: Int
driveRemovalTimeout = 60

-- | Removing drive:
-- We need to notify mero about drive state change and then send event to the logger.
ruleDriveRemoved :: Definitions LoopState ()
ruleDriveRemoved = define "drive-removed" $ do
   pinit   <- phaseHandle "init"
   finish   <- phaseHandle "finish"
   reinsert <- phaseHandle "reinsert"
   removal  <- phaseHandle "removal"

   run <- initWrapper pinit

   setPhase pinit $ \(DriveRemoved uuid _ enc disk loc) -> do
      markStorageDeviceRemoved disk
      sd <- lookupStorageDeviceSDev disk
      phaseLog "debug" $ "Associated storage device: " ++ show sd
      forM_ sd $ \m0sdev -> do
        fork CopyNewerBuffer $ do
          phaseLog "mero" $ "Notifying M0_NC_TRANSIENT for device."
          notifyDriveStateChange m0sdev M0_NC_TRANSIENT
          put Local $ Just (uuid, enc, disk, loc, m0sdev)
          switch [reinsert, timeout driveRemovalTimeout removal]
      messageProcessed uuid

   setPhaseIf reinsert
     (\(DriveInserted{diEnclosure=enc,diDiskNum=loc}) _ (Just (uuid, enc', _, loc', _)) -> do
        if enc == enc' && loc == loc'
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
     notifyDriveStateChange m0sdev M0_NC_FAILED
     messageProcessed uuid
     stop

   start run Nothing
  where
    initWrapper ginit = do
       wrapper_init <- phaseHandle "wrapper_init"
       wrapper_clear <- phaseHandle "wrapper_clear"
       wrapper_end <- phaseHandle "wrapper_end"

       directly wrapper_init $ switch [ginit, wrapper_clear]

       directly wrapper_clear $ do
         fork NoBuffer $ continue ginit
         continue wrapper_end

       directly wrapper_end stop
       return wrapper_init
#else
ruleDriveRemoved :: Definitions LoopState ()
ruleDriveRemoved = defineSimple "drive-removed" $ \(DriveRemoved uuid _ _ disk _) -> do
  markStorageDeviceRemoved disk
  messageProcessed uuid
#endif

#if USE_MERO
driveInsertionTimeout :: Int
driveInsertionTimeout = 10

-- | Inserting new drive. Drive insertion rule gathers all information about new
-- drive and prepares drives for Repair/rebalance procedure.
-- This rule works as following:
--
-- 1. Wait for some timeout, to check if new events about this drive will not
--    arrive. If they do - cancel procedure.
--
-- 2. If this is a new device we update confd.
--
-- 3. Once confd is updated rule decide if we need to trigger repair/rebalance
--    procedure and does that.
ruleDriveInserted :: Definitions LoopState ()
ruleDriveInserted = define "drive-inserted" $ do
      handler       <- phaseHandle "drive-inserted"
      removed       <- phaseHandle "removed"
      inserted      <- phaseHandle "inserted"
      main          <- phaseHandle "main"
      sync_complete <- phaseHandle "handle-sync"
      commit        <- phaseHandle "commit"
      finish        <- phaseHandle "finish"

      pinit <- initWrapper handler

      setPhase handler $ \di -> do
        put Local $ Just (UUID.nil, di)
        fork CopyNewerBuffer $
           switch [ removed
                  , inserted
                  , timeout driveInsertionTimeout main]

      setPhaseIf removed
        (\(DriveRemoved _ _ enc _ loc) _
          (Just (_,DriveInserted{diUUID=uuid
                                ,diEnclosure=enc'
                                ,diDiskNum=loc'})) -> do
           if enc == enc' && loc == loc'
              then return (Just uuid)
              else return Nothing)
        $ \uuid -> do
            phaseLog "debug" "cancel drive insertion procedure due to drive removal."
            messageProcessed uuid
            continue finish

      -- If for some reason new Inserted event will be received during a timeout
      -- we need to cancel current procedure and allow new procedure to continue.
      -- Theoretically it's impossible case as before each insertion removal should
      -- go. However we add this case to cover scenario when other subsystems do not
      -- work perfectly and do not issue DriveRemoval first.
      setPhaseIf inserted
        (\(DriveInserted{diEnclosure=enc, diDiskNum=loc}) _
          (Just (_, DriveInserted{ diUUID=uuid
                                 , diEnclosure=enc'
                                 , diDiskNum=loc'})) -> do
            if enc == enc' && loc == loc'
               then return (Just uuid)
               else return Nothing)
        $ \uuid -> do
            phaseLog "info" "cancel drive insertion procedure due to new drive insertion."
            messageProcessed uuid
            continue finish

      directly main $ do
        Just (_, di@DriveInserted{ diUUID = uuid
                                 , diDevice = disk
                                 , diSerial = sn
                                 , diPath = path
                                 }) <- get Local
        -- Check if we already have device that was inserted.
        -- In case it this is the same device, then we do not need to update confd.
        hasStorageDeviceIdentifier disk sn >>= \case
           True -> do
             let markIfNotMeroFailure = do
                   let isMeroFailure (StorageDeviceStatus "MERO-FAILED" _) = True
                       isMeroFailure _ = False
                   meroFailure <- maybe False isMeroFailure <$> driveStatus disk
                   if meroFailure
                     then messageProcessed uuid
                     else markStorageDeviceReplaced disk
             unmarkStorageDeviceRemoved disk
             msdev <- lookupStorageDeviceSDev disk
             forM_ msdev $ \sdev -> do
               fmap (fromMaybe M0_NC_UNKNOWN) (queryObjectStatus sdev) >>= \case
                 M0_NC_UNKNOWN -> messageProcessed uuid
                 M0_NC_ONLINE -> messageProcessed uuid
                 M0_NC_TRANSIENT -> do
                   notifyDriveStateChange sdev M0_NC_ONLINE
                   messageProcessed uuid
                 M0_NC_FAILED -> do
                   markIfNotMeroFailure
                   handleRepair $ Set [Note (fid sdev) M0_NC_FAILED]
                 M0_NC_REPAIRED -> do
                   markIfNotMeroFailure
                   handleRepair $ Set [Note (fid sdev) M0_NC_ONLINE]
                 M0_NC_REPAIR -> do
                   markIfNotMeroFailure
                   handleRepair $ Set [Note (fid sdev) M0_NC_ONLINE]
                 M0_NC_REBALANCE ->  -- Impossible case
                   messageProcessed uuid
             continue finish
           False -> do
             lookupStorageDeviceReplacement disk >>= \case
               Nothing -> modifyGraph $
                 G.disconnectAllFrom disk Has (Proxy :: Proxy DeviceIdentifier)
               Just cand -> actualizeStorageDeviceReplacement cand
             identifyStorageDevice disk sn
             identifyStorageDevice disk path
             updateStorageDeviceSDev disk
             markStorageDeviceReplaced disk
             request <- liftIO $ nextRandom
             put Local $ Just (request, di)
             syncGraphProcess $ \self -> usend self (request, SyncToConfdServersInRG)
             continue sync_complete

      setPhase sync_complete $ \(SyncComplete request) -> do
        Just (req, _) <- get Local
        let next = if req == request
                   then commit
                   else sync_complete
        continue next

      directly commit $ do
        Just (_, DriveInserted{diDevice=disk}) <- get Local
        sdev <- lookupStorageDeviceSDev disk
        forM_ sdev $ \m0sdev -> do
          msa <- getSpielAddressRC
          forM_ msa $ \_ -> void  $ withSpielRC $ \sp -> withRConfRC sp
                    $ liftIO $ Spiel.deviceAttach sp (d_fid m0sdev)
          fmap (fromMaybe M0_NC_UNKNOWN) (queryObjectStatus m0sdev) >>= \case
            M0_NC_TRANSIENT -> notifyDriveStateChange m0sdev M0_NC_FAILED
            M0_NC_FAILED -> handleRepair $ Set [Note (fid m0sdev) M0_NC_FAILED]
            M0_NC_REPAIRED -> handleRepair $ Set [Note (fid m0sdev) M0_NC_ONLINE]
            M0_NC_REPAIR -> return ()
            -- Impossible cases
            M0_NC_UNKNOWN -> notifyDriveStateChange m0sdev M0_NC_FAILED
            M0_NC_ONLINE ->  notifyDriveStateChange m0sdev M0_NC_FAILED
            M0_NC_REBALANCE -> notifyDriveStateChange m0sdev M0_NC_FAILED
        unmarkStorageDeviceRemoved disk
        continue finish

      directly finish $ do
        Just (_, DriveInserted{diUUID=uuid}) <- get Local
        syncGraphProcessMsg uuid
        stop

      start pinit Nothing
  where
    initWrapper ginit = do
       wrapper_init <- phaseHandle "wrapper_init"
       wrapper_clear <- phaseHandle "wrapper_clear"
       wrapper_end   <- phaseHandle "wrapper_end"
       directly wrapper_init $ switch [ginit, wrapper_clear]

       directly wrapper_clear $ do
         fork NoBuffer $ continue ginit
         continue wrapper_end

       directly wrapper_end stop
       return wrapper_init

#else
ruleDriveInserted :: Definitions LoopState ()
ruleDriveInserted = defineSimple "drive-inserted" $
  \(DriveInserted{diUUID=uuid,diDevice=disk,diSerial=sn,diPath=path}) -> do
    lookupStorageDeviceReplacement disk >>= \case
      Nothing -> modifyGraph $ G.disconnectAllFrom disk Has (Proxy :: Proxy DeviceIdentifier)
      Just cand -> actualizeStorageDeviceReplacement cand
    identifyStorageDevice disk sn
    identifyStorageDevice disk path
    syncGraphProcessMsg uuid
#endif

-- | Mark drive as failed
ruleDriveFailed :: Definitions LoopState ()
ruleDriveFailed = defineSimple "drive-failed" $ \(DriveFailed uuid _ _ disk) -> do
#ifdef USE_MERO
      sd <- lookupStorageDeviceSDev disk
      forM_ sd $ \m0sdev -> notifyDriveStateChange m0sdev M0_NC_FAILED
#endif
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
    attrs = [HA_MEMSIZE_MB mem, HA_CPU_COUNT cpucount]
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
