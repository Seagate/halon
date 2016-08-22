{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE DataKinds  #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Module dealing with pool repair and rebalance.
--
-- What are the conditions under which we can start repair?
--
-- What are the conditions under which we can start rebalance?
-- TODO We do not need to use repair status query periodically because we
--      expect process failure notification and progress notifications.
--
-- TODO: Only abort repair on notification failure if it's IOS that failed
module HA.RecoveryCoordinator.Rules.Castor.Disk.Repair
  ( handleRepairInternal
  , handleRepairExternal
  , ruleRebalanceStart
  , ruleRepairStart
  , noteToSDev
  , querySpiel
  , querySpielHourly
  , checkRepairOnClusterStart
  , checkRepairOnServiceUp
  , ruleSNSOperationAbort
  ) where

import           Control.Applicative
import           Control.Arrow (second)
import           Control.Distributed.Process
import           Control.Exception (SomeException)
import           Control.Lens
import           Control.Monad
import           Control.Monad.Trans
import           Control.Monad.Trans.Maybe
import qualified Data.Binary as B
import           Data.Either (partitionEithers)
import           Data.Foldable
import qualified Data.HashSet as S
import qualified Data.Map as M
import qualified Data.Set as Set
import           Data.Maybe (catMaybes, fromMaybe, listToMaybe)
import           Data.Proxy
import qualified Data.Text as T
import           Data.Monoid ((<>))
import           Data.Typeable (Typeable)
import           Data.UUID (nil)
import           Data.Vinyl
import           GHC.Generics (Generic)

import           HA.EventQueue.Producer
import           HA.EventQueue.Types
import qualified HA.ResourceGraph as G
import           HA.RecoveryCoordinator.Actions.Castor.Cluster (barrierPass)
import           HA.RecoveryCoordinator.Actions.Core
import           HA.RecoveryCoordinator.Actions.Job
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Mero
import           HA.RecoveryCoordinator.Events.Castor.Cluster
import           HA.RecoveryCoordinator.Events.Mero
import qualified HA.RecoveryCoordinator.Rules.Castor.Disk.Repair.Internal as R
import HA.RecoveryCoordinator.Rules.Mero.Conf
  ( applyStateChanges
  , setPhaseAllNotified
  , setPhaseInternalNotificationWithState
  , setPhaseNotified
  )
import           HA.Services.SSPL.CEP
import           HA.Resources
import           HA.Resources.Castor
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero
  hiding (Enclosure, Process, Rack, Process, lookupConfObjByFid)
import           HA.Resources.Mero.Note
import           HA.Services.Mero
import           Mero.Notification hiding (notifyMero)
import           Mero.Notification.HAState (Note(..))
import           Mero.ConfC (ServiceType(CST_IOS))
import qualified Mero.Spiel as Spiel
import           Network.CEP
import           Debug.Trace (traceEventIO)
import           Prelude

--------------------------------------------------------------------------------
-- Queries                                                               --
--------------------------------------------------------------------------------

-- | Event sent when we want a 5 minute spiel query rule to fire
data SpielQuery = SpielQuery Pool M0.PoolRepairType UUID
  deriving (Eq, Show, Generic, Typeable)

instance B.Binary SpielQuery

-- | Event sent when we want a 60 minute repeated query rule to fire
data SpielQueryHourly = SpielQueryHourly Pool M0.PoolRepairType UUID
  deriving (Eq, Show, Generic, Typeable)

instance B.Binary SpielQueryHourly

-- | Handler for @M0_NC_ONLINE@ 'Pool' messages. Its main role is to
-- check whether we need to wait for more messages and if yes,
-- dispatch queries to SSPL after a period of time through
-- 'querySpiel'. As we do not receive information as to what type of
-- message this is about, we use previously stored 'M0.PoolRepairType'
-- to help us out.
queryStartHandling :: M0.Pool -> PhaseM LoopState l ()
queryStartHandling pool = do
  possiblyInitialisePRI pool
  incrementOnlinePRSResponse pool
  M0.PoolRepairStatus prt ruuid (Just pri) <- getPoolRepairStatus pool >>= \case
    Nothing -> do
      let err = "In queryStartHandling for " ++ show pool ++ " without PRS set."
      phaseLog "error" err
      return $ error err
    Just prs -> do
      phaseLog "info" $ "PoolRepairStatus = " ++ show prs
      return prs

  iosvs <- length <$> R.getIOServices pool

  -- Ask for status always.
  onlines <- R.repairStatus prt pool >>= \case
    Left e -> do
      phaseLog "warn" $ "repairStatus " ++ show prt ++ " failed: " ++ show e
      -- we use priOnlineNotifications as a fallback here and we may
      -- want to do something better in case R.repairStatus fails but
      -- priOnlineNotifications has one more use, see [Note multipleIOS]
      return $ priOnlineNotifications pri
    Right sts -> return . length $ R.filterCompletedRepairs sts
  if -- Everything is repaired. Running timeouts keep running but
     -- 'completeRepair' will remove the repair information with given
     -- UUID they expect so they will simply die when it's their time
     -- to fire.
     | onlines == iosvs -> completeRepair pool prt Nothing
     -- This is the first of many notifications, start query in 5
     -- minutes.
     --
     -- [Note multipleIOS]
     -- We don't use ‘onlines’ here: consider the case where we
     -- receive our first notification and enter queryStartHandling
     -- for the first time but in the meantime, more than one IOS has
     -- finished repair. In this case ’onlines > 1’ and we can't
     -- decide whether we have dispatched SpielQuery. The obvious
     -- solution is to record in RG whether we have already started
     -- the query and use that to decide. But we already do except not
     -- explicitly: if we check ‘priOnlineNotifications’, we
     -- effectively find out how many times we entered
     -- queryStartHandling so we can determine when we have entered it
     -- for the first time and therefore can decide if we should
     -- dispatch a query.
     | priOnlineNotifications pri == 1 && iosvs > 1 ->
         promulgateRC $ SpielQuery pool prt ruuid

     -- This is not the first notification and also we haven't yet
     -- finished repair so do nothing and let the running queries or
     -- future notifications deal with it.
     | otherwise -> return ()

-- | This function does basic checking of whether we're done
-- repairing/rebalancing as well as handling time related matters.
--
-- Check if have received all online messages we were expecting.
--
-- If yes, notify about success and finish repair/rebalance.
--
-- If not, calculate the amount of time we have to wait until the next
-- query. Currently it's 5 minutes since the last query. Note that
-- when we enter this rule, the time since last query is the same as
-- the time that we received the first online notification, set by
-- 'incrementOnlinePRSResponse'. This ensure that we don't query
-- immediately after we receive the first status message. 'timeout'
-- for constant amount of time here is not good enough in case RC dies
-- in the middle of the wait.
--
-- When time to query comes, check the pool repair information again
-- to make sure the repair hasn't finished while we were waiting. If
-- it has, do nothing except mark message as processed.
--
-- This query is only ran once. If we're not finished repairing by
-- time we query spiel, we dispatch 'querySpielHourly' and finish the
-- rule.
--
-- TODO Can we remove these?
querySpiel :: Specification LoopState ()
querySpiel = define "query-spiel" $ do
  dispatchQuery <- phaseHandle "dispatch-query"
  runQuery <- phaseHandle "run-query"

  setPhase dispatchQuery $ \(HAEvent uid (SpielQuery pool prt ruuid) _) -> do
    put Local $ Just (uid, pool, prt, ruuid)
    getPoolRepairInformation pool >>= \case
      Nothing -> unsetPoolRepairStatusWithUUID pool ruuid
      Just pri -> do
        timeNow <- liftIO getTime
        let elapsed = timeNow - priTimeOfFirstCompletion pri
            untilTimeout = M0.mkTimeSpec 300 - elapsed
        iosvs <- length <$> R.getIOServices pool
        if priOnlineNotifications pri < iosvs
        then switch [timeout (timeSpecToSeconds untilTimeout) runQuery]
        else completeRepair pool prt $ Just uid

  directly runQuery $ do
    Just (uid, pool, prt, ruuid) <- get Local
    keepRunning <- getPoolRepairStatus pool >>= return . \case
      Nothing -> False
      Just prs -> prsRepairUUID prs == ruuid

    when keepRunning $ do
      iosvs <- length <$> R.getIOServices pool
      withRepairStatus prt pool uid $ \sts -> do
        let onlines = length $ R.filterCompletedRepairs sts
        modifyPoolRepairInformation pool $ \pri ->
          pri { priOnlineNotifications = onlines }
        updatePoolRepairStatusTime pool
        if onlines < iosvs
        then liftProcess . promulgateWait $ SpielQueryHourly pool prt ruuid
        else completeRepair pool prt $ Just uid
    phaseLog "repair" $ "First query for pool " ++ show pool ++ " terminating."

  start dispatchQuery Nothing

-- | This rule works in similar fashion to 'querySpiel' with the main difference
-- that:
--
-- * it runs hourly
-- * it runs until repairs complete
querySpielHourly :: Specification LoopState ()
querySpielHourly = define "query-spiel-hourly" $ do
  dispatchQueryHourly <- phaseHandle "dispatch-query-hourly"
  runQueryHourly <- phaseHandle "run-query-hourly"

  setPhase dispatchQueryHourly $ \(HAEvent uid (SpielQueryHourly pool prt ruuid) _) -> do
    t <- getTimeUntilQueryHourlyPRI pool
    put Local $ Just (uid, pool, prt, ruuid)
    phaseLog "repair" $ "Running hourly query in " ++ show t ++ " seconds."
    switch [timeout t runQueryHourly]

  directly runQueryHourly $ do
    Just (uid, pool, prt, ruuid) <- get Local
    keepRunning <- getPoolRepairStatus pool >>= return . \case
      Nothing -> False
      Just prs -> prsRepairUUID prs == ruuid
    when keepRunning $ do
      iosvs <- length <$> R.getIOServices pool
      Just pri <- getPoolRepairInformation pool
      case priOnlineNotifications pri < iosvs of
        False -> completeRepair pool prt (Just uid)
        True -> withRepairStatus prt pool uid $ \sts -> do
          -- is 'filterCompletedRepairs' relevant for rebalancing too?
          -- If not, how do we handle this query?
          let onlines = length $ R.filterCompletedRepairs sts
          modifyPoolRepairInformation pool $ \pri' ->
            pri' { priOnlineNotifications = onlines }
          updatePoolRepairStatusTime pool
          if onlines < iosvs
          then do t <- getTimeUntilQueryHourlyPRI pool
                  switch [timeout t runQueryHourly]
          else completeRepair pool prt (Just uid)
    phaseLog "repair" $ "Hourly query for pool " ++ show pool ++ " terminating."
    messageProcessed uid

  start dispatchQueryHourly Nothing

ruleRebalanceStart :: Specification LoopState ()
ruleRebalanceStart = define "castor-rebalance-start" $ do
  init_rule <- phaseHandle "init_rule"
  wait_abort <- phaseHandle "wait_abort"
  pool_disks_notified <- phaseHandle "pool_disks_notified"
  notify_failed <- phaseHandle "notify_failed"
  notify_timeout <- phaseHandle "notify_timeout"

  setPhase init_rule $ \(HAEvent uuid (PoolRebalanceRequest pool) _) ->
    getPoolRepairInformation pool >>= \case
      Nothing -> do
       rg <- getLocalGraph
       sdevs <- getPoolSDevs pool
       sts <- mapM (\d -> (,d) <$> getSDevState d) sdevs
       -- states that are considered as ‘OK, we can finish
       -- repair/rebalance’ states for the drives
       let okMessages = [M0_NC_REPAIRED, M0_NC_ONLINE]
        -- list of devices in OK state
           sdev_repaired = snd <$> filter (\(typ, _) -> typ == M0_NC_REPAIRED) sts
           (sdev_notready, sdev_ready) = partitionEithers $ (deviceReadyStatus rg) <$> sdev_repaired
           sdev_broken   = snd <$> filter (\(typ, _) -> not $ typ `elem` okMessages) sts
       for_ sdev_notready $ phaseLog "info"
       if null sdev_broken
       then if null sdev_ready
             then do phaseLog "info" $ "Can't start rebalance, no drive to rebalance on"
                     messageProcessed uuid
             else do
              disks <- catMaybes <$> mapM lookupSDevDisk sdev_ready
              let messages = stateSet pool M0_NC_REBALANCE : (flip stateSet M0.SDSRebalancing <$> disks)
              put Local $ Just (uuid, messages, Just (pool, disks))
              applyStateChanges messages
              switch [pool_disks_notified, notify_failed, timeout 10 notify_timeout]

       else do phaseLog "info" $ "Can't start rebalance, not all drives are ready: " ++ show sdev_broken
               messageProcessed uuid
      Just info -> do
        phaseLog "info" $ "Pool Rep/Reb is already running: " ++ show info
        promulgateRC (AbortSNSOperation pool)
        messageProcessed uuid

  setPhase wait_abort $ \result -> do
    case result of
      AbortSNSOperationOk pool -> promulgateRC (PoolRebalanceRequest pool)
      AbortSNSOperationFailure _ -> return ()
      AbortSNSOperationSkip pool -> promulgateRC (PoolRebalanceRequest pool)

  let viewNS :: Lens' (Maybe (a, [AnyStateSet], b)) (Maybe [AnyStateSet])
      viewNS = lens lget lset where
        lget ms = (\(_, ns, _) -> ns) <$> ms
        lset Nothing _ = Nothing
        lset (Just (a, _, b)) x = Just (a, fromMaybe [] x, b)

  setPhaseAllNotified pool_disks_notified viewNS $ do
    Just (uuid, _, Just (pool, disks)) <- get Local
    startRebalanceOperation pool disks
    queryStartHandling pool
    messageProcessed uuid

  -- Check if it's IOS that failed, if not then just keep going
  -- XXX: I'm not sure that logic is correct here
  setPhase notify_failed $ \(HAEvent uuid' (NotifyFailureEndpoints eps) _) -> do
    todo uuid'
    rg <- getLocalGraph
    case R.failedNotificationIOS eps rg of
      [] -> get Local >>= \(Just (uuid, _, _)) -> messageProcessed uuid
      ps -> do
        phaseLog "warn" $ "Aborting rebalance as IOS failed: " ++ show ps
        runAbort
    done uuid'

  directly notify_timeout $ do
    phaseLog "warn" $ "Unable to notify Mero; cannot start rebalance"
    runAbort

  start init_rule Nothing

  where
    runAbort = get Local >>= \case
      Nothing -> phaseLog "warn" $ "no local state"
      Just (uuid, _, mp) -> do
        case mp of
          Nothing -> phaseLog "error" "No pool info in local state"
          Just (pool, _) -> do
            ds <- getPoolSDevsWithState pool M0_NC_REBALANCE
            applyStateChanges $ map (\d -> stateSet d M0.SDSFailed) ds
        messageProcessed uuid

    -- Is this device ready to be rebalanced onto?
    deviceReadyStatus :: G.Graph -> M0.SDev -> Either String M0.SDev
    deviceReadyStatus rg s = case stats of
        [(_, True, False, True, "OK")] -> Right s
        [other] -> Left $ "Device not ready: " ++ showFid s
                      ++ " (sdev, Replaced, Removed, Powered, OK): "
                      ++ show other
        [] -> Left $ "No storage device or status could be found for " ++ showFid s
        xs -> Left $ "Device has multiple storage devices connected! " ++ show xs
      where
        stats = [ ( sd
                  , G.isConnected sd Has SDReplaced rg
                  , G.isConnected sd Has SDRemovedAt rg
                  , G.isConnected sd Has (SDPowered True) rg
                  , sds
                  )
                | (disk :: M0.Disk) <- G.connectedTo s M0.IsOnHardware rg
                , (sd :: StorageDevice) <- G.connectedTo disk At rg
                , (StorageDeviceStatus sds _) <- G.connectedTo sd Is rg
                ]

    getSDevState :: M0.SDev -> PhaseM LoopState l' ConfObjectState
    getSDevState d = getConfObjState d <$> getLocalGraph

-- | Possibly start repair on the given pool and disks.
ruleRepairStart :: Specification LoopState ()
ruleRepairStart = define "castor-repair-start" $ do
  init_rule <- phaseHandle "init_rule"
  pool_disks_notified <- phaseHandle "'pool_disks_notified"
  notify_failed <- phaseHandle "notify_failed"
  notify_timeout <- phaseHandle "notify_timeout"

  setPhase init_rule $ \(HAEvent uuid (PoolRepairRequest pool) _) -> do
    getPoolRepairInformation pool >>= \case
      Nothing -> do
        fa <- getPoolSDevsWithState pool M0_NC_FAILED
        phaseLog "repair" $ "Starting repair operation on " ++ show pool
        let msgs = stateSet pool M0_NC_REPAIR : (flip stateSet M0.SDSRepairing <$> fa)
        put Local $ Just (uuid, msgs, Just pool)
        applyStateChanges msgs
        switch [pool_disks_notified, notify_failed, timeout 10 notify_timeout]
      Just _ -> messageProcessed uuid

  let viewNS :: Lens' (Maybe (a, [AnyStateSet], b)) (Maybe [AnyStateSet])
      viewNS = lens lget lset where
        lget ms = (\(_, ns, _) -> ns) <$> ms
        lset Nothing _ = Nothing
        lset (Just (a, _, b)) x = Just (a, fromMaybe [] x, b)

  setPhaseAllNotified pool_disks_notified viewNS $ do
    Just (uuid, _, Just pool) <- get Local
    startRepairOperation pool
    queryStartHandling pool
    messageProcessed uuid

  -- Check if it's IOS that failed, if not then just keep going
  setPhase notify_failed $ \(HAEvent uuid' (NotifyFailureEndpoints eps) _) -> do
    todo uuid'
    rg <- getLocalGraph
    case R.failedNotificationIOS eps rg of
      [] -> get Local >>= \(Just (uuid, _, _)) -> messageProcessed uuid
      ps -> do
        phaseLog "warn" $ "Aborting repair as IOS failed: " ++ show ps
        runAbort
    done uuid'

  -- Failure endpoint message didn't come and notification didn't go
  -- through either, abort just in case.
  directly notify_timeout $ do
    phaseLog "warn" $ "Unable to notify Mero; cannot start repair"
    runAbort

  start init_rule Nothing

  where
    runAbort = get Local >>= \case
      Nothing -> phaseLog "warn" $ "no local state"
      Just (uuid, _, mp) -> do
        case mp of
          Nothing -> phaseLog "error" "No pool info in local state"
          -- HALON-275: We have failed to start the repair so
          -- clean up repair status. halon:m0d should notice that
          -- notification has failed and fail the process, restart
          -- should happen and repair eventually restarted if
          -- everything goes right
          Just pool -> do
            ds <- getPoolSDevsWithState pool M0_NC_REPAIR
            -- There may be a race here: either this notification
            -- tries to go out first or the rule for failed
            -- notification fires first. The race does not matter
            -- because notification failure handler will check for
            -- already failed processes.
            applyStateChanges $ map (\d -> stateSet d M0.SDSFailed) ds
        messageProcessed uuid

-- | Try to fetch 'Spiel.SnsStatus' for the given 'Pool' and if that
-- fails, unset the @PRS@ and ack the message. Otherwise run the
-- user-supplied handler.
withRepairStatus :: PoolRepairType -> Pool -> UUID
                 -> ([Spiel.SnsStatus] -> PhaseM LoopState l ())
                 -> PhaseM LoopState l ()
withRepairStatus prt pool uid f = R.repairStatus prt pool >>= \case
  Left e -> do
    liftProcess . sayRC $ "repairStatus " ++ show prt ++ " failed: " ++ show e
    updatePoolRepairStatusTime pool
    messageProcessed uid
  Right sts -> f sts

--------------------------------------------------------------------------------
-- Actions                                                                    --
--------------------------------------------------------------------------------

-- | Continue a previously-quiesced repair.
continueRepair :: M0.Pool
                  -- ^ Pool under repair
               -> M0.PoolRepairType
               -> PhaseM LoopState l ()
continueRepair pool prt = repairHasQuiesced pool prt >>= \case
  Left e -> phaseLog "repair" $ "queryContinueRepair: failed repair status: "
                             ++ show e
  Right True -> do
    R.continueRepair prt pool >>= \case
      Nothing -> return ()
      Just e -> phaseLog "repair" $ "Repair continue failed with " ++ show e
  Right False ->
    phaseLog "repair" $ "queryContinueRepair: repair not quiesced, not contunuing"

-- | Quiesce the repair on the given pool if the repair is on-going.
--
-- Tell spiel to quiesce and mark the given set of 'M0.SDev's
-- 'M0_NC_TRANSIENT' internally so we can track drives as they come
-- back up online and know when to continue repair. We don't have to
-- do much else, the regular spiel queries can run as usual because
-- the repair states will come back as 'M0_SNS_CM_STATUS_PAUSED' so
-- the repair won't finish and they'll just keep running until either
-- we 'queryContinueRepair' and everything completes fine or something
-- fails and we kill them during halt.
quiesceRepair :: M0.Pool
              -- ^ Pool under repair
              -> M0.PoolRepairType
              -- ^ Rebalance/repair?
              -> PhaseM LoopState l ()
quiesceRepair pool prt = repairHasQuiesced pool prt >>= \case
  -- We may have quiesced before. We could check the stored disk map
  -- here but in case of RC death we might have quiesced but lost the
  -- graph update. Therefore we ask for repair status explicitly and
  -- check if any status comes back as PAUSED, in which case we know
  -- quiesce has happened.
  Right False -> do
    phaseLog "repair" $ "Quescing repair operation on " ++ show pool
    R.quiesceRepair prt pool >>= \case
      Nothing -> return ()
      Just e -> phaseLog "repair" $ "Repair quiesce failed with " ++ show e
  Right True -> do
    phaseLog "repair" $ "queryQuiesceRepair: "
                     ++ show pool ++ " already quiesced."
  Left e -> phaseLog "repair" $ "queryQuiesceRepair: failed repair status: "
                               ++ show e

-- | Abort current SNS operation. Rule requesting SNS operation abort
-- and waiting for all IOs to be finalized.
jobSNSAbort :: Job AbortSNSOperation AbortSNSOperationResult
jobSNSAbort = Job "castor::node::sns::abort"

ruleSNSOperationAbort :: Definitions LoopState ()
ruleSNSOperationAbort = mkJobRule jobSNSAbort args $ \finish -> do
  entry <- phaseHandle "entry"
  await <- phaseHandle "await"
  ok    <- phaseHandle "ok"

  let route (AbortSNSOperation pool) = getPoolRepairStatus pool >>= \case
        Nothing -> do
          phaseLog "repair" $ "Abort requested on " ++ show pool
                           ++ "but no repair seems to be happening."
          modify Local $ rlens fldRep .~ (Field . Just $ AbortSNSOperationSkip pool)
          return $ Just [finish]
        Just (M0.PoolRepairStatus prt uuid _) -> do
          modify Local $ rlens fldPrt .~ (Field . Just $ prt)
          modify Local $ rlens fldUUID .~ (Field . Just $ uuid)
          return $ Just [entry]

  directly entry $ do
    Just (AbortSNSOperation pool) <- getField . rget fldReq <$> get Local
    Just prt <- getField . rget fldPrt <$> get Local
    case prt of
      M0.Failure -> abortRepairOperation pool
      M0.Rebalance -> abortRebalanceOperation pool
    continue await

  directly await $ do
    Just (AbortSNSOperation pool) <- getField . rget fldReq <$> get Local
    Just prt <- getField . rget fldPrt <$> get Local
    eresult <- case prt of
      M0.Rebalance -> statusOfRebalanceOperation pool
      M0.Failure -> statusOfRepairOperation pool
    case eresult of
      Left e -> do
        modify Local $ rlens fldRep .~ (Field . Just $ AbortSNSOperationFailure $ show e)
        continue finish
      Right xs -> do
        if all ((`elem` [Spiel.M0_SNS_CM_STATUS_IDLE
                        ,Spiel.M0_SNS_CM_STATUS_FAILED])
                . Spiel._sss_state) xs
        then continue ok
        else continue (timeout 5 await)

  directly ok $ do
    Just (AbortSNSOperation pool) <- getField . rget fldReq <$> get Local
    Just uuid <- getField . rget fldUUID <$> get Local
    unsetPoolRepairStatusWithUUID pool uuid
    modify Local $ rlens fldRep .~ (Field . Just $ AbortSNSOperationOk pool)
    continue finish

  return route
  where
    fldReq :: Proxy '("request", Maybe AbortSNSOperation)
    fldReq = Proxy
    fldRep :: Proxy '("reply", Maybe AbortSNSOperationResult)
    fldRep = Proxy
    fldPrt :: Proxy '("prt", Maybe PoolRepairType)
    fldPrt = Proxy
    args =  fldReq  =: Nothing
        <+> fldRep  =: Nothing
        <+> fldPrt  =: Nothing
        <+> fldUUID =: Nothing
        <+> RNil

-- | Complete the given pool repair by notifying mero about all the
-- devices being repaired and marking the message as processed.
--
-- If the repair/rebalance has not finished on every device in the
-- pool, will send information about devices that did complete and
-- continue with the process.
--
-- Starts rebalance if we were repairing and have fully completed.
completeRepair :: Pool -> PoolRepairType -> Maybe UUID -> PhaseM LoopState l ()
completeRepair pool prt muid = do
  -- if no status is found for SDev, assume M0_NC_ONLINE
  let getSDevState :: M0.SDev -> PhaseM LoopState l' ConfObjectState
      getSDevState d = getConfObjState d <$> getLocalGraph

  iosvs <- length <$> R.getIOServices pool
  mdrive_updates <- fmap M0.priStateUpdates <$> getPoolRepairInformation pool
  case mdrive_updates of
    Nothing -> phaseLog "warning" $ "No pool repair information were found for " ++ show pool
    Just drive_updates -> do
      sdevs <- getPoolSDevs pool
      sts <- mapM (\d -> (,d) <$> getSDevState d) sdevs

      let -- devices that are under operation
          repairing_sdevs = Set.fromList [ d | (t,d) <- sts, t == R.repairingNotificationMsg prt]
          -- drives that were fixed during operation
          repaired_sdevs = Set.fromList [ f | (f, v) <- drive_updates, v >= iosvs]
          -- drives that are under operation but were not fixed
          non_repaired_sdevs = repairing_sdevs `Set.difference` repaired_sdevs
          repairedState M0.Rebalance = M0.SDSOnline
          repairedState M0.Failure = M0.SDSRepaired

      repaired_disks <- mapMaybeM lookupSDevDisk $ Set.toList repaired_sdevs
      unless (null repaired_sdevs) $ do

        traverse_ (\m0disk -> modifyGraph $ setState m0disk $ repairedState prt)
                  repaired_sdevs
        traverse_ (\m0disk -> modifyGraph $ setState m0disk $ repairedState prt)
                  repaired_disks
        notifyMero $ createSet ((AnyConfObj <$> Set.toList repaired_sdevs)
                    ++ (AnyConfObj <$> repaired_disks))
                    $ R.repairedNotificationMsg prt

        when (prt == M0.Rebalance) $
           forM_ repaired_sdevs $ \m0sdev -> void $ runMaybeT $ do
             sdev   <- MaybeT $ lookupStorageDevice m0sdev
             host   <- MaybeT $ listToMaybe <$> getSDevHost sdev
             serial <- MaybeT $ listToMaybe <$> lookupStorageDeviceSerial sdev
             lift $ sendLedUpdate DriveOk host (T.pack serial)

        if Set.null non_repaired_sdevs
        then do phaseLog "info" $ "Full repair on " ++ show pool
                notifyMero $ createSet [AnyConfObj pool] $ R.repairedNotificationMsg prt
                unsetPoolRepairStatus pool
                when (prt == M0.Failure) $ promulgateRC (PoolRebalanceRequest pool)
        else do phaseLog "info" $ "Some devices failed to repair: " ++ show (Set.toList non_repaired_sdevs)
                -- TODO: schedule next repair.
                unsetPoolRepairStatus pool
        traverse_ messageProcessed muid

--------------------------------------------------------------------------------
-- Main handler                                                               --
--------------------------------------------------------------------------------

-- | Dispatch appropriate repair/rebalance action as a result of the
-- notifications beign received.
--
-- TODO: add link to diagram.
--
-- TODO: Currently we don't handle a case where we have pool
-- information in the message set but also some disks which belong to
-- a different pool.
handleRepairExternal :: Set -> PhaseM LoopState l ()
handleRepairExternal noteSet = do
   liftIO $ traceEventIO "START mero-halon:external-handlers:repair-rebalance"
   getPoolInfo noteSet >>= traverse_ run
   liftIO $ traceEventIO "STOP mero-halon:external-handlers:repair-rebalance"
   where
     run (PoolInfo pool st m) = do
       phaseLog "repair" $ "Processed as PoolInfo " ++ show (pool, st, m)
       setObjectStatus pool st
       mprs <- getPoolRepairStatus pool
       forM_ mprs $ \prs@(PoolRepairStatus prt _ mpri) ->
         forM_ mpri $ \pri -> do
           let disks = getSDevs m (R.repairedNotificationMsg prt)
           let go ls d = case lookup d ls of
                           Just v -> (d,v+1):filter (\(d',_) -> d' /=d) ls
                           Nothing -> (d,1):ls
           let pst' = foldl' go (priStateUpdates pri) disks
           setPoolRepairStatus pool prs{prsPri = Just pri{priStateUpdates=pst'}}
       processPoolInfo pool st m

-- | Dispatch appropriate repair procedures based on the set of
-- internal notifications we have received.
--
-- * If any device moves to transient state - we should stop current
--   repair/rebalance procedure.
--
-- * If any device moves to failed state - we should start repair
--   process, if there are no transient devices.
--
-- * If any device moves to REPAIRED state - we should try to start
--   rebalance process, if there are no transient devices.
--
-- * Handle messages that only include information about devices and
-- not pools.
--
-- TODO Make this use `InternalStateChangeNotification`
handleRepairInternal :: Set -> PhaseM LoopState l ()
handleRepairInternal noteSet = do
  liftIO $ traceEventIO "START mero-halon:internal-handlers:repair-rebalance"
  getClusterStatus <$> getLocalGraph >>= \case
    Just (M0.MeroClusterState M0.ONLINE n _) | n >= (M0.BootLevel 1) ->
      processDevices noteSet >>= traverse_ go
    _ -> return ()
  liftIO $ traceEventIO "STOP mero-halon:internal-handlers:repair-rebalance"
  where
    -- Handle information from internal messages that didn't include pool
    -- information. That is, DevicesOnly is a list of all devices and
    -- their states that were reported in the given 'Set' message. Most
    -- commonly we'll enter here when some device changes state and
    -- RC is notified about the change.
    go (DevicesOnly devices) = do
      phaseLog "repair" $ "Processed as " ++ show (DevicesOnly devices)
      for_ devices $ \(pool, diskMap) -> do

        tr <- getPoolSDevsWithState pool M0_NC_TRANSIENT
        fa <- getPoolSDevsWithState pool M0_NC_FAILED

            -- If no devices are transient and something is failed, begin
            -- repair. It's up to caller to ensure any previous repair has
            -- been aborted/completed.
            -- TODO This is a bit crap. At least badly named. Redo it.
        let maybeBeginRepair =
              if null tr && not (null fa)
              then promulgateRC $ PoolRepairRequest pool
              else do phaseLog "repair" $ "Failed: " ++ show fa ++ ", Transient: " ++ show tr
                      maybeBeginRebalance

            -- If there are neither failed nor transient, and no new transient
            -- devices were reported we could request pool rebalance procedure start.
            -- That procedure can decide itself if there any work to do.
            maybeBeginRebalance = when (and [ null tr
                                            , S.null $ getSDevs diskMap M0_NC_FAILED
                                            , S.null $ getSDevs diskMap M0_NC_TRANSIENT
                                            ])
              $ promulgateRC (PoolRebalanceRequest pool)

        getPoolRepairStatus pool >>= \case
          Just (M0.PoolRepairStatus prt _ _)
            -- Repair happening, device failed, restart repair
            | fa' <- getSDevs diskMap M0_NC_FAILED
            , not (S.null fa') -> maybeBeginRepair
            -- Repair happening, some devices are transient
            | tr' <- getSDevs diskMap M0_NC_TRANSIENT
            , not (S.null tr') -> do
                phaseLog "repair" $ "Got M0_NC_TRANSIENT for " ++ show (pool, tr)
                                 ++ ", quescing repair."
                quiesceRepair pool prt
            -- Repair happening, something came online, check if
            -- nothing is left transient and continue repair if possible
            | Just ds <- allWithState diskMap M0_NC_ONLINE
            , ds' <- S.toList ds -> do
                sdevs <- filter (`notElem` ds') <$> getPoolSDevs pool
                sts <- getLocalGraph >>= \rg ->
                  return $ (flip getConfObjState $ rg) <$> sdevs
                if null $ filter (== M0_NC_TRANSIENT) sts
                then if prt == M0.Failure
                     then continueRepair pool prt
                     else withRepairStatus prt pool nil $ \st ->
                            -- TODO Can we make this predicate better? It's
                            -- actually testing to see whether there is any
                            -- rebalance happening, not whether there
                            -- are paused repairs.
                            if null $ R.filterPausedRepairs st
                            then promulgateRC (PoolRebalanceRequest pool)
                            else continueRepair pool prt
                else phaseLog "repair" $ "Still some drives transient: " ++ show sts
            | otherwise -> phaseLog "repair" $
                "Repair on-going but don't know what to do with " ++ show diskMap
          Nothing -> maybeBeginRepair

-- | When the cluster has completed starting up, it's possible that
--   we have devices that failed during the startup process.
checkRepairOnClusterStart :: Definitions LoopState ()
checkRepairOnClusterStart = define "check-repair-on-start" $ do
    clusterRunning <- phaseHandle "cluster-running"
    notified <- phaseHandle "mero-notification-success"
    end <- phaseHandle "end"

    setPhaseIf clusterRunning (barrierPass (\mcs -> _mcs_runlevel mcs >= M0.BootLevel 2)) $ \() -> do
      pools <- getPool
      forM_ pools $ \pool ->
        getPoolRepairStatus pool >>= \case
          Just _ -> return () -- Repair is already handled by another rule
          Nothing -> do
            tr <- getPoolSDevsWithState pool M0_NC_TRANSIENT
            fa <- getPoolSDevsWithState pool M0_NC_FAILED
            when (null tr && not (null fa)) $ do
              fork NoBuffer $ do
                put Local $ Just (pool, M0_NC_REPAIR)
                applyStateChanges (
                    stateSet pool M0_NC_REPAIR
                  : ((flip stateSet $ M0.SDSRepairing) <$> fa)
                  )
                switch [notified, timeout 10 end]

    setPhaseNotified notified (maybe Nothing return) $ \(pool, _) -> do
      startRepairOperation pool
      queryStartHandling pool
      continue end

    directly end stop

    startFork clusterRunning Nothing

-- | We have received information about a pool state change (as well
-- as some devices) so handle this here. Such a notification is likely
-- to have come from IOS indicating thigns like finished
-- repair/rebalance.
processPoolInfo :: M0.Pool
                -- ^ Pool to work on
                -> ConfObjectState
                -- ^ Status of the pool
                -> SDevStateMap
                -- ^ Status of the disks in the pool as received in a
                -- notification. Note this may not be the full set of
                -- disks belonging to the pool.
                -> PhaseM LoopState l ()

-- We are rebalancing and have received ONLINE for the pool and all
-- the devices: rebalance is finished so simply fall back to query
-- handler which will query the repair status and complete the
-- procedure.
processPoolInfo pool M0_NC_ONLINE m
  | Just _ <- allWithState m M0_NC_ONLINE = getPoolRepairStatus pool >>= \case
      Nothing -> phaseLog "warning" $ "Got M0_NC_ONLINE for a pool but "
                                   ++ "no pool repair status was found."
      Just (M0.PoolRepairStatus M0.Rebalance _ _) -> do
        phaseLog "repair" $ "Got M0_NC_ONLINE for a pool that is rebalancing."
        -- Will query spiel for repair status and complete the repair
        queryStartHandling pool
      _ -> phaseLog "repair" $ "Got M0_NC_ONLINE but pool is repairing now."

-- We got a REPAIRED for a pool that was repairing before. Currently
-- we simply fall back to queryStartHandling which should conclude the
-- repair.
processPoolInfo pool M0_NC_REPAIRED _ = getPoolRepairStatus pool >>= \case
  Nothing -> phaseLog "warning" $ "Got M0_NC_REPAIRED for a pool but "
                               ++ "no pool repair status was found."
  Just (M0.PoolRepairStatus prt _ _)
    | prt == M0.Failure -> do
    phaseLog "repair" $ "Got M0_NC_REPAIRED for a pool that is repairing, "
                     ++ "checking if other IOS completed."
    iosvs <- length <$> R.getIOServices pool
    withRepairStatus prt pool nil $ \sts -> do
      -- is 'filterCompletedRepairs' relevant for rebalancing too?
      -- If not, how do we handle this query?
      let onlines = length $ R.filterCompletedRepairs sts
      modifyPoolRepairInformation pool $ \pri' ->
          pri' { priOnlineNotifications = onlines }
      updatePoolRepairStatusTime pool
      if onlines >= iosvs
      then do
        phaseLog "repair" $ "All IOS have finished repair, moving to complete"
        completeRepair pool prt Nothing
      else phaseLog "repair" $ "Not all services completed repair: [" ++ show onlines ++"/"++show iosvs ++"]" ++ show sts
  _ -> phaseLog "repair" $ "Got M0_NC_REPAIRED but pool is rebalancing now."

-- We got some pool state info but we don't care about what it is as
-- it seems some devices belonging to the pool failed, abort repair.
processPoolInfo pool _ m
  | fa <- getSDevs m M0_NC_FAILED
  , not (S.null fa) = promulgateRC (AbortSNSOperation pool)
-- All the devices we were notified in the pool came up as ONLINE. In
-- this case we may want to continue repair if no other devices in the
-- pool are transient.
  | Just ds <- allWithState m M0_NC_ONLINE
  , ds' <- S.toList ds = getPoolRepairStatus pool >>= \case
      Just (M0.PoolRepairStatus prt _ _) -> do
        sdevs <- filter (`notElem` ds') <$> getPoolSDevs pool
        sts <- getLocalGraph >>= \rg ->
          return $ (flip getConfObjState $ rg) <$> sdevs
        if null $ filter (== M0_NC_TRANSIENT) sts
        then continueRepair pool prt
        else phaseLog "repair" $ "Still some drives transient: " ++ show sts
      _ -> phaseLog "repair" $ "Got some transient drives but repair not on-going on " ++ show pool
-- Some devices came up as transient, quiesce repair if it's on-going.
  | tr <- getSDevs m M0_NC_TRANSIENT
  , _:_ <- S.toList tr = getPoolRepairStatus pool >>= \case
      Nothing -> do
        phaseLog "repair" $ "Got M0_NC_TRANSIENT for " ++ show (pool, tr)
                         ++ " but no repair is on-going, doing nothing."
      Just (M0.PoolRepairStatus prt _ _) -> do
        phaseLog "repair" $ "Got M0_NC_TRANSIENT for " ++ show (pool, tr)
                         ++ ", quescing repair."
        quiesceRepair pool prt

processPoolInfo pool st m = phaseLog "warning" $ unwords
  [ "Got", show st, "for a pool", show pool
  , "but don't know how to handle it: ", show m ]

--------------------------------------------------------------------------------
-- Helpers                                                                    --
--------------------------------------------------------------------------------

-- | Like 'mapMaybe' but lifted to 'Monad'.
mapMaybeM :: Monad m => (a -> m (Maybe b)) -> [a] -> m [b]
mapMaybeM f xs = catMaybes <$> mapM f xs

-- | Info about Pool repair update. Such sets are sent by the IO
-- services during repair and rebalance procedures.
data PoolInfo = PoolInfo M0.Pool ConfObjectState SDevStateMap deriving (Show)

-- | Given a 'Set', figure out if this update belongs to a 'PoolInfo' update.
--
-- TODO: this function do not support processing more than one set in one
-- message.
getPoolInfo :: Set -> PhaseM LoopState l (Maybe PoolInfo)
getPoolInfo (Set ns) =
  mapMaybeM (\(Note fid' typ) -> fmap (typ,) <$> lookupConfObjByFid fid') ns >>= \case
    [(typ, pool)] -> do
      disks <- M.fromListWith (<>) . map (second S.singleton) <$> mapMaybeM noteToSDev ns
      return . Just . PoolInfo pool typ $ SDevStateMap disks
    _ -> return Nothing

-- | Updates of sdev, that doesn't contain Pool version.
newtype DevicesOnly = DevicesOnly [(M0.Pool, SDevStateMap)] deriving (Show)

-- | Given a 'Set', figure if update contains only info about devices
--
-- XXX: do we really need it, can we just read info about devices here?
processDevices :: Set -> PhaseM LoopState l (Maybe DevicesOnly)
processDevices (Set ns) =
  mapMaybeM (\(Note fid' _) -> lookupConfObjByFid fid') ns >>= \case
    ([] :: [M0.Pool]) -> do
      disks <- mapMaybeM noteToSDev ns
      pdisks <- mapM (\x@(stType,sdev) -> (,x) <$> getSDevPool sdev) disks
      {-
      pdisks <- mapMaybeM (\(stType, sdev) -> getSDevPool sdev
                             >>= return . fmap (,(stType, sdev)))
                          disks
                          -}

      let ndisks = M.toList
                 . M.map (SDevStateMap . M.fromListWith (<>))
                 . M.fromListWith (<>)
                 . map (\(pool, (st', sdev)) -> (pool, [(st', S.singleton sdev)]))
                 $ pdisks
      case ndisks of
        [] -> return Nothing
        x  -> return (Just (DevicesOnly x))

    _ -> return Nothing

-- | A mapping of 'ConfObjectState's to 'M0.SDev's.
newtype SDevStateMap = SDevStateMap (M.Map ConfObjectState (S.HashSet SDev))
  deriving (Show, Eq, Generic, Typeable)

-- | Queries the 'SDevStateMap'.
getSDevs :: SDevStateMap -> ConfObjectState -> S.HashSet SDev
getSDevs (SDevStateMap m) st = fromMaybe mempty $ M.lookup st m

-- | Check that all 'SDev's have the given 'ConfObjectState' and if
-- they do, return them.
allWithState :: SDevStateMap -> ConfObjectState -> Maybe (S.HashSet SDev)
allWithState sm@(SDevStateMap m) st =
  if M.member st m && M.size m == 1 then Just $ getSDevs sm st else Nothing


-- | Check if the repair is quiesced. Note that this function just
-- checks if any SNS status comes back as
-- 'Spiel.M0_SNS_CM_STATUS_PAUSED': if we get no statuses back, it
-- will report as no quiesce happening.
repairHasQuiesced :: Pool -> PoolRepairType
                  -> PhaseM LoopState l (Either SomeException Bool)
repairHasQuiesced pool prt = R.repairStatus prt pool >>= \case
  Left e -> return $ Left e
  Right sts -> do
    let p (Spiel.SnsStatus _ Spiel.M0_SNS_CM_STATUS_PAUSED _) = True
        p _                                                   = False
    return . Right . not . null $ filter p sts

-- | Check if processes associated with IOS are up. If yes, try to
-- restart repair/rebalance on the pools.
checkRepairOnServiceUp :: Definitions LoopState ()
checkRepairOnServiceUp = define "checkRepairOnProcessStarte" $ do
  init_rule <- phaseHandle "init_rule"

  setPhaseInternalNotificationWithState init_rule (== M0.SSOnline) $ \(eid, srvs :: [(M0.Service, M0.ServiceState)]) -> do
    todo eid
    -- Check if any of the services are IOS: if no service is IOS then
    -- we can just do nothing early and save ourselves some lookups
    case filter ((== CST_IOS) . M0.s_type . fst) srvs of
      [] -> return ()
      -- but if we do have IOS, we don't care about which one it is as
      -- we have to check that all IOS-related processes are up anyway
      _ -> do
        rg <- getLocalGraph
        let failedIOS = [ p | p <- getAllProcesses rg
                            , M0.PSFailed _ <- [getState p rg]
                            , s <- G.connectedTo p M0.IsParentOf rg
                            , CST_IOS <- [M0.s_type s] ]
        case failedIOS of
          [] -> do
            pools <- getPool
            for_ pools $ \pool -> case getState pool rg of
              -- TODO: we should probably be setting pool to failed too but
              -- after abort we lose information on what kind of repair was
              -- happening so we currently can't; perhaps we need to mark
              -- what kind of failure it was
              M0_NC_REBALANCE -> promulgateRC (PoolRebalanceRequest pool)
              M0_NC_REPAIR -> promulgateRC (PoolRepairRequest pool)
              st -> phaseLog "warn" $
                "checkRepairOnProcessStart: Don't know how to deal with pool state " ++ show st
          ps -> phaseLog "info" $ "Still waiting for following IOS processes: " ++ show (M0.fid <$> ps)
    done eid

  start init_rule ()
