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
{-# LANGUAGE GADTs #-}
module HA.RecoveryCoordinator.Castor.Drive.Rules
  ( -- & All rules
    rules
  , externalNotificationHandlers
    -- * Internal rules (exported for test use)
  , ruleDriveFailed
  , ruleDriveInserted
  , ruleDriveRemoved
  , driveRemovalTimeout
  , driveInsertionTimeout
  -- * Constants (for test use)
  , resetAttemptThreshold
  ) where

import qualified HA.RecoveryCoordinator.Castor.Drive.Rules.Raid as Raid
import HA.RecoveryCoordinator.Castor.Drive.Rules.Repair as Repair
import HA.RecoveryCoordinator.Castor.Drive.Rules.Reset  as Reset
import qualified HA.RecoveryCoordinator.Castor.Drive.Rules.Smart  as Smart
import HA.RecoveryCoordinator.Castor.Drive.Events

import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Hardware
import HA.RecoveryCoordinator.Castor.Drive.Actions
import HA.RecoveryCoordinator.Events.Castor.Cluster (PoolRebalanceRequest(..))
import HA.Resources
import HA.Resources.Castor
import qualified HA.ResourceGraph as G
import HA.Services.SSPL
import HA.RecoveryCoordinator.Actions.Mero
import HA.RecoveryCoordinator.Rules.Mero.Conf
import HA.Resources.Mero hiding (Enclosure, Node, Process, Rack, Process)
import qualified HA.Resources.Mero as M0
import HA.Resources.Mero.Note
import HA.RecoveryCoordinator.Events.Mero
import Mero.Notification hiding (notifyMero)

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

-- | Set of all rules related to the disk livetime. It's reexport to be
-- used at the toplevel castor module.
rules :: Definitions LoopState ()
rules = sequence_
  [ ruleDriveFailed
  , ruleDriveInserted
  , ruleDriveRemoved
  , ruleDrivePoweredOff
  , ruleDrivePoweredOn
  , ruleDriveBlip
  , ruleDriveOK
  , rulePowerDownDriveOnFailure
  , Repair.checkRepairOnClusterStart
  , Repair.checkRepairOnServiceUp
  , Repair.ruleRepairStart
  , Repair.ruleRebalanceStart
  , Repair.ruleSNSOperationAbort
  , Repair.ruleSNSOperationQuiesce
  , Repair.ruleSNSOperationContinue
  , Repair.ruleOnSnsOperationQuiesceFailure
  , Repair.ruleHandleRepair
  , Reset.ruleResetAttempt
  , Raid.rules
  , Smart.rules
  ]

-- | All external notifications related to disks.
externalNotificationHandlers :: [Set -> PhaseM LoopState l ()]
externalNotificationHandlers =
  [ Repair.handleRepairExternal
  , Reset.handleResetExternal
  ]

driveRemovalTimeout :: Int
driveRemovalTimeout = 60

-- | Verifies that a drive is in a ready state, and takes appropriate
--   actions accordingly.
--   To be 'ready', a drive should be:
--   - Powered
--   - Inserted
--   - Visible to the OS (e.g. have a drivemanager 'OK' status)
mkCheckAndHandleDriveReady ::
     (l -> Maybe StorageDevice) -- ^ accessor to curent storage device in a local state.
  -> (M0.SDev -> PhaseM LoopState l ()) -- ^ Action to run when drive is handled.
  -> RuleM LoopState l (Jump PhaseHandle, StorageDevice -> PhaseM LoopState l ())
mkCheckAndHandleDriveReady getter next = do

  let post_process m0sdev = do
        oldState <- getLocalGraph <&> getState m0sdev
        case oldState of
          SDSUnknown -> do
            -- We do not know the old state, so set the new state to online
            applyStateChanges [ stateSet m0sdev SDSOnline ]
          SDSOnline -> return () -- Do nothing
          SDSFailed -> do
            -- Drive was permanently failed, and has not yet been repaired.
            -- We should not have to do anything here.
            return ()
          SDSRepairing -> do
            -- Drive is repairing. When it's finished, rebalance should start
            -- automatically.
            return ()
          SDSRepaired -> do
            -- Start rebalance
            pool <- getSDevPool m0sdev
            promulgateRC $ PoolRebalanceRequest pool
          SDSTransient _ -> do
            -- Transient failure - recover
            applyStateChanges [ stateSet m0sdev . sdsRecoverTransient $ oldState ]
          SDSRebalancing -> return ()
        next m0sdev

  (device_attached, deviceAttach) <- mkAttachDisk
    (fmap join . traverse (lookupStorageDeviceSDev) . getter)
    (\sdev e -> do phaseLog "warning" e
                   post_process sdev)
    post_process

  return (device_attached, \disk -> do
    reset <- hasOngoingReset disk
    powered <- isStorageDevicePowered disk
    removed <- isStorageDriveRemoved disk
    StorageDeviceStatus status _ <-
      maybe (StorageDeviceStatus "" "") id <$> driveStatus disk

    if not reset && powered && not removed && status == "OK"
    then do
      promulgateRC $ DriveReady disk
      mm0sdev <- lookupStorageDeviceSDev disk
      forM_ mm0sdev $ \sd -> do
        deviceAttach sd
        continue device_attached
     else
       phaseLog "info" $ unwords [
           "Device not ready:", show disk
         , "Reset ongoing:", show reset
         , "Powered:", show powered
         , "Removed:", show removed
         , "Status:", status
         ])

-- | Removing drive:
-- We need to notify mero about drive state change and then send event to the logger.
ruleDriveRemoved :: Definitions LoopState ()
ruleDriveRemoved = define "drive-removed" $ do
  pinit   <- phaseHandle "init"
  finish   <- phaseHandle "finish"
  reinsert <- phaseHandle "reinsert"
  removal  <- phaseHandle "removal"

  let post_process m0sdev = do
        Just (uuid, _, _, _, _) <- get Local
        old_state <- getLocalGraph >>= return . getState m0sdev
        applyStateChanges [stateSet m0sdev $ sdsFailTransient old_state]
        switch [reinsert, timeout driveRemovalTimeout removal]
        messageProcessed uuid

  (device_detached, detachDisk) <- mkDetachDisk
    (return . fmap (\(_,_,_,_,d) -> d))
    (\sdev e -> do phaseLog "warning" e
                   post_process sdev)
    post_process

  setPhase pinit $ \(DriveRemoved uuid _ enc disk loc powered) -> do
    markStorageDeviceRemoved disk
    unless powered $ markDiskPowerOff disk
    sd <- lookupStorageDeviceSDev disk
    phaseLog "debug" $ "Associated storage device: " ++ show sd
    forM_ sd $ \m0sdev -> do
      fork CopyNewerBuffer $ do
        phaseLog "mero" $ "Notifying M0_NC_TRANSIENT for sdev"
        put Local $ Just (uuid, enc, disk, loc, m0sdev)
        detachDisk m0sdev
        continue device_detached
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
--
-- https://drive.google.com/open?id=0BxJP-hCBgo5OVDhjY3ItU1oxTms
ruleDriveInserted :: Definitions LoopState ()
ruleDriveInserted = define "drive-inserted" $ do
  handler       <- phaseHandle "drive-inserted"
  removed       <- phaseHandle "removed"
  inserted      <- phaseHandle "inserted"
  main          <- phaseHandle "main"
  sync_complete <- phaseHandle "handle-sync"
  finish        <- phaseHandle "finish"

  setPhase handler $ \di -> do
    put Local $ Just (UUID.nil, di)
    fork CopyNewerBuffer $
       switch [ removed
              , inserted
              , timeout driveInsertionTimeout main]

  setPhaseIf removed
    (\(DriveRemoved _ _ enc _ loc _) _
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

  (checked, checkAndHandleDriveReady) <-
    mkCheckAndHandleDriveReady (fmap (\(_,DriveInserted{diDevice=disk})->disk))
      $ \_ -> continue finish

  directly main $ do
    Just (_, di@DriveInserted{ diUUID = uuid
                             , diDevice = disk
                             , diSerial = sn
                             , diPowered = powered
                             }) <- get Local
    -- Check if we already have device that was inserted.
    -- In case it this is the same device, then we do not need to update confd.
    hasStorageDeviceIdentifier disk sn >>= \case
       True -> do
         let markIfNotMeroFailure = do
               -- TODO this should be more general and should check for
               -- e.g. smart failure as well.
               let isMeroFailure (StorageDeviceStatus "HALON-FAILED" _) = True
                   isMeroFailure _ = False
               meroFailure <- maybe False isMeroFailure <$> driveStatus disk
               if meroFailure
                 then messageProcessed uuid
                 else markStorageDeviceReplaced disk
         unmarkStorageDeviceRemoved disk
         when powered $ markDiskPowerOn disk
         markIfNotMeroFailure
         put Local $ Just (UUID.nil, di)
         checkAndHandleDriveReady disk
         continue checked
       False -> do
         lookupStorageDeviceReplacement disk >>= \case
           Nothing -> -- TODO remove this line? This removes all identifiers
                      -- from a drive with no replacement. Only the SN gets
                      -- added back.
             modifyGraph $
               G.disconnectAllFrom disk Has (Proxy :: Proxy DeviceIdentifier)
           Just cand ->
             -- actualizeStorageDeviceReplacement will merge the candidate
             -- back into the current disk, so now cand is merged back into
             -- disk.
             actualizeStorageDeviceReplacement cand
         identifyStorageDevice disk [sn]
         updateStorageDeviceSDev disk
         when powered $ markDiskPowerOn disk
         markStorageDeviceReplaced disk
         request <- liftIO $ nextRandom
         put Local $ Just (request, di)
         registerSyncGraphProcess $ \self -> usend self (request, SyncToConfdServersInRG)
         continue sync_complete

  setPhaseIf sync_complete
    (\(SyncComplete request) _ (Just (req, _)) -> return $
        if (req == request) then (Just ()) else Nothing
      )
    $ \() -> do
    Just (_, DriveInserted{diDevice=disk}) <- get Local
    checkAndHandleDriveReady disk
    continue finish

  directly finish $ do
    Just (_, DriveInserted{diUUID=uuid}) <- get Local
    registerSyncGraphProcessMsg uuid
    stop

  startFork handler Nothing

-- | Mark drive as failed when SMART fails.
--
--   This is triggered when a SMART test fails on the drive.
--   In this case, all we do is directly send FAILED notification
--   to Mero and internally.
--
--   See also:
--   'ruleMonitorDriveManager' -- sends the 'DriveFailed' message.
--   'handleRepairInternal' -- tries to start repair on disk
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
  post_power_removed <- phaseHandle "post-power-removed"

  let
    power_down_timeout = 300 -- seconds
    power_off evt@(DrivePowerChange{..}) _ _ =
      if dpcPowered then return Nothing else return (Just evt)
    power_on evt@(DrivePowerChange{..}) _ _ =
      if dpcPowered then return (Just evt) else return Nothing
    matching_device _ _ Nothing = return Nothing
    matching_device evt@(DrivePowerChange{..}) _ (Just (_,dev, _, _)) =
      if dev == dpcDevice then return (Just evt) else return Nothing
    x `gAnd` y = \a g l -> x a g l >>= \case
      Nothing -> return Nothing
      Just b -> y b g l

  let post_process m0sdev = do
        old_state <- getLocalGraph >>= return . getState m0sdev
        applyStateChanges [stateSet m0sdev $ sdsFailTransient old_state]
        continue post_power_removed
  (device_detached, detachDisk) <- mkDetachDisk
    (fmap join . traverse (\(_,d,_,_) -> lookupStorageDeviceSDev d))
    (\sdev e -> do phaseLog "warning" e
                   post_process sdev) post_process

  setPhaseIf power_removed power_off $ \(DrivePowerChange{..}) ->
    let
      (Node nid) = dpcNode
    in do
      todo dpcUUID
      put Local $ Just (dpcUUID, dpcDevice, nid, dpcSerial)
      markDiskPowerOff dpcDevice

      -- Mark Mero device as transient
      mm0sdev <- lookupStorageDeviceSDev dpcDevice
      forM_ mm0sdev $ \m0sdev -> do
        detachDisk m0sdev
        continue device_detached
      continue post_power_removed

  directly post_power_removed $ do
      Just (_, _, nid, serial) <- get Local
      -- Attempt to power the disk back on
      sent <- sendNodeCmd nid Nothing (DrivePoweron serial)
      if sent
      then switch [ power_returned
                  , timeout power_down_timeout power_removed_duration
                  ]
      else do
        -- Unable to send drive power on message - go straight to
        -- power_removed_duration
        -- TODO Send some sort of 'CannotTalkToSSPL' message?
        phaseLog "warning" $ "Cannot send poweron message to "
                          ++ (show nid)
                          ++ " for disk with s/n "
                          ++ (show dpcSerial)
        continue power_removed_duration

  (checked, checkAndHandleDriveReady) <-
    mkCheckAndHandleDriveReady (fmap (\(_,d,_,_) -> d)) $ \_ -> do
      Just (uuid, _, _, _) <- get Local
      done uuid

  setPhaseIf power_returned (power_on `gAnd` matching_device)
    $ \(DrivePowerChange{..}) -> do
      phaseLog "info" $ "Device " ++ (show dpcSerial) ++ " has been repowered."
      markDiskPowerOn dpcDevice

      checkAndHandleDriveReady dpcDevice
      continue checked

  directly power_removed_duration $ do
    Just (uuid, dpcDevice, _, _) <- get Local

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
ruleDrivePoweredOn = define "drive-powered-on" $ do

  handle <- phaseHandle "Drive power change event received."

  (checked, checkAndHandleDriveReady) <-
    mkCheckAndHandleDriveReady (fmap snd) $ \_ -> do
      Just (uuid,_) <- get Local
      done uuid

  setPhase handle $ \(DrivePowerChange{..}) -> do
    when dpcPowered $ do
      put Local $ Just (dpcUUID, dpcDevice)
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
          checkAndHandleDriveReady dpcDevice
          continue checked

  start handle Nothing
  where
    filterMaybeM _ Nothing = return Nothing
    filterMaybeM f j@(Just x) = f x >>= \q -> return $ if q then j else Nothing
    isRealFailure (StorageDeviceStatus "HALON-FAILED" _) = True
    isRealFailure (StorageDeviceStatus "FAILED" _) = True
    isRealFailure _ = False
    m0failed SDSFailed = True
    m0failed SDSRepairing = True
    m0failed SDSRepaired = True
    m0failed _ = False

-- | Drive blip probably means we have an expander reset. But for the
--   moment, just fail the one drive. Note that here we have a transient
--   failure that does not timeout. In general, this should be fine, because
--   either we should have a higher-level failure or this is an expander reset.
--   In the case of a higher-level failure (e.g. power fail or drive removed)
--   then those rules should be responsible for recovering to a non-transient
--   state. In the case of an expander reset, the expander reset rule should
--   handle escalating the failure.
ruleDriveBlip :: Definitions LoopState ()
ruleDriveBlip = defineSimple "castor::disk::blip"
  $ \(DriveTransient eid _ _ disk) -> do
    rg <- getLocalGraph
    removed <- isStorageDriveRemoved disk
    powered <- isStorageDevicePowered disk
    unless (removed || not powered) $ do
      mm0sdev <- lookupStorageDeviceSDev disk
      forM_ mm0sdev $ \sd -> do
        applyStateChanges [ stateSet sd . sdsFailTransient $ getState sd rg ]
    messageProcessed eid

-- | Fires when a drive is marked as 'ready' for use. This is typically
--   caused by a DriveManager message which indicates that the OS can now
--   see and interract with the drive.
ruleDriveOK :: Definitions LoopState ()
ruleDriveOK = define "castor::disk::ready" $ do
  handle <- phaseHandle "Drive ready event received"

  (checked, checkAndHandleDriveReady) <-
    mkCheckAndHandleDriveReady (fmap snd) $ \_ -> do
      Just (eid,_) <- get Local
      messageProcessed eid

  setPhase handle $ \(DriveOK eid _ _ disk) -> do
    put Local $ Just (eid, disk)
    checkAndHandleDriveReady disk
    continue checked

  start handle Nothing

-- | When a drive is marked as failed, power it down.
rulePowerDownDriveOnFailure :: Definitions LoopState ()
rulePowerDownDriveOnFailure = define "power-down-drive-on-failure" $ do

  m0_drive_failed <- phaseHandle "m0_drive_failed"

  setPhaseInternalNotificationWithState m0_drive_failed
    (\o n -> not (o `elem` [ M0.SDSRepaired
                           , M0.SDSFailed
                           , M0.SDSRepairing]) && n == M0.SDSFailed)
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
