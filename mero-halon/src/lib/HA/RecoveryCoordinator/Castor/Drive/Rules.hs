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
--       See "HA.RecoveryCoordinator.Castor.Rules.Disk.Reset" for details.
--    * Repair - mero specific procedure of recovering data in case of
--       disk failure or new drive insertion.
--       See "HA.RecoveryCoordinator.Castor.Rules.Disk.Repair" for details.

{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE GADTs #-}
module HA.RecoveryCoordinator.Castor.Drive.Rules
  ( -- & All rules
    rules
    -- * Internal rules (exported for test use)
  , ruleDriveFailed
  , ruleDriveInserted
  , ruleDriveRemoved
  , driveRemovalTimeout
  , driveInsertionTimeout
  ) where

import           HA.RecoveryCoordinator.Castor.Drive.Rules.Internal
import qualified HA.RecoveryCoordinator.Castor.Drive.Rules.Raid as Raid
import qualified HA.RecoveryCoordinator.Castor.Drive.Rules.Repair as Repair
import HA.RecoveryCoordinator.Castor.Drive.Rules.Reset  as Reset
import qualified HA.RecoveryCoordinator.Castor.Drive.Rules.Smart  as Smart
import HA.RecoveryCoordinator.Castor.Drive.Events

import HA.RecoveryCoordinator.RC.Actions
import HA.RecoveryCoordinator.Actions.Hardware
import HA.RecoveryCoordinator.Castor.Drive.Actions
import HA.RecoveryCoordinator.Castor.Cluster.Events (PoolRebalanceRequest(..))
import HA.RecoveryCoordinator.Job.Actions
import HA.RecoveryCoordinator.Job.Events
import HA.Resources
import HA.Resources.Castor
import HA.Services.SSPL
import HA.RecoveryCoordinator.Actions.Mero
import HA.RecoveryCoordinator.Mero.Notifications
import HA.RecoveryCoordinator.Mero.State
import HA.Resources.Mero hiding (Enclosure, Node, Process, Rack, Process)
import qualified HA.Resources.Mero as M0
import HA.Resources.Mero.Note
import HA.RecoveryCoordinator.Mero.Events
import qualified HA.RecoveryCoordinator.Mero.Transitions as Tr

import Control.Distributed.Process hiding (catch)
import Control.Lens
import Control.Monad
import Control.Monad.Trans.Maybe

import Data.Foldable (for_)
import Data.Maybe
import qualified Data.Text as T
import Data.UUID.V4 (nextRandom)
import qualified Data.UUID as UUID

import Network.CEP

import Text.Printf (printf)

-- | Set of all rules related to the disk livetime. It's reexport to be
-- used at the toplevel castor module.
rules :: Definitions RC ()
rules = sequence_
  [ ruleDriveFailed
  , ruleDriveInserted
  , ruleDriveRemoved
  , ruleDrivePoweredOff
  , ruleDrivePoweredOn
  , ruleDriveBlip
  , ruleDriveOK
  , rulePowerDownDriveOnFailure
  , Repair.rules
  , Reset.ruleResetAttempt
  , Reset.ruleResetInit
  , Raid.rules
  , Smart.rules
  ]

driveRemovalTimeout :: Int
driveRemovalTimeout = 60


-- | Verifies that a drive is in a ready state, and takes appropriate
--   actions accordingly.
--   To be 'ready', a drive should be:
--   - Powered
--   - Inserted
--   - Visible to the OS (e.g. have a drivemanager 'OK' status, and drive path)
--   - Have a successful SMART test run. This will be checked by this rule.
mkCheckAndHandleDriveReady ::
     Lens' l (Maybe CheckAndHandleState) -- ^ Simple lens to listener ID for SMART test
  -> (M0.SDev -> PhaseM RC l ())  -- ^ Action to run when drive is handled.
  -> RuleM RC l (Node -> StorageDevice -> PhaseM RC l [Jump PhaseHandle] -> PhaseM RC l [Jump PhaseHandle])
mkCheckAndHandleDriveReady smartLens next = do

  smart_run     <- phaseHandle "smart_run"
  sync_complete <- phaseHandle "sync-complete"
  smart_result  <- phaseHandle "smart_result"
  abort_result  <- phaseHandle "abort_result"

  let getter l = l ^? smartLens . _Just . chsStorageDevice
  let post_process m0sdev = do
        Just sdev <- getter <$> get Local
        promulgateRC $ DriveReady sdev
        getState m0sdev <$> getLocalGraph >>= \case
          SDSUnknown -> do
            -- We do not know the old state, so set the new state to online
            applyStateChanges [ stateSet m0sdev Tr.sdevReady ]
            next m0sdev
          SDSOnline -> return () -- Do nothing
          SDSFailed -> do
            -- Drive was permanently failed, and has not yet been repaired.
            -- We should not have to do anything here.
            next m0sdev
          SDSRepairing -> do
            -- Drive is repairing. When it's finished, rebalance should start
            -- automatically.
            next m0sdev
          SDSRepaired -> do
            -- Start rebalance
            pool <- getSDevPool m0sdev
            getPoolRepairStatus pool >>= \case
              Nothing -> do
                promulgateRC $ PoolRebalanceRequest pool
                next m0sdev
              Just prs -> do
                promulgateRC . AbortSNSOperation pool $ prsRepairUUID prs
                continue abort_result
          SDSTransient _ -> do
            -- Transient failure - recover
            applyStateChanges [ stateSet m0sdev Tr.sdevRecoverTransient]
            next m0sdev
          SDSRebalancing -> next m0sdev
          SDSInhibited _ -> do
            -- Higher level failure - nothing we can do
            next m0sdev

      onSameSdev (JobFinished listenerIds (SMARTResponse sdev' status)) _ l =
        return $ case (,) <$> ( getter l )
                          <*> ((\x -> x ^.chsSmartRequest) =<< (l ^. smartLens)) of
          Just (sdev, smartId)
               | smartId `elem` listenerIds
              && sdev == sdev' -> Just status
          _ -> Nothing

  setPhaseIf sync_complete
    (\(SyncComplete request) _ l -> return $
        let Just req = (\x -> x ^. chsSyncRequest) =<< (l ^. smartLens)
        in if (req == request) then (Just ()) else Nothing
      )
    $ \() -> continue smart_run

  (device_attached, deviceAttach) <- mkAttachDisk
    (fmap join . traverse (lookupStorageDeviceSDev) . getter)
    (\sdev e -> do phaseLog "warning" e
                   post_process sdev)
    post_process

  directly smart_run $ do
    phaseLog "info" "Device ready. Running SMART test."
    Just disk <- getter <$> get Local
    Just node <- fmap (\x -> x ^. chsNode) . (\x -> x ^. smartLens) <$> get Local
    smartId <- startJob $ SMARTRequest node disk
    modify Local $ smartLens . _Just . chsSmartRequest .~ Just smartId
    continue smart_result

  setPhaseIf smart_result onSameSdev $ \status -> do
    Just sdev <- getter <$> get Local
    phaseLog "sdev" $ show sdev
    phaseLog "smart.response" $ show status
    smartSuccess <- case status of
      SRSSuccess -> return True
      SRSNotAvailable -> do
        phaseLog "warning" "SMART functionality not available."
        return True
      _ -> do
        phaseLog "info" "Unsuccessful SMART test."
        return False

    if smartSuccess
    then do
      mm0sdev <- lookupStorageDeviceSDev sdev
      case mm0sdev of
        Just sd -> do
          deviceAttach sd
          continue device_attached
        Nothing ->
          promulgateRC $ DriveReady sdev
    else
      phaseLog "warning" "Unsuccessful SMART test. Drive cannot be used."

  setPhase abort_result $ \msg -> do
    case msg of
      AbortSNSOperationOk pool -> promulgateRC $ PoolRebalanceRequest pool
      AbortSNSOperationFailure _ err -> do
        phaseLog "warn" "Failed to abort SNS operation, doing nothing."
        phaseLog "warn.message" err
      AbortSNSOperationSkip pool -> promulgateRC $ PoolRebalanceRequest pool
    mm0sdev <- getter  <$> get Local >>= fmap join . traverse lookupStorageDeviceSDev
    for_ mm0sdev next

  return (\node disk onFailure -> do
    modify Local $ smartLens .~ Just (CheckAndHandleState node disk Nothing Nothing)
    reset   <- hasOngoingReset disk
    powered <- isStorageDevicePowered disk
    removed <- isStorageDriveRemoved disk
    StorageDeviceStatus status _ <-
      maybe (StorageDeviceStatus "" "") id <$> driveStatus disk

    Just sn <- fmap DISerialNumber . listToMaybe <$> lookupStorageDeviceSerial disk

    if not reset && powered && not removed && status == "OK"
    then
      -- Check if we already have device that was inserted.
      -- In case it this is the same device, then we do not need to update confd.
      lookupStorageDeviceReplacement disk >>= \case
        Nothing -> do
          sameDev <- hasStorageDeviceIdentifier disk sn
          if sameDev
          then do
            -- TODO this should be more general and should check for
            -- e.g. smart failure as well.
            let isMeroFailure (StorageDeviceStatus "HALON-FAILED" _) = True
                isMeroFailure _ = False
            meroFailure <- maybe False isMeroFailure <$> driveStatus disk
            if meroFailure
               then onFailure
               else do markStorageDeviceReplaced disk
                       if status == "OK"
                       then return [smart_run]
                       else do phaseLog "info" $ "status is " ++ status ++ " can't run smart check."
                               onFailure
          else do
            phaseLog "ERROR" "Unseen drive with no replacement candidate."
            onFailure
        Just cand -> do
          paths  <- lookupStorageDevicePaths cand
          serials <- lookupStorageDeviceSerial cand
          case (paths, serials) of
            ([], _) -> do
              phaseLog "WARN" "Paths are not attache to device, waiting for drive manager request"
              onFailure
            (_, []) -> do
              phaseLog "WARN" "No serial number attached to replacement device."
              onFailure
            (_, _) -> do
             -- actualizeStorageDeviceReplacement will merge the candidate
             -- back into the current disk, so now cand is merged back into
             -- disk.
             actualizeStorageDeviceReplacement cand
             updateStorageDeviceSDev disk
             markStorageDeviceReplaced disk
             request <- liftIO $ nextRandom
             modify Local $ smartLens . _Just . chsSyncRequest .~ Just request
             registerSyncGraphProcess $ \self -> usend self (request, SyncToConfdServersInRG)
             return [sync_complete]

    -- The drive wasn't ready so just run user callback: let's say
    -- reset is still on-going; reset rule will take care of
    -- attaching the drive and performing the state transition so
    -- don't worry about it here.
    else do
       phaseLog "info" $ unwords [
           "Device not ready:", show disk
         , "Reset ongoing:", show reset
         , "Powered:", show powered
         , "Removed:", show removed
         , "Status:", status
         ]
       onFailure)

-- | Removing drive:
-- We need to notify mero about drive state change and then send event to the logger.
ruleDriveRemoved :: Definitions RC ()
ruleDriveRemoved = define "drive-removed" $ do
  pinit   <- phaseHandle "init"
  finish   <- phaseHandle "finish"
  reinsert <- phaseHandle "reinsert"
  removal  <- phaseHandle "removal"

  let post_process m0sdev = do
        Just (uuid, _, _, _, _) <- get Local
        applyStateChanges [stateSet m0sdev Tr.sdevFailTransient]
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
    applyStateChanges [stateSet m0sdev Tr.sdevFailFailed]
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
ruleDriveInserted :: Definitions RC ()
ruleDriveInserted = define "drive-inserted" $ do
  handler       <- phaseHandle "drive-inserted"
  removed       <- phaseHandle "removed"
  inserted      <- phaseHandle "inserted"
  main          <- phaseHandle "main"
  finish        <- phaseHandle "finish"

  setPhase handler $ \di -> do
    put Local $ (Just (UUID.nil, di), Nothing)
    fork CopyNewerBuffer $
       switch [ removed
              , inserted
              , timeout driveInsertionTimeout main]

  setPhaseIf removed
    (\(DriveRemoved _ _ enc _ loc _) _
      (Just (_,DriveInserted{diUUID=uuid
                            ,diEnclosure=enc'
                            ,diDiskNum=loc'}), _) -> do
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
                             , diDiskNum=loc'}), _) -> do
        if enc == enc' && loc == loc'
           then return (Just uuid)
           else return Nothing)
    $ \uuid -> do
        phaseLog "info" "cancel drive insertion procedure due to new drive insertion."
        messageProcessed uuid
        continue finish

  checkAndHandleDriveReady <- mkCheckAndHandleDriveReady _2 (\_ -> continue finish)

  directly main $ do
    (Just (_, DriveInserted{ diNode = node
                           , diDevice = disk
                           , diPowered = powered
                           }), _) <- get Local

    when powered $ markDiskPowerOn disk
    unmarkStorageDeviceRemoved disk
    checked <- checkAndHandleDriveReady node disk (return [finish])
    switch checked

  directly finish $ do
    (Just (_, DriveInserted{diUUID=uuid}), _) <- get Local
    registerSyncGraphProcessMsg uuid
    stop

  startFork handler (Nothing, Nothing)

-- | Mark drive as failed when SMART fails.
--
--   This is triggered when a SMART test fails on the drive.
--   In this case, all we do is directly send FAILED notification
--   to Mero and internally.
--
--   See also:
--   'ruleMonitorDriveManager' -- sends the 'DriveFailed' message.
--   'handleRepairInternal' -- tries to start repair on disk
ruleDriveFailed :: Definitions RC ()
ruleDriveFailed = defineSimple "drive-failed" $ \(DriveFailed uuid _ _ disk) -> do
  sd <- lookupStorageDeviceSDev disk
  forM_ sd $ \m0sdev -> do
    applyStateChanges [ stateSet m0sdev Tr.sdevFailFailed]
  messageProcessed uuid

-- | When a drive is powered off
ruleDrivePoweredOff :: Definitions RC ()
ruleDrivePoweredOff = define "drive-powered-off" $ do
  power_removed <- phaseHandle "power_removed"
  power_returned <- phaseHandle "power_returned"
  power_removed_duration <- phaseHandle "power_removed_duration"
  post_power_removed <- phaseHandle "post-power-removed"
  finish <- phaseHandle "finish"

  let
    power_down_timeout = 300 -- seconds
    power_off evt@(DrivePowerChange{..}) _ _ =
      if dpcPowered then return Nothing else return (Just evt)
    power_on evt@(DrivePowerChange{..}) _ _ =
      if dpcPowered then return (Just evt) else return Nothing
    matching_device evt@(DrivePowerChange{..}) _ (Just (_,dev, _, _), Nothing) =
      if dev == dpcDevice then return (Just evt) else return Nothing
    matching_device _ _ _ = return Nothing
    x `gAnd` y = \a g l -> x a g l >>= \case
      Nothing -> return Nothing
      Just b -> y b g l

  let post_process m0sdev = do
        applyStateChanges [stateSet m0sdev Tr.sdevFailTransient]
        continue post_power_removed
  (device_detached, detachDisk) <- mkDetachDisk
    (fmap join . traverse (\(_,d,_,_) -> lookupStorageDeviceSDev d) . fst)
    (\sdev e -> do phaseLog "warning" e
                   post_process sdev) post_process

  setPhaseIf power_removed power_off $ \(DrivePowerChange{..}) -> do
    fork CopyNewerBuffer $ do
      todo dpcUUID
      let Node nid = dpcNode
      put Local $ (Just (dpcUUID, dpcDevice, nid, dpcSerial), Nothing)
      markDiskPowerOff dpcDevice

      -- Mark Mero device as transient
      mm0sdev <- lookupStorageDeviceSDev dpcDevice
      forM_ mm0sdev $ \m0sdev -> do
        detachDisk m0sdev
        continue device_detached
      continue post_power_removed

  directly post_power_removed $ do
      (Just (_, _, nid, serial), _) <- get Local
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

  checkAndHandleDriveReady <-
    mkCheckAndHandleDriveReady _2
      $ \_ -> do
        (Just (uuid, _, _, _), _) <- get Local
        done uuid
        continue finish

  setPhaseIf power_returned (power_on `gAnd` matching_device)
    $ \(DrivePowerChange{..}) -> do
      phaseLog "info" $ "Device " ++ show dpcSerial ++ " has been repowered."
      markDiskPowerOn dpcDevice
      (Just (uuid, _, _, _), _) <- get Local
      checked <- checkAndHandleDriveReady dpcNode dpcDevice (done uuid >> return [finish])
      switch checked

  directly power_removed_duration $ do
    (Just (uuid, dpcDevice, _, _), _) <- get Local

    -- Mark Mero device as permanently failed
    mm0sdev <- lookupStorageDeviceSDev dpcDevice
    forM_ mm0sdev $ \m0sdev -> do
      applyStateChanges [stateSet m0sdev Tr.sdevFailFailed]
    done uuid
    continue finish

  directly finish stop

  startFork power_removed (Nothing, Nothing)

-- | If a drive is powered on, and it wasn't failed due to Mero issues
--   or SMART test failures (e.g. it had just been depowered), then mark
--   it as replaced and start a rebalance.
ruleDrivePoweredOn :: Definitions RC ()
ruleDrivePoweredOn = define "drive-powered-on" $ do

  handle <- phaseHandle "Drive power change event received."
  finish <- phaseHandle "finish"

  checkAndHandleDriveReady <-
    mkCheckAndHandleDriveReady _2
      $ \_ -> do
        (Just (uuid,_), _) <- get Local
        done uuid
        continue finish

  setPhase handle $ \(DrivePowerChange{..}) -> do
    when dpcPowered . fork CopyNewerBuffer $ do
      put Local $ (Just (dpcUUID, dpcDevice), Nothing)
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
          (Just (uuid, _), _) <- get Local
          checked <- checkAndHandleDriveReady dpcNode dpcDevice (done uuid >> return [finish])
          switch checked

  directly finish stop

  start handle (Nothing, Nothing)
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
ruleDriveBlip :: Definitions RC ()
ruleDriveBlip = defineSimple "castor::disk::blip"
  $ \(DriveTransient eid _ _ disk) -> do
    removed <- isStorageDriveRemoved disk
    powered <- isStorageDevicePowered disk
    unless (removed || not powered) $ do
      mm0sdev <- lookupStorageDeviceSDev disk
      forM_ mm0sdev $ \sd -> do
        applyStateChanges [ stateSet sd Tr.sdevFailTransient]
    messageProcessed eid

-- | Fires when a drive is marked as 'ready' for use. This is typically
--   caused by a DriveManager message which indicates that the OS can now
--   see and interract with the drive.
ruleDriveOK :: Definitions RC ()
ruleDriveOK = define "castor::disk::ready" $ do
  handle <- phaseHandle "Drive ready event received"

  checkAndHandleDriveReady <-
    mkCheckAndHandleDriveReady _2
      $ \_ -> do
        (Just (eid,_), _) <- get Local
        messageProcessed eid

  setPhase handle $ \(DriveOK eid node _ disk) -> do
    put Local $ (Just (eid, disk), Nothing)
    checked <- checkAndHandleDriveReady node disk (messageProcessed eid >> return [])
    switch checked

  start handle (Nothing, Nothing)

-- | When a drive is marked as failed, power it down.
rulePowerDownDriveOnFailure :: Definitions RC ()
rulePowerDownDriveOnFailure = define "power-down-drive-on-failure" $ do

  m0_drive_failed <- phaseHandle "m0_drive_failed"

  setPhaseInternalNotification m0_drive_failed
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
