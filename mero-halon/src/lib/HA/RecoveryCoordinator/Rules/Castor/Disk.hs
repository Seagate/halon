-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Module rules for Disk entity.
--
-- # Resource graph representation.
--
-- Disk is represented in graph as following linked objects:
--
--    * 'HA.Resource.Castor.StorageDevice' - Halon specific identifier.
--    * 'HA.Resource.Mero.Disk' - information about drive properties.
--    * 'HA.Resource.Mero.SDev' - Mero specific identifier.
--
-- # Processes that can be run on disks
--
--    * Reset - castor specific procedule of drive reset. This procedure
--       tries to recover disk in case if error appeared on the mero side.
--       See "HA.RecoveryCoordinator.Rules.Castor.Disk.Reset" for details.
--    * Repair - mero specific procedure of recovering data in case of
--       disk failure or new drive insertion.
--       See "HA.RecoveryCoordinator.Rules.Castor.Disk.Repair" for details.

{-# LANGUAGE LambdaCase #-}
module HA.RecoveryCoordinator.Rules.Castor.Disk
  ( -- & All rules
    rules
  , internalNotificationHandlers
  , externalNotificationHandlers
    -- * Internal rules (for tests use)
  , ruleDriveFailed
  , ruleDriveInserted
  , ruleDriveRemoved
  , driveRemovalTimeout
  , driveInsertionTimeout
  ) where

import HA.RecoveryCoordinator.Rules.Castor.Disk.Repair as Repair
import HA.RecoveryCoordinator.Rules.Castor.Disk.Reset  as Reset

import Control.Distributed.Process hiding (catch)

import HA.Encode (decodeP)
import HA.EventQueue.Types
import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Hardware
import HA.RecoveryCoordinator.Events.Drive
import HA.Resources
import HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.ResourceGraph as G
import HA.Services.SSPL
import Control.Applicative
import qualified Mero.Spiel as Spiel
import HA.RecoveryCoordinator.Actions.Mero
import HA.RecoveryCoordinator.Rules.Mero.Conf
import HA.Resources.Mero hiding (Enclosure, Node, Process, Rack, Process)
import qualified HA.Resources.Mero as M0
import HA.Resources.Mero.Note
import HA.RecoveryCoordinator.Events.Mero
import Mero.Notification hiding (notifyMero)
import Mero.Notification.HAState (Note(..))
import Data.UUID.V4 (nextRandom)
import qualified Data.UUID as UUID
import Data.Proxy (Proxy(..))
import Data.Foldable


import Control.Monad
import Data.Maybe
import Data.Binary (Binary)

import Network.CEP
import Prelude hiding (id)

-- | Set of all rules related to the disk livetime. It's reexport to be
-- used at the toplevel castor module.
rules :: Definitions LoopState ()
rules = sequence_
  [ ruleDriveFailed
  , ruleDriveInserted
  , ruleDriveRemoved
  , Repair.checkRepairOnClusterStart
  , Repair.checkRepairOnServiceUp
  , Repair.ruleRepairStart
  , Repair.ruleRebalanceStart
  , Reset.ruleResetAttempt
  ]

-- | All internal notifications related to disks.
internalNotificationHandlers :: [Set -> PhaseM LoopState l ()]
internalNotificationHandlers =
  [ Repair.handleRepairInternal
  , Reset.handleResetInternal
  ]

-- | All external notifications related to disks.
externalNotificationHandlers :: [Set -> PhaseM LoopState l ()]
externalNotificationHandlers =
  [ Repair.handleRepairExternal
  , Reset.handleResetExternal
  ]

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
        phaseLog "mero" $ "Notifying M0_NC_TRANSIENT for sdev"
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
    mdisk <- lookupSDevDisk m0sdev
    forM_ mdisk $ \disk ->
      withSpielRC $ \sp m0 -> withRConfRC sp
        $ m0 $ Spiel.deviceDetach sp (fid disk)
    phaseLog "debug" "Notifying M0_NC_FAILED for sdev"
    notifyDriveStateChange m0sdev M0_NC_FAILED
    messageProcessed uuid
    continue finish

  startFork pinit Nothing

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
           getLocalGraph >>= \rg -> case getConfObjState sdev rg of
             M0_NC_UNKNOWN -> messageProcessed uuid
             M0_NC_ONLINE -> messageProcessed uuid
             M0_NC_TRANSIENT -> do
               notifyDriveStateChange sdev M0_NC_ONLINE
               messageProcessed uuid
             M0_NC_FAILED -> do
                markIfNotMeroFailure
                handleRepairInternal $ Set [Note (fid sdev) M0_NC_FAILED]
             M0_NC_REPAIRED -> do
               markIfNotMeroFailure
               attachDisk sdev
               handleRepairInternal $ Set [Note (fid sdev) M0_NC_ONLINE]
             M0_NC_REPAIR -> do
               markIfNotMeroFailure
               attachDisk sdev
               handleRepairInternal $ Set [Note (fid sdev) M0_NC_ONLINE]
             M0_NC_REBALANCE ->  -- Impossible case
               messageProcessed uuid
         continue finish
       False -> do
         lookupStorageDeviceReplacement disk >>= \case
           Nothing -> modifyGraph $
             G.disconnectAllFrom disk Has (Proxy :: Proxy DeviceIdentifier)
           Just cand -> actualizeStorageDeviceReplacement cand
         identifyStorageDevice disk [sn]
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
      attachDisk m0sdev
      getLocalGraph >>= \rg -> case getConfObjState m0sdev rg of
        M0_NC_TRANSIENT -> notifyDriveStateChange m0sdev M0_NC_FAILED
        M0_NC_FAILED -> handleRepairInternal $ Set [Note (fid m0sdev) M0_NC_FAILED]
        M0_NC_REPAIRED -> handleRepairInternal $ Set [Note (fid m0sdev) M0_NC_ONLINE]
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

attachDisk :: M0.SDev -> PhaseM LoopState a ()
attachDisk sdev = do
  mdisk <- lookupSDevDisk sdev
  forM_ mdisk $ \d -> do
    msa <- getSpielAddressRC
    forM_ msa $ \_ -> void  $ withSpielRC $ \sp m0 -> withRConfRC sp
      $ m0 $ Spiel.deviceAttach sp (fid d)

-- | Mark drive as failed
ruleDriveFailed :: Definitions LoopState ()
ruleDriveFailed = defineSimple "drive-failed" $ \(DriveFailed uuid _ _ disk) -> do
  sd <- lookupStorageDeviceSDev disk
  forM_ sd $ \m0sdev -> notifyDriveStateChange m0sdev M0_NC_FAILED
  messageProcessed uuid
