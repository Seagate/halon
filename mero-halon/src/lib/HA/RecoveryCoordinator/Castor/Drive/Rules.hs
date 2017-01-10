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
  ) where

import           Control.Distributed.Process hiding (catch)
import           Control.Lens
import           Control.Monad
import           Control.Monad.Trans.Maybe
import           Data.Foldable (for_)
import           Data.Maybe
import qualified Data.Text as T
import qualified Data.UUID as UUID
import           Data.UUID.V4 (nextRandom)
import           HA.RecoveryCoordinator.Actions.Hardware
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Castor.Cluster.Events (PoolRebalanceRequest(..))
import           HA.RecoveryCoordinator.Castor.Drive.Actions
import           HA.RecoveryCoordinator.Castor.Drive.Events
import           HA.RecoveryCoordinator.Castor.Drive.Rules.Internal
import qualified HA.RecoveryCoordinator.Castor.Drive.Rules.Raid as Raid
import qualified HA.RecoveryCoordinator.Castor.Drive.Rules.Repair as Repair
import           HA.RecoveryCoordinator.Castor.Drive.Rules.Reset as Reset
import qualified HA.RecoveryCoordinator.Castor.Drive.Rules.Smart as Smart
import           HA.RecoveryCoordinator.Job.Actions
import           HA.RecoveryCoordinator.Job.Events
import           HA.RecoveryCoordinator.Mero.Events
import           HA.RecoveryCoordinator.Mero.Notifications
import           HA.RecoveryCoordinator.Mero.State
import qualified HA.RecoveryCoordinator.Hardware.StorageDevice.Actions as StorageDevice
import qualified HA.RecoveryCoordinator.Mero.Transitions as Tr
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import           HA.Resources
import           HA.Resources.Castor
import           HA.Resources.HalonVars
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero hiding (Enclosure, Node, Process, Rack, Process)
import           HA.Resources.Mero.Note
import           HA.Services.SSPL
import           Network.CEP
import           Text.Printf (printf)

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
  let location l = l ^? smartLens . _Just . chsLocation

  let post_process m0sdev = do
        Just sdev <- getter <$> get Local
        markSDevReplaced m0sdev
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

  (device_attached, deviceAttach) <- mkAttachDisk
    (fmap join . traverse (lookupStorageDeviceSDev) . getter)
    (\sdev e -> do
       Log.rcLog' Log.ERROR e
       post_process sdev)
    (\m0sdev -> do
       Just sdev <- getter <$> get Local  
       attachStorageDeviceToSDev sdev m0sdev
       post_process m0sdev)

  setPhaseIf sync_complete
    (\(SyncComplete request) _ l -> return $
        let Just req = (\x -> x ^. chsSyncRequest) =<< (l ^. smartLens)
        in if (req == request) then (Just ()) else Nothing
      )
    $ \() -> do
       Just disk <- getter <$> get Local
       lookupStorageDeviceSDev disk >>= \case
         Nothing -> return ()
         Just sdev -> do
           deviceAttach sdev
           continue device_attached

  directly smart_run $ do
    phaseLog "info" "Device ready. Running SMART test."
    Just disk <- getter <$> get Local
    Just node <- fmap (\x -> x ^. chsNode) . (\x -> x ^. smartLens) <$> get Local
    smartId <- startJob $ SMARTRequest node disk
    modify Local $ smartLens . _Just . chsSmartRequest .~ Just smartId
    continue smart_result

  setPhaseIf smart_result onSameSdev $ \status -> do
    Just sdev <- getter <$> get Local
    Just loc  <- location <$> get Local
    Log.rcLog' Log.DEBUG [("smart.response", show status)]
    smartSuccess <- case status of
      SRSSuccess -> return True
      SRSNotAvailable -> do
        Log.rcLog' Log.DEBUG "SMART functionality not available."
        return True
      _ -> do
        Log.rcLog' Log.DEBUG "Unsuccessful SMART test."
        return False
    if smartSuccess
    then lookupLocationSDev loc >>= \case
      Nothing -> promulgateRC $ DriveReady sdev
      Just m0sdev -> do 
        mm0sdev <- lookupStorageDeviceSDev sdev
        unless (Just m0sdev == mm0sdev) $ do
          request <- liftIO $ nextRandom
          modify Local $ smartLens . _Just . chsSyncRequest .~ Just request
          registerSyncGraphProcess $ \self -> usend self (request, SyncToConfdServersInRG)
        continue sync_complete
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

  return $ \node disk onFailure -> do
    reset   <- hasOngoingReset disk
    powered <- StorageDevice.isPowered disk
    StorageDeviceStatus status _ <- StorageDevice.status disk

    StorageDevice.location disk >>= \case
      Just loc | not reset && powered && status == "OK" -> do
        current_m0sdev <- lookupStorageDeviceSDev disk
        disk_path <- StorageDevice.path disk
        rg <- getLocalGraph
        case  current_m0sdev of
          Just sdev | Just (M0.d_path sdev) == disk_path
                    , SDSUnknown == getState sdev rg
                    -> do
            Log.rcLog' Log.DEBUG "Device is already attached."
            applyStateChanges [ stateSet sdev Tr.sdevReady]
            onFailure
          Just sdev | Just (M0.d_path sdev) == disk_path 
                    , SDSOnline == getState sdev rg
                    -> do
            Log.rcLog' Log.DEBUG "Device is already attached and online."
            onFailure
          _ -> do
            modify Local $ smartLens .~ Just (CheckAndHandleState node disk loc Nothing Nothing)
            return [smart_run]
      Nothing -> do
        Log.rcLog' Log.ERROR $ "Device is not inserted."
        onFailure
      _ -> do
        -- The drive wasn't ready so just run user callback: let's say
        -- reset is still on-going; reset rule will take care of
        -- attaching the drive and performing the state transition so
        -- don't worry about it here.
        Log.rcLog' Log.DEBUG [ ("Device not ready", show disk)
                             , ("Reset ongoing", show reset)
                             , ("Powered:", show powered)
                             , ("Status:", status)
                             ]
        onFailure

