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
{-# LANGUAGE ViewPatterns #-}
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

import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Hardware
import HA.RecoveryCoordinator.Events.Castor.Cluster (PoolRebalanceRequest(..))
import HA.RecoveryCoordinator.Events.Drive
import HA.Resources
import HA.Resources.Castor
import qualified HA.ResourceGraph as G
import HA.Services.SSPL
import qualified Mero.Spiel as Spiel
import HA.RecoveryCoordinator.Actions.Mero
import HA.RecoveryCoordinator.Rules.Mero.Conf
import HA.Resources.Mero hiding (Enclosure, Node, Process, Rack, Process)
import qualified HA.Resources.Mero as M0
import HA.Resources.Mero.Note
import HA.RecoveryCoordinator.Events.Mero
import Mero.Notification hiding (notifyMero)
import Mero.Notification.HAState (Note(..))


import Control.Applicative
import Control.Distributed.Process hiding (catch)
import Control.Lens ((<&>))
import Control.Monad
import Control.Monad.Trans.Maybe

import Data.Maybe
import Data.Proxy (Proxy(..))
import qualified Data.Text as T
import Data.UUID.V4 (nextRandom)
import qualified Data.UUID as UUID

import Network.CEP

import Text.Printf (printf)

import Prelude hiding (id)

-- | Set of all rules related to the disk livetime. It's reexport to be
-- used at the toplevel castor module.
rules :: Definitions LoopState ()
rules = sequence_
  [ ruleDriveFailed
  , ruleDriveInserted
  , ruleDriveRemoved
  , ruleDrivePoweredOff
  , ruleDrivePoweredOn
  , ruleExpanderResetBlip
  , rulePowerDownDriveOnFailure
  , Repair.checkRepairOnClusterStart
  , Repair.checkRepairOnServiceUp
  , Repair.ruleRepairStart
  , Repair.ruleRebalanceStart
  , Repair.ruleSNSOperationAbort
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
        old_state <- getLocalGraph >>= return . getState m0sdev
        applyStateChanges [stateSet m0sdev $ sdsFailTransient old_state]
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
    old_state <- getLocalGraph <&> getState m0sdev
    applyStateChanges [stateSet m0sdev $ sdsFailFailed old_state]
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
               applyStateChangesCreateFS [
                   stateSet sdev . sdsRecoverTransient $ getState sdev rg
                 ]
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
        M0_NC_TRANSIENT -> applyStateChanges [ stateSet m0sdev M0.SDSFailed ]
        M0_NC_FAILED -> handleRepairInternal $ Set [Note (fid m0sdev) M0_NC_FAILED]
        M0_NC_REPAIRED -> handleRepairInternal $ Set [Note (fid m0sdev) M0_NC_ONLINE]
        M0_NC_REPAIR -> return ()
        -- Impossible cases
        M0_NC_UNKNOWN -> applyStateChanges [ stateSet m0sdev M0.SDSFailed ]
        M0_NC_ONLINE ->  applyStateChanges [ stateSet m0sdev M0.SDSFailed ]
        M0_NC_REBALANCE -> applyStateChanges [ stateSet m0sdev M0.SDSFailed ]
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
  forM_ sd $ \m0sdev -> do
    old_state <- getLocalGraph <&> getState m0sdev
    applyStateChanges [ stateSet m0sdev $ sdsFailFailed old_state ]
  messageProcessed uuid

-- | When a drive is powered off
ruleDrivePoweredOff :: Definitions LoopState ()
ruleDrivePoweredOff = define "drive-powered-off" $ do
  power_removed <- phaseHandle "power_removed"
  power_returned <- phaseHandle "power_returned"
  power_removed_duration <- phaseHandle "power_removed_duration"

  let
    power_down_timeout = 300 -- seconds
    power_off evt@(DrivePowerChange{..}) _ _ =
      if dpcPowered then return Nothing else return (Just evt)
    power_on evt@(DrivePowerChange{..}) _ _ =
      if dpcPowered then return (Just evt) else return Nothing
    matching_device _ _ Nothing = return Nothing
    matching_device evt@(DrivePowerChange{..}) _ (Just (_,dev)) =
      if dev == dpcDevice then return (Just evt) else return Nothing
    x `gAnd` y = \a g l -> x a g l >>= \case
      Nothing -> return Nothing
      Just b -> y b g l

  setPhaseIf power_removed power_off $ \(DrivePowerChange{..}) ->
    let
      (Node nid) = dpcNode
    in do
      todo dpcUUID
      put Local $ Just (dpcUUID, dpcDevice)
      markDiskPowerOff dpcDevice

      -- Mark Mero device as transient
      mm0sdev <- lookupStorageDeviceSDev dpcDevice
      forM_ mm0sdev $ \m0sdev -> do
        old_state <- getLocalGraph >>= return . getState m0sdev
        applyStateChanges [stateSet m0sdev $ sdsFailTransient old_state]

      -- Attempt to power the disk back on
      sent <- sendNodeCmd nid Nothing (DrivePoweron dpcSerial)
      if sent
      then switch [ power_returned
                  , timeout power_down_timeout power_removed_duration
                  ]
      else do
        -- Unable to send drive power on message - go straight to
        -- power_removed_duration
        phaseLog "warning" $ "Cannot send poweron message to "
                          ++ (show nid)
                          ++ " for disk with s/n "
                          ++ (show dpcSerial)
        continue power_removed_duration

  setPhaseIf power_returned (power_on `gAnd` matching_device)
    $ \(DrivePowerChange{..}) -> do
      phaseLog "info" $ "Device " ++ (show dpcSerial) ++ " has been repowered."
      markDiskPowerOn dpcDevice

      -- Mark Mero device as back online
      mm0sdev <- lookupStorageDeviceSDev dpcDevice
      forM_ mm0sdev $ \m0sdev -> do
        old_state <- getLocalGraph >>= return . getState m0sdev
        applyStateChanges [stateSet m0sdev $ sdsRecoverTransient old_state]

      Just (uuid, _) <- get Local
      done uuid

  directly power_removed_duration $ do
    Just (uuid, dpcDevice) <- get Local

    -- Mark Mero device as permanently failed
    mm0sdev <- lookupStorageDeviceSDev dpcDevice
    forM_ mm0sdev $ \m0sdev -> do
      old_state <- getLocalGraph <&> getState m0sdev
      applyStateChanges [stateSet m0sdev $ sdsFailFailed old_state]

    done uuid

  startFork power_removed Nothing

-- | If a drive is powered on, and it wasn't failed due to Mero issues
--   or SMART test failures (e.g. it had just been depowered), then mark
--   it as replaced and start a rebalance.
ruleDrivePoweredOn :: Definitions LoopState ()
ruleDrivePoweredOn = defineSimple "drive-powered-on"
  $ \(DrivePowerChange{..}) -> do
    todo dpcUUID
    markDiskPowerOn dpcDevice
    realFailure <- maybe False isRealFailure <$> driveStatus dpcDevice
    unless realFailure $ do
      fdev <- lookupStorageDeviceSDev dpcDevice
              >>= filterMaybeM (\d -> getLocalGraph <&> m0failed . getState d)
      forM_ fdev $ \m0sdev -> do
        phaseLog "info" $ "Failed device with no underlying failure has been "
                        ++ "repowered. Marking as replaced."
        phaseLog "info" $ "Storage device: " ++ show dpcDevice
        phaseLog "info" $ "Mero device: " ++ showFid m0sdev
        markStorageDeviceReplaced dpcDevice
        -- Start rebalance
        pool <- getSDevPool m0sdev
        forM_ pool $ promulgateRC . PoolRebalanceRequest
    done dpcUUID
  where
    filterMaybeM _ Nothing = return Nothing
    filterMaybeM f j@(Just x) = f x >>= \q -> return $ if q then j else Nothing
    isRealFailure (StorageDeviceStatus "MERO-FAILED" _) = True
    isRealFailure (StorageDeviceStatus "FAILED" _) = True
    isRealFailure _ = False
    m0failed SDSFailed = True
    m0failed SDSRepairing = True
    m0failed SDSRepaired = True
    m0failed _ = False

-- | This rule handles processing events seen when the expander resets. In
--   such a case we expect to see many @DriveTransient@ events, as well as
--   an @ExpanderReset@ event. This may all happen whilst Mero is also
--   detecting failures.
ruleExpanderResetBlip :: Definitions LoopState ()
ruleExpanderResetBlip = define "castor::disk::expander-reset::blip" $ do
  any_evt <- phaseHandle "any_evt"
  drive_blip <- phaseHandle "drive_blip"
  drive_unblip <- phaseHandle "drive_unblip"

  directly any_evt $ switch [drive_blip, drive_unblip]

  -- Drive blip probably means we have an expander reset. But for the
  -- moment, just fail the one drive.
  setPhase drive_blip $ \(DriveTransient eid _ _ disk) -> do
    rg <- getLocalGraph
    mm0sdev <- lookupStorageDeviceSDev disk
    forM_ mm0sdev $ \sd -> do
      applyStateChanges [ stateSet sd . sdsFailTransient $ getState sd rg ]
    messageProcessed eid

  -- Drive unblip. Expander reset has passed, now we can restore disks
  -- to their previous state, provided they're not undergoing reset or similar.
  setPhase drive_unblip $ \(DriveOK eid _ _ disk) -> do
    rg <- getLocalGraph
    reset <- hasOngoingReset disk
    powered <- isStorageDevicePowered disk
    removed <- isStorageDriveRemoved disk
    when (not reset && powered && not removed) $ do
      mm0sdev <- lookupStorageDeviceSDev disk
      forM_ mm0sdev $ \sd -> do
        applyStateChanges [ stateSet sd . sdsRecoverTransient $ getState sd rg ]
    messageProcessed eid

  startFork any_evt ()

-- | When a drive is marked as failed, power it down.
rulePowerDownDriveOnFailure :: Definitions LoopState ()
rulePowerDownDriveOnFailure = define "power-down-drive-on-failure" $ do

  m0_drive_failed <- phaseHandle "m0_drive_failed"

  setPhaseInternalNotificationWithState m0_drive_failed (== M0.SDSFailed)
    $ \(uuid, objs) -> forM_ objs $ \(m0sdev, _) -> do
      todo uuid
      mdiskinfo <- runMaybeT $ do
        sdev <- MaybeT $ lookupStorageDevice m0sdev
        serial <- MaybeT $ listToMaybe <$> lookupStorageDeviceSerial sdev
        node <- MaybeT $ listToMaybe <$> getSDevNode sdev
        return (node, serial)
      forM_ mdiskinfo $ \(node@(Node nid), serial) -> do
        sent <- sendNodeCmd nid Nothing (DrivePowerdown . T.pack $ serial)
        if sent
        then phaseLog "info"
              $ printf "Powering off failed device %s on node %s"
                          serial
                          (show node)
        else phaseLog "warning"
              $ printf "Unable to power off failed device %s on node %s"
                          serial
                          (show node)
      done uuid

  startFork m0_drive_failed Nothing
