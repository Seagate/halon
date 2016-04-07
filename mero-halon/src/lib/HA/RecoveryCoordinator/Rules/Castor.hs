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
import qualified Mero.Spiel as Spiel
import HA.RecoveryCoordinator.Actions.Mero
import HA.RecoveryCoordinator.Actions.Mero.Failure
import HA.RecoveryCoordinator.Rules.Castor.Repair
import HA.RecoveryCoordinator.Rules.Castor.Reset
import HA.Resources.Mero hiding (Enclosure, Node, Process, Rack, Process)
import HA.Resources.Mero.Note
import HA.RecoveryCoordinator.Events.Mero
import Mero.Notification hiding (notifyMero)
import Mero.Notification.HAState (Note(..))
import Data.UUID.V4 (nextRandom)
import qualified Data.UUID as UUID
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
      liftProcess $ say "Loaded initial data"
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
    stateChangeHandlers = [ handleReset
                          , handleRepair
                          , handleUnused
                          ]
    handleUnused :: ([PendingNotification], Set)
                 -> PhaseM LoopState l ([PendingNotification], Set)
    handleUnused (pn, set) = do
      phaseLog "handleUnused" $ "Unhandled Set messages: " ++ show set
      return (pn, set)

ruleMeroNoteSet :: Definitions LoopState ()
ruleMeroNoteSet = do
  defineSimple "mero-note-set" $ \(HAEvent uid set@(Set _) _) -> do
    phaseLog "info" $ "Received " ++ show set
    _ <- runStateChangeHandlers ([], set)
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

  setPhase pinit $ \(DriveRemoved uuid _ enc disk loc) -> do
    markStorageDeviceRemoved disk
    sd <- lookupStorageDeviceSDev disk
    phaseLog "debug" $ "Associated storage device: " ++ show sd
    forM_ sd $ \m0sdev -> do
      fork CopyNewerBuffer $ do
        phaseLog "mero" $ "Notifying M0_NC_TRANSIENT for device."
        _ <- updateDriveState True m0sdev M0_NC_TRANSIENT
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
    phaseLog "debug" "Notify about drive state change"
    notifyDriveStateChange m0sdev M0_NC_FAILED
    messageProcessed uuid
    continue finish

  startFork pinit Nothing
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
               void . handleRepair $ ([], Set [Note (fid sdev) M0_NC_FAILED])
             M0_NC_REPAIRED -> do
               markIfNotMeroFailure
               void . handleRepair $ ([], Set [Note (fid sdev) M0_NC_ONLINE])
             M0_NC_REPAIR -> do
               markIfNotMeroFailure
               void . handleRepair $ ([], Set [Note (fid sdev) M0_NC_ONLINE])
             M0_NC_REBALANCE ->  -- Impossible case
               messageProcessed uuid
         continue finish
       False -> do
         lookupStorageDeviceReplacement disk >>= \case
           Nothing -> modifyGraph $
             G.disconnectAllFrom disk Has (Proxy :: Proxy DeviceIdentifier)
           Just cand -> actualizeStorageDeviceReplacement cand
         identifyStorageDevice disk [sn, path]
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
      forM_ msa $ \_ -> void  $ withSpielRC $ \sp _ -> withRConfRC sp
                $ liftIO $ Spiel.deviceAttach sp (d_fid m0sdev)
      fmap (fromMaybe M0_NC_UNKNOWN) (queryObjectStatus m0sdev) >>= \case
        M0_NC_TRANSIENT -> notifyDriveStateChange m0sdev M0_NC_FAILED
        M0_NC_FAILED -> void . handleRepair $ ([], Set [Note (fid m0sdev) M0_NC_FAILED])
        M0_NC_REPAIRED -> void . handleRepair $ ([], Set [Note (fid m0sdev) M0_NC_ONLINE])
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

  startFork handler Nothing

#else
ruleDriveInserted :: Definitions LoopState ()
ruleDriveInserted = defineSimple "drive-inserted" $
  \(DriveInserted{diUUID=uuid,diDevice=disk,diSerial=sn,diPath=path}) -> do
    lookupStorageDeviceReplacement disk >>= \case
      Nothing -> modifyGraph $ G.disconnectAllFrom disk Has (Proxy :: Proxy DeviceIdentifier)
      Just cand -> actualizeStorageDeviceReplacement cand
    identifyStorageDevice disk [sn, path]
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
    -- Nodes mentioned in ID are not clients in the 'dynamic' sense.
    remAttrs = [HA_M0CLIENT]
  in do
    registerHost host
    locateHostInEnclosure host enc
    mapM_ (setHostAttr host) attrs
    mapM_ (unsetHostAttr host) remAttrs
    mapM_ (registerInterface host) h_interfaces