-- | Removing drive:
-- We need to notify mero about drive state change and then send event to the logger.
ruleDriveRemoved :: Definitions RC ()
ruleDriveRemoved = define "drive-removed" $ do
  pinit   <- phaseHandle "init"
  finish   <- phaseHandle "finish"
  reinsert <- phaseHandle "reinsert"
  removal  <- phaseHandle "removal"

  let post_process m0sdev = do
        applyStateChanges [stateSet m0sdev Tr.sdevFailTransient]
        t <- getHalonVar _hv_drive_removal_timeout
        switch [reinsert, timeout t removal]

  (device_detached, detachDisk) <- mkDetachDisk
    (return . fmap (\(_,_,_,d) -> d))
    (\sdev e -> do phaseLog "warning" e
                   post_process sdev)
    post_process

  setPhase pinit $ \(DriveRemoved uuid _ (Slot enc loc) disk _) -> do
    sd <- lookupStorageDeviceSDev disk
    forM_ sd $ \m0sdev -> fork CopyNewerBuffer $ do
      Log.tagContext Log.SM uuid Nothing
      Log.tagContext Log.SM disk Nothing
      put Local $ Just (enc, disk, loc, m0sdev)
      detachDisk m0sdev
      continue device_detached

  setPhaseIf reinsert
   (\(DriveInserted{diLocation=Slot enc loc}) _ (Just (enc', _, loc', _)) -> do
      if enc == enc' && loc == loc'
         then return (Just ())
         else return Nothing
      )
   $ \() -> do
      Log.rcLog' Log.DEBUG "cancel drive removal procedure"
      continue finish

  directly finish $ stop

  directly removal $ do
    Just (_, _, _, m0sdev) <- get Local
    Log.rcLog' Log.DEBUG "Notifying M0_NC_FAILED for sdev"
    applyStateChanges [stateSet m0sdev Tr.sdevFailFailed]
    continue finish

  startFork pinit Nothing

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

  setPhase handler $ \di ->
    fork CopyNewerBuffer $ do
       put Local $ (Just (UUID.nil, di), Nothing)
       Log.tagContext Log.SM (diUUID di) Nothing
       Log.tagContext Log.SM (diDevice di) Nothing
       t <- getHalonVar _hv_drive_insertion_timeout
       switch [ removed
              , inserted
              , timeout t main]

  setPhaseIf removed
    (\(DriveRemoved{drLocation=Slot enc loc}) _
      (Just (_,DriveInserted{diLocation=Slot enc' loc'
                            }), _) -> do
       if enc == enc' && loc == loc'
          then return $ Just ()
          else return Nothing)
    $ \() -> do
        phaseLog "debug" "cancel drive insertion procedure due to drive removal."
        continue finish

  -- If for some reason new Inserted event will be received during a timeout
  -- we need to cancel current procedure and allow new procedure to continue.
  -- Theoretically it's impossible case as before each insertion removal should
  -- go. However we add this case to cover scenario when other subsystems do not
  -- work perfectly and do not issue DriveRemoval first.
  setPhaseIf inserted
    (\(DriveInserted{diLocation=Slot enc loc}) _
      (Just (_, DriveInserted{diLocation=Slot enc' loc'}), _) -> do
        if enc == enc' && loc == loc'
           then return (Just ())
           else return Nothing)
    $ \() -> do
        phaseLog "info" "cancel drive insertion procedure due to new drive insertion."
        continue finish

  checkAndHandleDriveReady <- mkCheckAndHandleDriveReady _2 (\_ -> continue finish)

  directly main $ do
    (Just (_, DriveInserted{ diNode = node
                           , diDevice = disk
                           , diPowered = powered
                           }), _) <- get Local
    if powered
    then StorageDevice.poweron disk
    else StorageDevice.poweroff disk
    checked <- checkAndHandleDriveReady node disk (return [finish])
    switch checked

  directly finish $ stop

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
      let Node nid = dpcNode
          StorageDevice serial = dpcDevice
          dpcSerial = T.pack serial
      Log.tagContext Log.SM dpcDevice Nothing
      Log.tagContext Log.SM dpcUUID   Nothing
      put Local $ (Just (dpcUUID, dpcDevice, nid, dpcSerial), Nothing)
      StorageDevice.poweroff dpcDevice

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
                          ++ (show serial)
        continue power_removed_duration

  checkAndHandleDriveReady <-
    mkCheckAndHandleDriveReady _2
      $ \_ -> do
        (Just (uuid, _, _, _), _) <- get Local
        done uuid
        continue finish

  setPhaseIf power_returned (power_on `gAnd` matching_device)
    $ \(DrivePowerChange{..}) -> do
      Log.rcLog' Log.DEBUG "Device has been repowered."
      StorageDevice.poweron dpcDevice
      (Just (uuid, _, _, _), _) <- get Local
      checked <- checkAndHandleDriveReady dpcNode dpcDevice (done uuid >> return [finish])
      switch checked

  directly power_removed_duration $ do
    (Just (_, dpcDevice, _, _), _) <- get Local

    -- Mark Mero device as permanently failed
    mm0sdev <- lookupStorageDeviceSDev dpcDevice
    forM_ mm0sdev $ \m0sdev -> do
      applyStateChanges [stateSet m0sdev Tr.sdevFailFailed]
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
      $ \_ -> continue finish

  setPhase handle $ \(DrivePowerChange{..}) -> do
    when dpcPowered . fork CopyNewerBuffer $ do
      Log.tagContext Log.SM dpcUUID   Nothing
      Log.tagContext Log.SM dpcDevice Nothing
      put Local $ (Just (dpcUUID, dpcDevice), Nothing)
      StorageDevice.poweron dpcDevice
      realFailure <- isRealFailure <$> StorageDevice.status dpcDevice
      unless realFailure $ do
        m0sdev <- lookupLocationSDev dpcLocation
        for_ m0sdev $ \sdev ->
          m0failed . getState sdev <$> getLocalGraph >>= \case
            False -> Log.rcLog' Log.ERROR "Can't find mero drive."
            True  -> do
              Log.tagContext Log.SM sdev Nothing
              Log.rcLog' Log.DEBUG 
                "Failed device with no underlying failure has been repowered. Marking as replaced."
              checked <- checkAndHandleDriveReady dpcNode dpcDevice (return [finish])
              switch checked
      continue finish

  directly finish stop

  start handle (Nothing, Nothing)
  where
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
    powered <- StorageDevice.isPowered disk
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

  checkAndHandleDriveReady <- mkCheckAndHandleDriveReady _2 $ \_ -> return ()

  setPhase handle $ \(DriveOK eid node _ disk) -> do
    Log.tagContext Log.SM eid Nothing
    put Local $ (Just (eid, disk), Nothing)
    checked <- checkAndHandleDriveReady node disk (return [])
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
        sdev@(StorageDevice serial) <- MaybeT $ lookupStorageDevice m0sdev
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
