{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE DataKinds  #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE GADTs #-}

{-# OPTIONS_GHC -fno-warn-overlapping-patterns #-}

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
module HA.RecoveryCoordinator.Castor.Drive.Rules.Repair
  ( handleRepairExternal
  , ruleRebalanceStart
  , ruleRepairStart
  , noteToSDev
  , querySpiel
  , querySpielHourly
  , checkRepairOnClusterStart
  , checkRepairOnServiceUp
  , ruleSNSOperationAbort
  , ruleSNSOperationQuiesce
  , ruleSNSOperationContinue
  , ruleOnSnsOperationQuiesceFailure
  , ruleHandleRepair
  ) where

import           Control.Applicative
import           Control.Arrow (second)
import           Control.Distributed.Process
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
import           Data.Maybe
  ( catMaybes
  , isJust
  , fromMaybe
  , listToMaybe
  , mapMaybe
  )
import           Data.Proxy
import qualified Data.Text as T
import           Data.Traversable (for)
import           Data.Monoid ((<>))
import           Data.Typeable (Typeable, (:~:)(..), eqT)
import           Data.Vinyl hiding ((:~:))
import           GHC.Generics (Generic)

import           HA.Encode
import           HA.EventQueue.Types
import qualified HA.ResourceGraph as G
import           HA.RecoveryCoordinator.Actions.Castor.Cluster (barrierPass)
import           HA.RecoveryCoordinator.Actions.Core
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Job.Actions
import           HA.RecoveryCoordinator.Mero
import           HA.RecoveryCoordinator.Events.Castor.Cluster
import           HA.RecoveryCoordinator.Events.Mero
import qualified HA.RecoveryCoordinator.Castor.Drive.Rules.Repair.Internal as R
import HA.RecoveryCoordinator.Rules.Mero.Conf
  ( applyStateChanges
  , setPhaseInternalNotificationWithState
  , setPhaseAllNotified
  )
import           HA.Services.SSPL.CEP
import           HA.Resources
import           HA.Resources.Castor
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero
  hiding (Enclosure, Process, Rack, Process, lookupConfObjByFid)
import           HA.Resources.Mero.Note
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
  deriving (Eq, Ord, Show, Generic, Typeable)

instance B.Binary SpielQueryHourly

-- | Event that hourly job finihed.
data SpielQueryHourlyFinished = SpielQueryHourlyFinished Pool M0.PoolRepairType UUID
  deriving (Eq, Show, Generic, Typeable)

instance B.Binary SpielQueryHourlyFinished

-- | Handler for @M0_NC_ONLINE@ 'Pool' messages. Its main role is to
-- load all metadata information and schedule request that will check
-- if repair could be completed.
queryStartHandling :: M0.Pool -> PhaseM LoopState l ()
queryStartHandling pool = do
  M0.PoolRepairStatus prt ruuid _ <- getPoolRepairStatus pool >>= \case
    Nothing -> do
      let err = "In queryStartHandling for " ++ show pool ++ " without PRS set."
      phaseLog "error" err
      return $ error err
    Just prs -> do
      phaseLog "info" $ "PoolRepairStatus = " ++ show prs
      return prs
  -- We always send SpielQuery and move all complex logic there,
  -- this allow to leave this call synchronous but non-blocking
  -- so it can be used inside 'PhaseM' directly
  promulgateRC $ SpielQuery pool prt ruuid

processSnsStatusReply ::
      PhaseM LoopState l (Maybe UUID, PoolRepairType, UUID) -- ^ Get interesting info from env
   -> PhaseM LoopState l () -- ^ action to run before doing anything else
   -> PhaseM LoopState l () -- ^ action to run if SNS is not running
   -> PhaseM LoopState l () -- ^ action to run if action is not complete
   -> (PoolRepairInformation -> PhaseM LoopState l ()) -- ^ action to run if action is complete
   -> M0.Pool
   -> [Spiel.SnsStatus]
   -> PhaseM LoopState l ()
processSnsStatusReply getUUIDs preProcess onNotRunning onNonComplete onComplete pool sts = do
  (muuid, prt, ruuid) <- getUUIDs
  preProcess
  mpri <- getPoolRepairInformation pool
  case mpri of
    Nothing -> unsetPoolRepairStatusWithUUID pool ruuid
    Just pri -> do
      keepRunning <- maybe False ((ruuid ==) .prsRepairUUID)
                       <$> getPoolRepairStatus pool
      when keepRunning $ do
        updatePoolRepairStatusTime pool
        nios <- length <$> R.getIOServices pool -- XXX: this is not number of
                                                --  IOS we started with
        if sts == R.filterCompletedRepairs sts
             && length sts >= nios
        then do completeRepair pool prt muuid
                onComplete pri
        else onNonComplete
      onNotRunning

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
querySpiel :: Definitions LoopState ()
querySpiel = define "spiel::sns:query-status" $ do
  query_status    <- phaseHandle "run status request"
  dispatch_hourly <- phaseHandle "dispatch hourly event"
  abort_on_quiesce <- phaseHandle "aborting because of SNS operation quiesce"
  abort_on_abort   <- phaseHandle "aborting baceuse of SNS operation abort"

  let process_info = processSnsStatusReply
        (do Just (uuid, _, prt, ruuid) <- get Local
            return (Just uuid, prt, ruuid))
        (do Just (uuid, _, _, _) <- get Local
            messageProcessed uuid)
        (return ())
        (return ())
        (\pri -> do
            timeNow <- liftIO getTime
            let elapsed = timeNow - priTimeOfFirstCompletion pri
                untilTimeout = M0.mkTimeSpec 300 - elapsed
            switch [ query_status
                   , abort_on_quiesce
                   , abort_on_abort
                   , timeout (timeSpecToSeconds untilTimeout) dispatch_hourly])
  let process_failure pool str = do
        Just (uuid, _, _, _) <- get Local
        messageProcessed uuid
        phaseLog "error" "Exception when requesting status"
        phaseLog "pool.fid" $ show (M0.fid pool)
        phaseLog "text"  str

  (repair_status, repairStatus) <-
     mkRepairStatusRequestOperation process_failure process_info

  (rebalance_status, rebalanceStatus) <-
    mkRebalanceStatusRequestOperation process_failure process_info

  setPhase query_status $ \(HAEvent uid (SpielQuery pool prt ruuid) _) -> do
    phaseLog "pool.fid" $ show (M0.fid pool)
    phaseLog "repair.type" $ show prt
    put Local $ Just (uid, pool, prt, ruuid)
    case prt of
      M0.Rebalance -> do
        rebalanceStatus pool
        continue rebalance_status
      M0.Failure   -> do
        repairStatus pool
        continue repair_status

  directly dispatch_hourly $ do
    Just (_, pool, prt, ruuid) <- get Local
    keepRunning <- maybe False ((ruuid ==) .prsRepairUUID)
                     <$> getPoolRepairStatus pool
    when keepRunning $ do
      phaseLog "pool.fid" $ show (M0.fid  pool)
      phaseLog "repair.type" $ show prt
      phaseLog "repair.uuid" $ show ruuid
      promulgateRC $ SpielQueryHourly pool prt ruuid

  setPhase abort_on_quiesce $
    \(HAEvent _ (QuiesceSNSOperation _pool) _) -> return ()
  setPhase abort_on_abort $
    \(HAEvent _ (AbortSNSOperation _pool _) _) -> return ()

  start query_status Nothing

-- | 'Job' used by 'ruleRebalanceStart'
jobHourlyStatus :: Job SpielQueryHourly SpielQueryHourlyFinished
jobHourlyStatus  = Job "castor::sns::hourly-status"

-- | This rule works in similar fashion to 'querySpiel' with the main difference
-- that:
--
-- * it runs hourly
-- * it runs until repairs complete
querySpielHourly :: Definitions LoopState ()
querySpielHourly = mkJobRule jobHourlyStatus args $ \finish -> do
  run_query <- phaseHandle "run status query"
  abort_on_quiesce <- phaseHandle "abort due to SNS operation pause"
  abort_on_abort   <- phaseHandle "abort due to SNS operation abort"
  let loop = [ timeout 3600 run_query
             , abort_on_quiesce
             , abort_on_abort
             ]
  let process_info = processSnsStatusReply
        (do Just (SpielQueryHourly _ prt ruid) <- getField . rget fldReq <$> get Local
            return (Nothing, prt, ruid))
        (return ())
        (continue finish)
        (switch loop)
        (\_ -> continue finish)
  let process_failure _pool _str = continue finish

  let route (SpielQueryHourly pool prt ruid) = do
        modify Local $ rlens fldRep .~ Field (Just $ SpielQueryHourlyFinished pool prt ruid)
        return $ Just loop

  setPhase abort_on_quiesce $
    \(HAEvent _ (QuiesceSNSOperation _pool) _) -> continue finish
  setPhase abort_on_abort   $
    \(HAEvent _ (AbortSNSOperation _pool _) _) -> continue finish

  (repair_status, repairStatus) <-
     mkRepairStatusRequestOperation process_failure process_info

  (rebalance_status, rebalanceStatus) <-
    mkRebalanceStatusRequestOperation process_failure process_info

  directly run_query $ do
    Just (SpielQueryHourly pool prt ruuid) <- getField . rget fldReq <$> get Local
    keepRunning <- maybe False ((ruuid ==) . prsRepairUUID) <$> getPoolRepairStatus pool
    unless keepRunning $ continue finish
    case prt of
      M0.Rebalance -> do rebalanceStatus pool
                         continue rebalance_status
      M0.Failure   -> do repairStatus pool
                         continue repair_status

  return route
  where
    fldReq = Proxy :: Proxy '("request", Maybe SpielQueryHourly)
    fldRep = Proxy :: Proxy '("reply", Maybe SpielQueryHourlyFinished)
    args = fldUUID          =: Nothing
       <+> fldReq           =: Nothing
       <+> fldRep           =: Nothing
       <+> RNil


-- | 'Job' used by 'ruleRebalanceStart'
jobRebalanceStart :: Job PoolRebalanceRequest PoolRebalanceStarted
jobRebalanceStart = Job "castor::sns::rebalance::start"

-- | Start rebalance operation triggered by 'PoolRebalanceRequest.
-- Emits 'PoolRebalanceStarted' if successful.
--
-- See 'ruleRepairStart' for some caveats.
ruleRebalanceStart :: Definitions LoopState ()
ruleRebalanceStart = mkJobRule jobRebalanceStart args $ \finish -> do
  pool_disks_notified <- phaseHandle "pool_disks_notified"
  notify_failed <- phaseHandle "notify_failed"
  notify_timeout <- phaseHandle "notify_timeout"

  let init_rule (PoolRebalanceRequest pool) = getPoolRepairInformation pool >>= \case
        Nothing -> R.allIOSOnline pool >>= \case
          True -> do
            rg <- getLocalGraph
            sdevs <- getPoolSDevs pool
            let sts = map (\d -> (getConfObjState d rg, d)) sdevs
            -- states that are considered as ‘OK, we can finish
            -- repair/rebalance’ states for the drives
            let okMessages = [M0_NC_REPAIRED, M0_NC_ONLINE]
             -- list of devices in OK state
                sdev_repaired = snd <$> filter (\(typ, _) -> typ == M0_NC_REPAIRED) sts
                (sdev_notready, sdev_ready) = partitionEithers $ deviceReadyStatus rg <$> sdev_repaired
                sdev_broken   = snd <$> filter (\(typ, _) -> not $ typ `elem` okMessages) sts
            for_ sdev_notready $ phaseLog "info"
            if null sdev_broken
            then if null sdev_ready
                  then do phaseLog "info" $ "Can't start rebalance, no drive to rebalance on"
                          return $ Just [finish]
                  else do
                    phaseLog "info" "starting rebalance"
                    disks <- catMaybes <$> mapM lookupSDevDisk sdev_ready
                    let messages = stateSet pool M0_NC_REBALANCE : (flip stateSet M0.SDSRebalancing <$> disks)
                    modify Local $ rlens fldNotifications .~ Field (Just messages)
                    modify Local $ rlens fldPoolDisks .~ Field (Just (pool, disks))
                    applyStateChanges messages
                    return $ Just [pool_disks_notified, notify_failed, timeout 10 notify_timeout]
            else do phaseLog "info" $ "Can't start rebalance, not all drives are ready: " ++ show sdev_broken
                    return $ Just [finish]
          False -> do
            phaseLog "warn" "Not starting rebalance, some IOS are not online"
            return Nothing
        Just info -> do
          phaseLog "warn" $ "Pool repair/rebalance is already running: " ++ show info
          return Nothing

  (rebalance_started, startRebalance) <- mkRebalanceStartOperation $ \pool eresult -> do
     case eresult of
       Left _err -> do abortRebalanceStart
                       continue finish
       Right _uuid -> do modify Local $ rlens fldRep .~ Field (Just $ PoolRebalanceStarted pool)
                         possiblyInitialisePRI pool
                         incrementOnlinePRSResponse pool
                         continue finish

  (status_received, statusRebalance) <- mkRebalanceStatusRequestOperation
     (\_ s -> do phaseLog "error" $ "failed to query SNS state: " ++ s
                 abortRebalanceStart
                 continue finish)
     (\_ sns -> if all R.iosReady $ Spiel._sss_state <$> sns
              then do
                Just (pool, disks) <- getField . rget fldPoolDisks <$> get Local
                startRebalance pool disks
                continue rebalance_started
              else do
                phaseLog "error" "some IO services are not ready"
                phaseLog "reply" $ show sns
                abortRebalanceStart
                continue finish)

  setPhaseAllNotified pool_disks_notified (rlens fldNotifications . rfield) $ do
    Just (pool, _) <- getField . rget fldPoolDisks <$> get Local
    statusRebalance pool
    continue status_received

  setPhase notify_failed $ \(HAEvent uuid (NotifyFailureEndpoints eps) _) -> do
    todo uuid
    when (not $ null eps) $ do
      phaseLog "warn" $ "Failed to notify " ++ show eps ++ ", not starting rebalance"
      abortRebalanceStart
    done uuid
    continue finish

  directly notify_timeout $ do
    phaseLog "warn" $ "Unable to notify Mero; cannot start rebalance"
    abortRebalanceStart
    continue finish

  return init_rule

  where
    abortRebalanceStart = getField . rget fldPoolDisks <$> get Local >>= \case
      Nothing -> phaseLog "error" "No pool info in local state"
      Just (pool, _) -> do
        ds <- getPoolSDevsWithState pool M0_NC_REBALANCE
        applyStateChanges $ map (\d -> stateSet d M0.SDSFailed) ds

    -- Is this device ready to be rebalanced onto?
    deviceReadyStatus :: G.Graph -> M0.SDev -> Either String M0.SDev
    deviceReadyStatus rg s = case stats of
        Just (_, True, False, True, "OK") -> Right s
        Just other -> Left $ "Device not ready: " ++ showFid s
                      ++ " (sdev, Replaced, Removed, Powered, OK): "
                      ++ show other
        Nothing -> Left $ "No storage device or status could be found for " ++ showFid s
      where
        stats = do
          (disk :: M0.Disk) <- G.connectedTo s M0.IsOnHardware rg
          (sd :: StorageDevice) <- G.connectedTo disk At rg
          (StorageDeviceStatus sds _) <- G.connectedTo sd Is rg
          return ( sd
                 , G.isConnected sd Has SDReplaced rg
                 , G.isConnected sd Has SDRemovedAt rg
                 , G.isConnected sd Has (SDPowered True) rg
                 , sds
                 )

    fldReq = Proxy :: Proxy '("request", Maybe PoolRebalanceRequest)
    fldRep = Proxy :: Proxy '("reply", Maybe PoolRebalanceStarted)
    fldNotifications = Proxy :: Proxy '("notifications", Maybe [AnyStateSet])
    fldPoolDisks = Proxy :: Proxy '("pooldisks", Maybe (M0.Pool, [M0.Disk]))

    args = fldUUID          =: Nothing
       <+> fldReq           =: Nothing
       <+> fldRep           =: Nothing
       <+> fldNotifications =: Nothing
       <+> fldPoolDisks =: Nothing

-- | 'Job' used by 'ruleRepairStart'
jobRepairStart :: Job PoolRepairRequest PoolRepairStartResult
jobRepairStart = Job "castor-repair-start"

-- | Handle the 'PoolRepairRequest' message that tries to trigger repair.
--
-- * If no repair is on-going, all IOS are idle and online, set
-- appropriate states to pool and disks and notify mero.
--
-- * Once mero has been notified, 'startRepairOperation' and
-- 'queryStartHandling'.
--
-- * It may happen that notification either times out or fails. In
-- either case, set the pool and disks to a state that indicates
-- repair failure.
--
-- * If everything goes well, repair starts and rule emits 'PoolRepairStarted'.
--
-- TODO: There is a race between us checking that we're ready to start
-- repair, issuing the start repair call, repair actually starting and
-- IOS becoming unavailable. For now we just check IOS status right
-- before repairing but there is no guarantee we won't try to start
-- repair on IOS that's down. HALON-403 should help.
ruleRepairStart :: Definitions LoopState ()
ruleRepairStart = mkJobRule jobRepairStart args $ \finish -> do
  pool_disks_notified <- phaseHandle "pool_disks_notified"
  notify_failed <- phaseHandle "notify_failed"
  notify_timeout <- phaseHandle "notify_timeout"

  let init_rule (PoolRepairRequest pool) = getPoolRepairInformation pool >>= \case
        -- We spare ourselves some work and if IOS aren't ready then
        -- we don't even try to put the drives in repairing state just
        -- to flip them back a second later.
        Nothing -> R.allIOSOnline pool >>= \case
          True -> do
            tr <- getPoolSDevsWithState pool M0_NC_TRANSIENT
            fa <- getPoolSDevsWithState pool M0_NC_FAILED
            case null tr && not (null fa) of
              True -> do
                let msgs = stateSet pool M0_NC_REPAIR : (flip stateSet M0.SDSRepairing <$> fa)
                modify Local $ rlens fldNotifications .~ Field (Just msgs)
                modify Local $ rlens fldPool .~ Field (Just pool)
                applyStateChanges msgs
                return $ Just [pool_disks_notified, notify_failed, timeout 10 notify_timeout]
              False -> do
                phaseLog "warn" $ "Not starting repair, have transient or no failed devices"
                return $ Just [finish]
          False -> do
            phaseLog "warn" $ "Not starting repair, some IOS are not online"
            return $ Just [finish]
        Just _ -> do
          phaseLog "warn" $ "Not starting repair, seems there is repair already on-going"
          return $ Just [finish]

  (repair_started, startRepairOperation) <- mkRepairStartOperation $ \pool er -> do
    case er of
      Left s -> do
        modify Local $ rlens fldRep .~ Field (Just $ PoolRepairFailedToStart pool s)
        continue finish
      Right _ -> do
        modify Local $ rlens fldRep .~ Field (Just $ PoolRepairStarted pool)
        possiblyInitialisePRI pool
        incrementOnlinePRSResponse pool
        continue finish

  (status_received, statusRepair) <- mkRepairStatusRequestOperation
     (\_ s -> do phaseLog "error" $ "failed to query SNS state: " ++ s
                 abortRepairStart
                 continue finish)
     (\pool sns -> if all R.iosReady $ Spiel._sss_state <$> sns
              then do
                startRepairOperation pool
                continue repair_started
              else do
                phaseLog "error" "some IO services are not ready"
                phaseLog "reply" $ show sns
                abortRepairStart
                continue finish)

  setPhaseAllNotified pool_disks_notified (rlens fldNotifications . rfield) $ do
    Just pool <- getField . rget fldPool <$> get Local
    statusRepair pool
    continue status_received

  -- Check if it's IOS that failed, if not then just keep going
  setPhase notify_failed $ \(HAEvent uuid (NotifyFailureEndpoints eps) _) -> do
    todo uuid
    when (not $ null eps) $ do
      phaseLog "warn" $ "Failed to notify " ++ show eps ++ ", not starting repair"
      abortRepairStart
    done uuid
    continue finish

  -- Failure endpoint message didn't come and notification didn't go
  -- through either, abort just in case.
  directly notify_timeout $ do
    phaseLog "warn" $ "Unable to notify Mero; cannot start repair"
    abortRepairStart
    continue finish

  return init_rule
  where
    abortRepairStart = getField . rget fldPool <$> get Local >>= \case
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


    fldReq = Proxy :: Proxy '("request", Maybe PoolRepairRequest)
    fldRep = Proxy :: Proxy '("reply", Maybe PoolRepairStartResult)
    fldNotifications = Proxy :: Proxy '("notifications", Maybe [AnyStateSet])
    fldPool = Proxy :: Proxy '("pool", Maybe M0.Pool)

    args = fldUUID          =: Nothing
       <+> fldReq           =: Nothing
       <+> fldRep           =: Nothing
       <+> fldNotifications =: Nothing
       <+> fldPool          =: Nothing

data ContinueSNS = ContinueSNS UUID M0.Pool M0.PoolRepairType
      deriving (Eq, Show, Ord, Typeable, Generic)

instance B.Binary ContinueSNS

data ContinueSNSResult
       = SNSContinued UUID M0.Pool M0.PoolRepairType
       | SNSFailed    UUID M0.Pool M0.PoolRepairType String
       | SNSSkipped   UUID M0.Pool M0.PoolRepairType
      deriving (Eq, Show, Ord, Typeable, Generic)

instance B.Binary ContinueSNSResult

-- | Job that convers all the repair continue logic.
jobContinueSNS :: Job ContinueSNS ContinueSNSResult
jobContinueSNS = Job "castor::sns:continue"


-- | Rule that check all if all nessesary conditions for pool repair start
-- are met and starts repair if so.
--
-- The requirements are:
--   * All IOS should be running.
--   * At least one IO service status should be M0_SNS_CM_STATUS_PAUSED.
ruleSNSOperationContinue :: Definitions LoopState ()
ruleSNSOperationContinue = mkJobRule jobContinueSNS args $ \finish -> do

  let process_failure pool s = do
        keepRunning <- isStillRunning pool
        if keepRunning
        then do Just (ContinueSNS ruuid _ prt) <- getField . rget fldReq <$> get Local
                modify Local $
                  rlens fldRep .~ Field (Just $ SNSFailed ruuid pool prt s)
        else do
          phaseLog "warning" "SNS continue operation failedm but SNS is no longer registered in RG"
          continue finish
      check_and_run (phase, action) pool sns = do
       keep_running <- isStillRunning pool
       if keep_running
       then do
         if any ((Spiel.M0_SNS_CM_STATUS_PAUSED ==) . Spiel._sss_state) sns
             && all ((Spiel.M0_SNS_CM_STATUS_FAILED /=) . Spiel._sss_state) sns
         then do
           result <- R.allIOSOnline pool
           if result
           then action pool >> continue phase
           else process_failure pool "Not all IOS are ready"
         else continue finish -- XXX: should we unregister operation here
       else continue finish
      isStillRunning pool = do
        Just (ContinueSNS ruuid _ _) <- getField . rget fldReq <$> get Local
        maybe False ((ruuid ==) .prsRepairUUID)
                         <$> getPoolRepairStatus pool

  repair <- mkRepairContinueOperation process_failure $ \pool _ -> do
    Just (ContinueSNS ruuid _ prt) <- getField . rget fldReq <$> get Local
    modify Local $ rlens fldRep .~ Field (Just $ SNSContinued ruuid pool prt)
    continue finish

  (repair_status, repairStatus) <-
     mkRepairStatusRequestOperation process_failure
       $ check_and_run repair

  rebalance <- mkRebalanceContinueOperation process_failure $ \pool _ -> do
    Just (ContinueSNS ruuid _ prt) <- getField . rget fldReq <$> get Local
    modify Local $ rlens fldRep .~ Field (Just $ SNSContinued ruuid pool prt)
    continue finish

  (rebalance_status, rebalanceStatus) <-
    mkRebalanceStatusRequestOperation process_failure (check_and_run rebalance)

  return $ \(ContinueSNS _ pool prt) -> do
        keepRunning <- isStillRunning pool
        result <- R.allIOSOnline pool
        if keepRunning && result
        then case prt of
          M0.Failure -> do
            repairStatus pool
            return $ Just [repair_status]
          M0.Rebalance -> do
            rebalanceStatus pool
            return $ Just [rebalance_status]
        else return Nothing
  where
    fldReq = Proxy :: Proxy '("request", Maybe ContinueSNS)
    fldRep = Proxy :: Proxy '("reply", Maybe ContinueSNSResult)
    args = fldUUID          =: Nothing
       <+> fldReq           =: Nothing
       <+> fldRep           =: Nothing
       <+> RNil

-- | Abort current SNS operation. Rule requesting SNS operation abort
-- and waiting for all IOs to be finalized.
jobSNSAbort :: Job AbortSNSOperation AbortSNSOperationResult
jobSNSAbort = Job "castor::node::sns::abort"

ruleSNSOperationAbort :: Definitions LoopState ()
ruleSNSOperationAbort = mkJobRule jobSNSAbort args $ \finish -> do
  entry <- phaseHandle "entry"
  ok    <- phaseHandle "ok"
  failure <- phaseHandle "SNS abort failed."

  let route (AbortSNSOperation pool uuid) = getPoolRepairStatus pool >>= \case
        Nothing -> do
          phaseLog "repair" $ "Abort requested on " ++ show pool
                           ++ "but no repair seems to be happening."
          modify Local $ rlens fldRep .~ (Field . Just $ AbortSNSOperationSkip pool)
          return $ Just [finish]
        Just (M0.PoolRepairStatus prt uuid' _) | uuid == uuid' -> do
          modify Local $ rlens fldPrt .~ (Field . Just $ prt)
          modify Local $ rlens fldRepairUUID .~ (Field . Just $ uuid')
          return $ Just [entry]
        Just (M0.PoolRepairStatus _ uuid' _) -> do
          phaseLog "repair" $ "Abort requested on " ++ show pool ++ " but UUIDs mismatch"
          phaseLog "request.uuid" $ show uuid
          phaseLog "PRS.uuid" $ show uuid'
          let msg = show uuid ++ " /= " ++ show uuid'
          modify Local $ rlens fldRep .~ (Field . Just $ AbortSNSOperationFailure pool msg)
          return $ Just [finish]

  (ph_repair_abort, abortRepair) <- mkRepairAbortOperation 15
      (\l -> (\(Just (AbortSNSOperation pool _)) -> pool) $ getField (rget fldReq l))
      (\pool s -> do
         modify Local $ rlens fldRep .~ (Field . Just $ AbortSNSOperationFailure pool s)
         continue failure)
      (\pool sns -> do
         if all R.iosReady $ snd <$> sns
         then do modify Local $ rlens fldRep .~ (Field . Just $ AbortSNSOperationOk pool)
                 continue ok
         else continue entry)

  (ph_rebalance_abort, abortRebalance) <- mkRebalanceAbortOperation 15
      (\l -> (\(Just (AbortSNSOperation pool _)) -> pool) $ getField (rget fldReq l))
      (\pool s -> do
         modify Local $ rlens fldRep .~ (Field . Just $ AbortSNSOperationFailure pool s)
         continue failure)
      (\pool sns -> do
         if all R.iosReady $ snd <$> sns
         then do modify Local $ rlens fldRep .~ (Field . Just $ AbortSNSOperationOk pool)
                 continue ok
         else continue entry)

  directly entry $ do
    Just (AbortSNSOperation pool _) <- getField . rget fldReq <$> get Local
    Just prt <- getField . rget fldPrt <$> get Local
    case prt of
      M0.Failure -> do
        abortRepair pool
        continue ph_repair_abort
      M0.Rebalance -> do
        abortRebalance pool
        continue ph_rebalance_abort

  directly ok $ do
    Just (AbortSNSOperation pool _) <- getField . rget fldReq <$> get Local
    Just uuid <- getField . rget fldRepairUUID <$> get Local
    unsetPoolRepairStatusWithUUID pool uuid
    modify Local $ rlens fldRep .~ (Field . Just $ AbortSNSOperationOk pool)
    continue finish

  directly failure $ do
    phaseLog "warning" "SNS abort failed - removing Pool repair info."
    Just (AbortSNSOperation pool _) <- getField . rget fldReq <$> get Local
    Just uuid <- getField . rget fldRepairUUID <$> get Local
    unsetPoolRepairStatusWithUUID pool uuid
    continue finish

  return route
  where
    fldReq :: Proxy '("request", Maybe AbortSNSOperation)
    fldReq = Proxy
    fldRep :: Proxy '("reply", Maybe AbortSNSOperationResult)
    fldRep = Proxy
    fldPrt :: Proxy '("prt", Maybe PoolRepairType)
    fldPrt = Proxy
    fldRepairUUID :: Proxy '("repairUUID", Maybe UUID)
    fldRepairUUID = Proxy
    args =  fldReq  =: Nothing
        <+> fldRep  =: Nothing
        <+> fldPrt  =: Nothing
        <+> fldUUID =: Nothing
        <+> fldRepairUUID =: Nothing
        <+> RNil


jobSNSQuiesce :: Job QuiesceSNSOperation QuiesceSNSOperationResult
jobSNSQuiesce = Job "castor::sns::quiesce"

ruleSNSOperationQuiesce :: Definitions LoopState ()
ruleSNSOperationQuiesce = mkJobRule jobSNSQuiesce args $ \finish -> do
  entry <- phaseHandle "execute operation"

  let route (QuiesceSNSOperation pool) = do
       phaseLog "info" $ "Quisce request."
       phaseLog "pool.fid" $ show (M0.fid pool)
       mprs <- getPoolRepairStatus pool
       case mprs of
         Nothing -> do phaseLog "result" $ "no repair seems to be happening"
                       modify Local $ rlens fldRep .~ (Field . Just $ QuiesceSNSOperationSkip pool)
                       return $ Just [finish]
         Just (M0.PoolRepairStatus prt uuid _) -> do
           modify Local $ rlens fldPrt .~ (Field . Just $ prt)
           modify Local $ rlens fldUUID .~ (Field . Just $ uuid)
           return $ Just [entry]

  (ph_repair_quiesced, quiesceRepair) <- mkRepairQuiesceOperation 15
      (\l -> (\(Just (QuiesceSNSOperation pool)) -> pool) $ getField (rget fldReq l))
      (\pool s -> do
         modify Local $ rlens fldRep .~ (Field . Just $ QuiesceSNSOperationFailure pool s)
         continue finish)
      (\pool sns -> do
         if all R.iosPaused $ snd <$> sns
         then modify Local $ rlens fldRep .~ (Field . Just $ QuiesceSNSOperationOk pool)
         else modify Local $ rlens fldRep .~ (Field . Just $ QuiesceSNSOperationFailure pool "services in a bad state")
         continue finish)

  (ph_rebalance_quiesced, quiesceRebalance) <- mkRebalanceQuiesceOperation 15
      (\l -> case getField (rget fldReq l) of
               Nothing -> error "impossible happened."
               Just (QuiesceSNSOperation pool) -> pool)
      (\pool s -> do
         modify Local $ rlens fldRep .~ (Field . Just $ QuiesceSNSOperationFailure pool s)
         continue finish)
      (\pool sns -> do
         if all R.iosPaused $ snd <$> sns
         then modify Local $ rlens fldRep .~ (Field . Just $ QuiesceSNSOperationOk pool)
         else modify Local $ rlens fldRep .~ (Field . Just $ QuiesceSNSOperationFailure pool "services in a bad state")
         continue finish
         )

  directly entry $ do
    Just (QuiesceSNSOperation pool) <- getField . rget fldReq <$> get Local
    Just prt <- getField . rget fldPrt <$> get Local
    case prt of
      M0.Rebalance -> do
        quiesceRebalance pool
        continue ph_rebalance_quiesced
      M0.Failure -> do
        quiesceRepair pool
        continue ph_repair_quiesced

  return route
  where
    fldReq :: Proxy '("request", Maybe QuiesceSNSOperation)
    fldReq = Proxy
    fldRep :: Proxy '("reply", Maybe QuiesceSNSOperationResult)
    fldRep = Proxy
    fldPrt :: Proxy '("prt", Maybe PoolRepairType)
    fldPrt = Proxy
    args =  fldReq  =: Nothing
        <+> fldRep  =: Nothing
        <+> fldPrt  =: Nothing
        <+> fldUUID =: Nothing
        <+> RNil

-- | If Quiesce operation on pool failed - we need to abort SNS operation.
ruleOnSnsOperationQuiesceFailure :: Definitions LoopState ()
ruleOnSnsOperationQuiesceFailure = defineSimple "castor::sns::abort-on-quiesce-error" $ \result ->
   case result of
    (QuiesceSNSOperationFailure pool _) -> do
       mprs <- getPoolRepairStatus pool
       case mprs of
         Nothing -> return ()
         Just prs  -> promulgateRC . AbortSNSOperation pool $ prsRepairUUID prs
    _ -> return ()

--------------------------------------------------------------------------------
-- Actions                                                                    --
--------------------------------------------------------------------------------


-- | Continue a previously-quiesced SNS operation.
continueSNS :: M0.Pool  -- ^ Pool under SNS operation
            -> M0.PoolRepairType
            -> PhaseM LoopState l ()
continueSNS pool prt = do
  -- We check what we have actualy registered in graph in order to
  -- understand what can we do. Theoretically it should not be needed
  -- and we could be able to get all info in runtime, without storing
  -- data in the graph.
  mprs <- getPoolRepairStatus pool
  case mprs of
    Nothing -> phaseLog "warning" $
      "continue repair was called, when no SNS operation were registered\
       \- ignoring"
    Just prs ->
      if prsType prs == prt
      then promulgateRC $ ContinueSNS (prsRepairUUID prs) pool prt
      else phaseLog "warning" $
             "Continue for " ++ show prt
                             ++ "was requested, but "
                             ++ show (prsType prs) ++ "is registered."

-- | Quiesce the repair on the given pool if the repair is on-going.
quiesceSNS :: M0.Pool -> PhaseM LoopState l ()
quiesceSNS pool = promulgateRC $ QuiesceSNSOperation pool

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

        applyStateChanges $ map (\s -> stateSet s (repairedState prt)) (Set.toList repaired_sdevs)
                         ++ map (\s -> stateSet s (repairedState prt)) repaired_disks

        when (prt == M0.Rebalance) $
           forM_ repaired_sdevs $ \m0sdev -> void $ runMaybeT $ do
             sdev   <- MaybeT $ lookupStorageDevice m0sdev
             host   <- MaybeT $ listToMaybe <$> getSDevHost sdev
             serial <- MaybeT $ listToMaybe <$> lookupStorageDeviceSerial sdev
             lift $ sendLedUpdate DriveOk host (T.pack serial)

        if Set.null non_repaired_sdevs
        then do phaseLog "info" $ "Full repair on " ++ show pool
                applyStateChanges [stateSet pool $ R.repairedNotificationMsg prt]
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
ruleHandleRepair :: Definitions LoopState ()
ruleHandleRepair = defineSimpleTask "castor::sns::handle-repair" $ \msg ->
  getClusterStatus <$> getLocalGraph >>= \case
    Just (M0.MeroClusterState M0.ONLINE n _) | n >= (M0.BootLevel 1) -> do
      InternalObjectStateChange chs <- liftProcess $ decodeP msg
      mdeviceOnly <- processDevices ignoreSome chs
      traverse_ go mdeviceOnly
    _ -> return ()
  where
    ignoreSome :: StateCarrier SDev -> StateCarrier SDev -> Bool
    ignoreSome SDSRepaired  SDSFailed = False -- Should not happen.
    ignoreSome SDSRepairing SDSFailed = False -- Cancelation of the repair operation.
    ignoreSome o n | o == n = False     -- Not a change - ignoring
    ignoreSome _ _ = True
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
                quiesceSNS pool
            -- Repair happening, something came online, check if
            -- nothing is left transient and continue repair if possible
            | Just ds <- allWithState diskMap M0_NC_ONLINE
            , ds' <- S.toList ds -> do
                sdevs <- filter (`notElem` ds') <$> getPoolSDevs pool
                sts <- getLocalGraph >>= \rg ->
                  return $ (flip getConfObjState $ rg) <$> sdevs
                if null $ filter (== M0_NC_TRANSIENT) sts
                then continueSNS pool prt
                else phaseLog "repair" $ "Still some drives transient: " ++ show sts
            | otherwise -> phaseLog "repair" $
                "Repair on-going but don't know what to do with " ++ show diskMap
          Nothing -> maybeBeginRepair

-- | When the cluster has completed starting up, it's possible that
--   we have devices that failed during the startup process.
checkRepairOnClusterStart :: Definitions LoopState ()
checkRepairOnClusterStart = defineSimpleIf "check-repair-on-start" clusterOnBootLevel2 $ \() -> do
  pools <- getPool
  forM_ pools $ promulgateRC . PoolRepairRequest
  where
    clusterOnBootLevel2 msg ls = barrierPass (\mcs -> _mcs_runlevel mcs >= M0.BootLevel 2) msg ls ()


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
    | prt == M0.Failure -> queryStartHandling pool
  _ -> phaseLog "repair" $ "Got M0_NC_REPAIRED but pool is rebalancing now."

-- We got some pool state info but we don't care about what it is as
-- it seems some devices belonging to the pool failed, abort repair.
processPoolInfo pool _ m
  | fa <- getSDevs m M0_NC_FAILED
  , not (S.null fa) = getPoolRepairStatus pool >>= \case
      Nothing -> return ()
      Just prs  -> promulgateRC . AbortSNSOperation pool $ prsRepairUUID prs
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
        then continueSNS pool prt
        else phaseLog "repair" $ "Still some drives transient: " ++ show sts
      _ -> phaseLog "repair" $ "Got some transient drives but repair not on-going on " ++ show pool
-- Some devices came up as transient, quiesce repair if it's on-going.
  | tr <- getSDevs m M0_NC_TRANSIENT
  , _:_ <- S.toList tr = getPoolRepairStatus pool >>= \case
      Nothing -> do
        phaseLog "repair" $ "Got M0_NC_TRANSIENT for " ++ show (pool, tr)
                         ++ " but no repair is on-going, doing nothing."
      Just (M0.PoolRepairStatus _ _ _) -> do
        phaseLog "repair" $ "Got M0_NC_TRANSIENT for " ++ show (pool, tr)
                         ++ ", quescing repair."
        quiesceSNS pool

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

-- | Given a 'Set', figure if update contains only info about devices.
--
-- This function takes a predicate that allow to remove certain chages
-- from the set.
--
-- XXX: This function is a subject of change in future, because there is no
-- point in of hiding old state and halon state, this allowes much range
-- of decisions that could be done by the caller.
processDevices :: (StateCarrier SDev -> StateCarrier SDev -> Bool) -- ^ Predicate
                -> [AnyStateChange]
                -> PhaseM LoopState l (Maybe DevicesOnly)
processDevices p changes = do
    for msdevs $ \sdevs -> do
      pdevs <- for sdevs $ \x@(sdev,_) -> (,x) <$> getSDevPool sdev
      return . DevicesOnly . M.toList
             . M.map (SDevStateMap . M.fromListWith (<>))
             . M.fromListWith (<>)
             . map (\(pool, (sdev,st)) -> (pool, [(st, S.singleton sdev)]))
             $ pdevs
  where
    go :: AnyStateChange -> Maybe (Maybe (SDev, ConfObjectState))
    go (AnyStateChange (a::x) o n _) = case eqT :: Maybe (x :~: M0.Process) of
      Nothing -> case eqT :: Maybe (x :~: M0.SDev) of
        Just Refl | p o n -> Just (Just (a,toConfObjState a n))
        _ -> Nothing
      Just _  -> Just (Nothing)
    msdevs :: Maybe [(SDev, ConfObjectState)]
    msdevs = sequence (mapMaybe go changes)

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

-- | Check if processes associated with IOS are up. If yes, try to
-- restart repair/rebalance on the pools.
checkRepairOnServiceUp :: Definitions LoopState ()
checkRepairOnServiceUp = define "checkRepairOnProcessStarte" $ do
    init_rule <- phaseHandle "init_rule"

    setPhaseInternalNotificationWithState init_rule (\o n -> o /= M0.PSOnline &&  n == M0.PSOnline)
      $ \(eid, procs :: [(M0.Process, M0.ProcessState)]) -> do
      todo eid
      rg <- getLocalGraph
      when (isJust $ find (flip isIOSProcess rg) (fst <$> procs)) $ do
        let failedIOS = [ p | p <- getAllProcesses rg
                            , M0.PSFailed _ <- [getState p rg]
                            , isIOSProcess p rg ]
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

  where
    isIOSProcess p rg = not . null $ [s | s <- G.connectedTo p M0.IsParentOf rg
                                        , CST_IOS <- [M0.s_type s] ]
