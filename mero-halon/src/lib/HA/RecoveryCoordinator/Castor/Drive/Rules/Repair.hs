{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE DataKinds  #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE GADTs #-}

{-# OPTIONS_GHC -fno-warn-overlapping-patterns #-}

-- |
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
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
  ( noteToSDev
  , querySpiel
  , querySpielHourly
  , rules
    -- * Individual rules exported for test purposes
  , ruleRebalanceStart
  , ruleRepairStart
  , ruleStobIoqError
  , ruleSNSOperationAbort
  , ruleSNSOperationQuiesce
  , ruleSNSOperationContinue
  , ruleSNSOperationRestart
  , ruleOnSnsOperationQuiesceFailure
  , ruleHandleRepair
  , ruleHandleRepairNVec
  , checkRepairOnClusterStart
  , checkRepairOnServiceUp
  ) where

import           Control.Applicative
import           Control.Arrow (second)
import           Control.Distributed.Process
import           Control.Lens
import           Control.Monad
import           Data.Either (partitionEithers)
import           Data.Foldable
import qualified Data.HashSet as S
import qualified Data.Map as M
import qualified Data.Set as Set
import           Data.Maybe (catMaybes, isJust, fromMaybe, mapMaybe)
import           Data.Proxy
import           Data.Traversable (for)
import           Data.Monoid ((<>))
import           Data.Typeable (Typeable, (:~:)(..), eqT)
import           Data.Vinyl hiding ((:~:))
import           Data.UUID (UUID)
import           GHC.Generics (Generic)

import           HA.Encode
import           HA.EventQueue
import qualified HA.ResourceGraph as G
import           HA.RecoveryCoordinator.Castor.Cluster.Actions (barrierPass)
import           HA.RecoveryCoordinator.RC.Actions
import           HA.RecoveryCoordinator.RC.Actions.Dispatch
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Job.Actions
import           HA.RecoveryCoordinator.Castor.Cluster.Events
import qualified HA.RecoveryCoordinator.Castor.Drive.Actions as Drive
import qualified HA.RecoveryCoordinator.Castor.Pool.Actions as Pool
import qualified HA.RecoveryCoordinator.Castor.Process.Actions as Process
import           HA.RecoveryCoordinator.Mero.Events
import           HA.RecoveryCoordinator.Mero.Notifications
import           HA.RecoveryCoordinator.Mero.State (applyStateChanges)
import qualified HA.RecoveryCoordinator.Mero.Transitions as Tr
import qualified HA.RecoveryCoordinator.Castor.Drive.Rules.Repair.Internal as R
import           HA.Resources
import           HA.Resources.Castor
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero
  hiding (Enclosure, Process, Rack, Process, lookupConfObjByFid)
import           HA.Resources.Mero.Note
import           HA.SafeCopy
import           Mero.Notification hiding (notifyMero)
import           Mero.Notification.HAState (HAMsg(..), Note(..), StobIoqError(..))
import           Mero.ConfC (ServiceType(CST_IOS))
import qualified Mero.Spiel as Spiel
import           Network.CEP
import           Prelude

--------------------------------------------------------------------------------
-- Types                                                                      --
--------------------------------------------------------------------------------

-- | Event sent when we want a 5 minute spiel query rule to fire
data SpielQuery = SpielQuery Pool M0.PoolRepairType UUID
  deriving (Eq, Show, Generic, Typeable)
deriveSafeCopy 0 'base ''SpielQuery

-- | Event sent when we want a 60 minute repeated query rule to fire
data SpielQueryHourly = SpielQueryHourly Pool M0.PoolRepairType UUID
  deriving (Eq, Ord, Show, Generic, Typeable)
deriveSafeCopy 0 'base ''SpielQueryHourly

-- | Event that hourly job finihed.
data SpielQueryHourlyFinished = SpielQueryHourlyFinished Pool M0.PoolRepairType UUID
  deriving (Eq, Show, Generic, Typeable)

deriveSafeCopy 0 'base ''SpielQueryHourlyFinished

data ContinueSNS = ContinueSNS UUID M0.Pool M0.PoolRepairType
      deriving (Eq, Show, Ord, Typeable, Generic)
deriveSafeCopy 0 'base ''ContinueSNS

data ContinueSNSResult
       = SNSContinued UUID M0.Pool M0.PoolRepairType
       | SNSFailed    UUID M0.Pool M0.PoolRepairType String
       | SNSSkipped   UUID M0.Pool M0.PoolRepairType
      deriving (Eq, Show, Ord, Typeable, Generic)
deriveSafeCopy 0 'base ''ContinueSNSResult

--------------------------------------------------------------------------------
-- Queries                                                                    --
--------------------------------------------------------------------------------


-- | Handler for @M0_NC_ONLINE@ 'Pool' messages. Its main role is to
-- load all metadata information and schedule request that will check
-- if repair could be completed.
queryStartHandling :: M0.Pool -> PhaseM RC l ()
queryStartHandling pool = do
  M0.PoolRepairStatus prt ruuid _ <- getPoolRepairStatus pool >>= \case
    Nothing -> do
      let err = "In queryStartHandling for " ++ show pool ++ " without PRS set."
      Log.rcLog' Log.ERROR err
      return $ error err
    Just prs -> do
      Log.rcLog' Log.DEBUG $ "PoolRepairStatus = " ++ show prs
      return prs
  -- We always send SpielQuery and move all complex logic there,
  -- this allow to leave this call synchronous but non-blocking
  -- so it can be used inside 'PhaseM' directly
  promulgateRC $ SpielQuery pool prt ruuid

processSnsStatusReply ::
      PhaseM RC l (Maybe UUID, PoolRepairType, UUID) -- ^ Get interesting info from env
   -> PhaseM RC l () -- ^ action to run before doing anything else
   -> PhaseM RC l () -- ^ action to run if SNS is not running
   -> PhaseM RC l () -- ^ action to run if action is not complete
   -> (Either AbortSNSOperation PoolRepairInformation -> PhaseM RC l ())
      -- ^ action to run if SNS repair is complete. SNS is considered
      -- to be complete when
      --
      -- @length ('R.filterCompletedRepairs' snsStatus) == length <$> 'R.getIOServices'@
      --
      -- In case 'anyIOSFailed', SNS abort message is provided instead
      -- of 'PoolRepairInformation'.
   -> M0.Pool
   -> [Spiel.SnsStatus]
   -> PhaseM RC l ()
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
        updatePoolRepairQueryTime pool
        nios <- length <$> R.getIOServices pool -- XXX: this is not number of
                                                --  IOS we started with
        if sts == R.filterCompletedRepairs sts
             && length sts >= nios
        then if R.anyIOSFailed sts
             then onComplete . Left $ AbortSNSOperation pool ruuid
             else do
               completeRepair pool prt muuid
               onComplete $ Right pri
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
querySpiel :: Definitions RC ()
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
        (do Just (_, pool, _, ruuid) <- get Local
            mprs <- getPoolRepairStatus pool
            case mprs of
              Just prs | ruuid == prsRepairUUID prs
                       , Just pri <- prsPri prs -> do
                let driveUpdates = priStateUpdates pri
                nios <- length <$> R.getIOServices pool
                when (all (\u -> snd u <= nios) driveUpdates) $ do
                  switch [ timeout 5 query_status
                         , abort_on_quiesce
                         , abort_on_abort
                         ]
              _ -> return ()
        )
        (\case
            Left abortMsg -> do
              promulgateRC abortMsg
              continue abort_on_abort
            Right pri -> do
              timeNow <- liftIO getTime
              let elapsed = timeNow - priTimeOfSnsStart pri
                  untilTimeout = M0.mkTimeSpec 300 - elapsed
              switch [ query_status
                     , abort_on_quiesce
                     , abort_on_abort
                     , timeout (timeSpecToSeconds untilTimeout) dispatch_hourly])
  let process_failure pool str = do
        Just (uuid, _, _, _) <- get Local
        messageProcessed uuid
        Log.tagContext Log.Phase [ ("pool.fid", show (M0.fid pool)) ] Nothing
        Log.rcLog' Log.ERROR $ "Exception when requesting status: " ++ str

  (repair_status, repairStatus) <-
     mkRepairStatusRequestOperation process_failure process_info

  (rebalance_status, rebalanceStatus) <-
    mkRebalanceStatusRequestOperation process_failure process_info

  setPhase query_status $ \(HAEvent uid (SpielQuery pool prt ruuid)) -> do
    Log.actLog "query status" [ ("pool.fid", show (M0.fid pool))
                              , ("repair.type", show prt)
                              , ("repair.uuid", show ruuid)
                              ]
    put Local $ Just (uid, pool, prt, ruuid)
    case prt of
      M0.Repair -> do
        repairStatus pool
        continue repair_status
      M0.Rebalance -> do
        rebalanceStatus pool
        continue rebalance_status

  directly dispatch_hourly $ do
    Just (_, pool, prt, ruuid) <- get Local
    keepRunning <- maybe False ((ruuid ==) .prsRepairUUID)
                     <$> getPoolRepairStatus pool
    when keepRunning $ do
      Log.actLog "keep running" [ ("pool.fid", show (M0.fid pool))
                                , ("repair.type", show prt)
                                , ("repair.uuid", show ruuid)
                                ]
      promulgateRC $ SpielQueryHourly pool prt ruuid

  setPhase abort_on_quiesce $
    \(HAEvent _ (QuiesceSNSOperation _pool)) -> return ()
  setPhase abort_on_abort $
    \(HAEvent _ (AbortSNSOperation _pool _)) -> return ()

  start query_status Nothing

-- | 'Job' used by 'ruleRebalanceStart'
jobHourlyStatus :: Job SpielQueryHourly SpielQueryHourlyFinished
jobHourlyStatus  = Job "castor::sns::hourly-status"

-- | This rule works in similar fashion to 'querySpiel' with the main difference
-- that:
--
-- * it runs hourly
-- * it runs until repairs complete
querySpielHourly :: Definitions RC ()
querySpielHourly = mkJobRule jobHourlyStatus args $ \(JobHandle getRequest finish) -> do
  run_query <- phaseHandle "run status query"
  abort_on_quiesce <- phaseHandle "abort due to SNS operation pause"
  abort_on_abort   <- phaseHandle "abort due to SNS operation abort"
  let loop t = [ timeout t run_query
               , abort_on_quiesce
               , abort_on_abort
               ]
  let process_info = processSnsStatusReply
        (do SpielQueryHourly _ prt ruid <- getRequest
            return (Nothing, prt, ruid))
        (return ())
        (continue finish)
        (do SpielQueryHourly pool _ _ <- getRequest
            t <- getTimeUntilHourlyQuery pool
            switch $ loop t)
        (\case
            Left abortMsg -> do
              promulgateRC abortMsg
              continue abort_on_abort
            Right _ -> continue finish
        )
  let process_failure _pool _str = continue finish

  let route (SpielQueryHourly pool prt ruid) = do
        modify Local $ rlens fldRep . rfield .~ Just (SpielQueryHourlyFinished pool prt ruid)
        t <- getTimeUntilHourlyQuery pool
        return $ Right (SpielQueryHourlyFinished pool prt ruid, loop t)

  setPhase abort_on_quiesce $
    \(HAEvent _ QuiesceSNSOperation{}) -> continue finish
  setPhase abort_on_abort   $
    \(HAEvent _ AbortSNSOperation{}) -> continue finish

  (repair_status, repairStatus) <-
     mkRepairStatusRequestOperation process_failure process_info

  (rebalance_status, rebalanceStatus) <-
    mkRebalanceStatusRequestOperation process_failure process_info

  directly run_query $ do
    SpielQueryHourly pool prt ruuid <- getRequest
    keepRunning <- maybe False ((ruuid ==) . prsRepairUUID) <$> getPoolRepairStatus pool
    unless keepRunning $ continue finish
    case prt of
      M0.Repair -> do repairStatus pool
                      continue repair_status
      M0.Rebalance -> do rebalanceStatus pool
                         continue rebalance_status

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

-- | Start rebalance operation triggered by 'PoolRebalanceRequest'.
-- Emits 'PoolRebalanceStarted' if successful.
--
-- See 'ruleRepairStart' for some caveats.
--
-- See diagram sns-rebalance
ruleRebalanceStart :: Definitions RC ()
ruleRebalanceStart = mkJobRule jobRebalanceStart args $ \(JobHandle _ finish) -> do
  pool_disks_notified <- phaseHandle "pool_disks_notified"
  notify_failed <- phaseHandle "notify_failed"
  notify_timeout <- phaseHandle "notify_timeout"
  dispatcher <- mkDispatcher
  notifier <- mkNotifierSimpleAct dispatcher waitClear

  let init_rule (PoolRebalanceRequest pool) = getPoolRepairInformation pool >>= \case
        Nothing -> R.allIOSOnline pool >>= \case
          True -> do
            rg <- getGraph
            sdevs <- liftGraph Pool.getSDevs pool
            let sts = map (\d -> (getConfObjState d rg, d)) sdevs
            -- states that are considered as ‘OK, we can finish
            -- repair/rebalance’ states for the drives
            let okMessages = [M0_NC_REPAIRED, M0_NC_ONLINE]
             -- list of devices in OK state
                sdev_repaired = snd <$> filter (\(typ, _) -> typ == M0_NC_REPAIRED) sts
                (sdev_notready, sdev_ready) = partitionEithers $ deviceReadyStatus rg <$> sdev_repaired
                sdev_broken   = snd <$> filter (\(typ, _) -> typ `notElem` okMessages) sts
            for_ sdev_notready $ Log.rcLog' Log.DEBUG
            if null sdev_broken
            then if null sdev_ready
                  then return $ Left $ "Can't start rebalance, no drive to rebalance on"
                  else do
                    Log.rcLog' Log.DEBUG "starting rebalance"
                    disks <- catMaybes <$> mapM Drive.lookupSDevDisk sdev_ready
                    -- Can ignore K here: disks are in Repaired state
                    -- so moving to rebalancing does not increase
                    -- number of failures.
                    let messages = stateSet pool Tr.poolRebalance : (flip stateSet Tr.diskRebalance <$> disks)
                    modify Local $ rlens fldPoolDisks . rfield .~ Just (pool, disks)
                    notifications <- applyStateChanges messages
                    setExpectedNotifications notifications
                    waitFor notifier
                    waitFor notify_failed
                    onSuccess pool_disks_notified
                    onTimeout 10 notify_timeout
                    return $ Right (PoolRebalanceFailedToStart pool, [dispatcher])
            else do return . Left $ "Can't start rebalance, not all drives are ready: " ++ show sdev_broken
          False -> return $ Left "Not starting rebalance, some IOS are not online"
        Just info -> return . Left $ "Pool repair/rebalance is already running: " ++ show info


  (rebalance_started, startRebalance) <- mkRebalanceStartOperation $ \pool eresult -> do
     case eresult of
       Left _err -> do abortRebalanceStart
                       continue finish
       Right _uuid -> do modify Local $ rlens fldRep . rfield .~ Just (PoolRebalanceStarted pool)
                         updateSnsStartTime pool
                         continue finish

  (status_received, statusRebalance) <- mkRebalanceStatusRequestOperation
     (\_ s -> do Log.rcLog' Log.ERROR $ "failed to query SNS state: " ++ s
                 abortRebalanceStart
                 continue finish)
     (\_ sns -> if all R.iosReady $ Spiel._sss_state <$> sns
              then do
                Just (pool, disks) <- getField . rget fldPoolDisks <$> get Local
                startRebalance pool disks
                continue rebalance_started
              else do
                Log.rcLog' Log.ERROR $ "some IO services are not ready: " ++ show sns
                abortRebalanceStart
                continue finish)

  directly pool_disks_notified $ do
    Just (pool, _) <- getField . rget fldPoolDisks <$> get Local
    statusRebalance pool
    continue status_received

  setPhase notify_failed $ \(HAEvent uuid (NotifyFailureEndpoints eps)) -> do
    todo uuid
    when (not $ null eps) $ do
      Log.rcLog' Log.WARN $ "Failed to notify " ++ show eps ++ ", not starting rebalance"
      abortRebalanceStart
    done uuid
    continue finish

  directly notify_timeout $ do
    Log.rcLog' Log.WARN $ "Unable to notify Mero; cannot start rebalance"
    abortRebalanceStart
    continue finish

  return init_rule

  where
    abortRebalanceStart = getField . rget fldPoolDisks <$> get Local >>= \case
      Nothing -> Log.rcLog' Log.ERROR "No pool info in local state"
      Just (pool, _) -> do
        ds <- liftGraph2 Pool.getSDevsWithState pool M0_NC_REBALANCE
        -- Don't need to think about K here as both rebalance and
        -- repaired are failed states.
        _ <- applyStateChanges $ map (\d -> stateSet d Tr.sdevRebalanceAbort) ds
        unsetPoolRepairStatus pool

    -- Is this device ready to be rebalanced onto?
    deviceReadyStatus :: G.Graph -> M0.SDev -> Either String M0.SDev
    deviceReadyStatus rg s = case stats of
        Just (_, True, True, "OK") -> Right s
        Just other -> Left $ "Device not ready: " ++ showFid s
                      ++ " (sdev, Replaced, Powered, OK): "
                      ++ show other
        Nothing -> Left $ "No storage device or status could be found for " ++ showFid s
      where
        stats = do
          (disk :: M0.Disk) <- G.connectedTo s M0.IsOnHardware rg
          (sd :: StorageDevice) <- G.connectedTo disk At rg
          (StorageDeviceStatus sds _) <- G.connectedTo sd Is rg
          return ( sd
                 , G.isConnected disk Is M0.Replaced rg
                 , G.isConnected sd Has (SDPowered True) rg
                 , sds
                 )

    fldReq = Proxy :: Proxy '("request", Maybe PoolRebalanceRequest)
    fldRep = Proxy :: Proxy '("reply", Maybe PoolRebalanceStarted)
    fldPoolDisks = Proxy :: Proxy '("pooldisks", Maybe (M0.Pool, [M0.Disk]))

    args = fldUUID          =: Nothing
       <+> fldReq           =: Nothing
       <+> fldRep           =: Nothing
       <+> fldNotifications =: []
       <+> fldPoolDisks     =: Nothing
       <+> fldDispatch      =: Dispatch [] (error "ruleRebalanceStart dispatcher") Nothing

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
--
-- see diagram: sns-repair
ruleRepairStart :: Definitions RC ()
ruleRepairStart = mkJobRule jobRepairStart args $ \(JobHandle getRequest finish) -> do
  pool_disks_notified <- phaseHandle "pool_disks_notified"
  notify_failed <- phaseHandle "notify_failed"
  notify_timeout <- phaseHandle "notify_timeout"
  dispatcher <- mkDispatcher
  notifier <- mkNotifierSimpleAct dispatcher waitClear

  let init_rule (PoolRepairRequest pool) = getPoolRepairInformation pool >>= \case
        -- We spare ourselves some work and if IOS aren't ready then
        -- we don't even try to put the drives in repairing state just
        -- to flip them back a second later.
        Nothing -> R.allIOSOnline pool >>= \case
          True -> do
            tr <- liftGraph2 Pool.getSDevsWithState pool M0_NC_TRANSIENT
            fa <- liftGraph2 Pool.getSDevsWithState pool M0_NC_FAILED
            case null tr && not (null fa) of
              True -> do
                let -- OK to just set repairing here without checking K:
                    -- @fa@ are already failed by this point.
                    msgs = stateSet pool Tr.poolRepairing
                           : map (`stateSet` Tr.sdevRepairStart) fa
                modify Local $ rlens fldPool . rfield .~ Just pool
                notifications <- applyStateChanges msgs
                setExpectedNotifications notifications
                waitFor notifier
                waitFor notify_failed
                onSuccess pool_disks_notified
                onTimeout 10 notify_timeout
                return $ Right (PoolRepairFailedToStart pool "default", [dispatcher])
              False -> do
                return $ Left "Not starting repair, have transient or no failed devices"
          False -> do
            return $ Left "Not starting repair, some IOS are not online"
        Just _ -> do
          return $ Left "Not starting repair, seems there is repair already on-going"

  (repair_started, startRepairOperation) <- mkRepairStartOperation $ \pool er -> do
    case er of
      Left s -> do
        modify Local $ rlens fldRep . rfield .~ Just (PoolRepairFailedToStart pool s)
        continue finish
      Right _ -> do
        modify Local $ rlens fldRep . rfield .~ Just (PoolRepairStarted pool)
        updateSnsStartTime pool
        abort_if_needed pool
        continue finish

  (status_received, statusRepair) <- mkRepairStatusRequestOperation
     (\_ s -> do Log.rcLog' Log.ERROR $ "failed to query SNS state: " ++ s
                 abortRepairStart
                 continue finish)
     (\pool sns -> if all R.iosReady $ Spiel._sss_state <$> sns
              then do
                startRepairOperation pool
                continue repair_started
              else do
                Log.rcLog' Log.ERROR $ "some IO services are not ready: " ++ show sns
                abortRepairStart
                continue finish)

  directly pool_disks_notified $ do
    PoolRepairRequest pool <- getRequest
    statusRepair pool
    continue status_received

  -- Check if it's IOS that failed, if not then just keep going
  setPhase notify_failed $ \(HAEvent uuid (NotifyFailureEndpoints eps)) -> do
    todo uuid
    let msg = "Failed to notify " ++ show eps ++ ", not starting repair"
    PoolRepairRequest pool <- getRequest
    modify Local $ rlens fldRep . rfield .~ Just (PoolRepairFailedToStart pool msg)
    when (not $ null eps) $ do
      Log.rcLog' Log.WARN msg
      abortRepairStart
    done uuid
    continue finish

  -- Failure endpoint message didn't come and notification didn't go
  -- through either, abort just in case.
  directly notify_timeout $ do
    let msg = "Unable to notify Mero; cannot start repair"
    PoolRepairRequest pool <- getRequest
    Log.rcLog' Log.WARN msg
    modify Local $ rlens fldRep . rfield .~ Just (PoolRepairFailedToStart pool msg)
    abortRepairStart
    continue finish

  return init_rule
  where
    abortRepairStart = getField . rget fldPool <$> get Local >>= \case
      Nothing -> Log.rcLog' Log.ERROR "No pool info in local state"
      -- HALON-275: We have failed to start the repair so
      -- clean up repair status. halon:m0d should notice that
      -- notification has failed and fail the process, restart
      -- should happen and repair eventually restarted if
      -- everything goes right
      Just pool -> do
        ds <- liftGraph2 Pool.getSDevsWithState pool M0_NC_REPAIR
        -- There may be a race here: either this notification
        -- tries to go out first or the rule for failed
        -- notification fires first. The race does not matter
        -- because notification failure handler will check for
        -- already failed processes.
        _ <- applyStateChanges $ (`stateSet` Tr.sdevRepairAbort) <$> ds
        unsetPoolRepairStatus pool

    -- It's possible that after calling for the repair to start, but before
    -- receiving notification from the IOSservers that repair *has* started,
    -- additional drives have failed or transient. If this is the case, normal
    -- handling rules will not pick them up, because they arrive before PRS
    -- has been set. So after start, we check them again, and potentially abort
    -- at this point. Note this is different from 'abortRepairStart' as the
    -- repair has already started.
    abort_if_needed pool = getPoolRepairStatus pool >>= \case
      Just (M0.PoolRepairStatus _ uuid _) -> do
        tr <- liftGraph2 Pool.getSDevsWithState pool M0_NC_TRANSIENT
        fa <- liftGraph2 Pool.getSDevsWithState pool M0_NC_FAILED
        let new_transient = not (null tr)
            new_failed = not (null fa)
        when new_transient $
          Log.rcLog' Log.DEBUG $ "disks.transient: " ++ show tr
        when new_failed $
          Log.rcLog' Log.DEBUG $ "disks.failed: " ++ show fa
        case (new_transient, new_failed) of
          (False, True) -> do
            Log.rcLog' Log.DEBUG "Devices failed after repair start - restarting."
            promulgateRC $ RestartSNSOperationRequest pool uuid
          (True, False) -> do
            Log.rcLog' Log.DEBUG "Devices transient after repair start - quiescing."
            promulgateRC $ QuiesceSNSOperation pool
          (True, True) -> do
            Log.rcLog' Log.DEBUG "Devices both transient and failed after repair start - aborting."
            promulgateRC $ AbortSNSOperation pool uuid
          _ -> return ()
      Nothing -> Log.rcLog' Log.ERROR "abort_if_needed called but PRS is unset."

    fldReq = Proxy :: Proxy '("request", Maybe PoolRepairRequest)
    fldRep = Proxy :: Proxy '("reply", Maybe PoolRepairStartResult)
    fldPool = Proxy :: Proxy '("pool", Maybe M0.Pool)

    args = fldUUID          =: Nothing
       <+> fldReq           =: Nothing
       <+> fldRep           =: Nothing
       <+> fldNotifications =: []
       <+> fldPool          =: Nothing
       <+> fldDispatch      =: Dispatch [] (error "ruleRepairStart dispatcher") Nothing

-- | Job that convers all the repair continue logic.
jobContinueSNS :: Job ContinueSNS ContinueSNSResult
jobContinueSNS = Job "castor::sns:continue"


-- | Rule that check all if all nessesary conditions for pool repair start
-- are met and starts repair if so.
--
-- The requirements are:
--   * All IOS should be running.
--   * At least one IO service status should be M0_SNS_CM_STATUS_PAUSED.
--
-- See diagram sns-operation-continue
ruleSNSOperationContinue :: Definitions RC ()
ruleSNSOperationContinue = mkJobRule jobContinueSNS args $ \(JobHandle _ finish) -> do

  let process_failure pool s = do
        keepRunning <- isStillRunning pool
        if keepRunning
        then do Just (ContinueSNS ruuid _ prt) <- getField . rget fldReq <$> get Local
                modify Local $
                  rlens fldRep . rfield .~ Just (SNSFailed ruuid pool prt s)
        else do
          Log.rcLog' Log.WARN "SNS continue operation failedm but SNS is no longer registered in RG"
          continue finish
      check_and_run (phase, action) pool sns = do
       keep_running <- isStillRunning pool
       if keep_running
       then do
         let havePaused = any ((Spiel.M0_SNS_CM_STATUS_PAUSED ==) . Spiel._sss_state) sns
             allOk = all ((Spiel.M0_SNS_CM_STATUS_FAILED /=) . Spiel._sss_state) sns
         case (havePaused, allOk) of
           (True, True) -> do
             result <- R.allIOSOnline pool
             if result
             then action pool >> continue phase
             else process_failure pool "Not all IOS are ready"
           (True, False) -> do
             Just (ContinueSNS ruuid _ _) <- getField . rget fldReq <$> get Local
             promulgateRC $ AbortSNSOperation pool ruuid
             continue finish
           (False, _) -> do
             Just (ContinueSNS _ _ prt) <- getField . rget fldReq <$> get Local
             completeRepair pool prt Nothing
             continue finish
       else continue finish
      isStillRunning pool = do
        Just (ContinueSNS ruuid _ _) <- getField . rget fldReq <$> get Local
        maybe False ((ruuid ==) .prsRepairUUID)
                         <$> getPoolRepairStatus pool

  repair <- mkRepairContinueOperation process_failure $ \pool _ -> do
    Just (ContinueSNS ruuid _ prt) <- getField . rget fldReq <$> get Local
    modify Local $ rlens fldRep . rfield .~ Just (SNSContinued ruuid pool prt)
    continue finish

  (repair_status, repairStatus) <-
     mkRepairStatusRequestOperation process_failure
       $ check_and_run repair

  rebalance <- mkRebalanceContinueOperation process_failure $ \pool _ -> do
    Just (ContinueSNS ruuid _ prt) <- getField . rget fldReq <$> get Local
    modify Local $ rlens fldRep . rfield .~ Just (SNSContinued ruuid pool prt)
    continue finish

  (rebalance_status, rebalanceStatus) <-
    mkRebalanceStatusRequestOperation process_failure (check_and_run rebalance)

  return $ \(ContinueSNS uuid pool prt) -> do
        keepRunning <- isStillRunning pool
        result <- R.allIOSOnline pool
        if keepRunning && result
        then case prt of
          M0.Repair -> do
            repairStatus pool
            return $ Right (SNSFailed uuid pool prt "default", [repair_status])
          M0.Rebalance -> do
            rebalanceStatus pool
            return $ Right (SNSFailed uuid pool prt "default", [rebalance_status])
        else return $ Left "SNS Operation is not running"
  where
    fldReq = Proxy :: Proxy '("request", Maybe ContinueSNS)
    fldRep = Proxy :: Proxy '("reply", Maybe ContinueSNSResult)
    args = fldUUID          =: Nothing
       <+> fldReq           =: Nothing
       <+> fldRep           =: Nothing
       <+> RNil

newtype DelayedAbort = DelayedAbort M0.Pool
  deriving (Show, Eq, Ord, Generic)

-- | Delay SNS operation abort for some time.
jobDelayedAbort :: Job DelayedAbort ()
jobDelayedAbort = Job "castor::node::sns::delyed-abort"

ruleSNSOperationDelayedAbort :: Definitions RC ()
ruleSNSOperationDelayedAbort = mkJobRule jobDelayedAbort args $ \(JobHandle getRequest finish) -> do
   delayed <- phaseHandle "delayed"
   immediate <- phaseHandle "immediate"
   directly delayed $ do
     DelayedAbort pool <- getRequest
     getPoolRepairStatus pool >>= \case
       Just (M0.PoolRepairStatus _ uuid _) -> do
         promulgateRC $ AbortSNSOperation pool uuid
         continue finish
       Nothing -> continue finish
   setPhase immediate $ \AbortSNSOperation{} -> continue finish
   return $ const $ return $ Right ((), [immediate, timeout 30 delayed])
  where
    fldReq :: Proxy '("request", Maybe DelayedAbort)
    fldReq = Proxy
    fldRep :: Proxy '("reply", Maybe ())
    fldRep = Proxy
    args =  fldReq  =: Nothing
        <+> fldRep  =: Nothing


-- | Abort current SNS operation. Rule requesting SNS operation abort
-- and waiting for all IOs to be finalized.
jobSNSAbort :: Job AbortSNSOperation AbortSNSOperationResult
jobSNSAbort = Job "castor::node::sns::abort"

-- | Abort the specified SNS operation. Uses 'jobSNSAbort'.
--
-- See diagram: 'sns-operation-abort'
ruleSNSOperationAbort :: Definitions RC ()
ruleSNSOperationAbort = mkJobRule jobSNSAbort args $ \(JobHandle _ finish) -> do
  entry   <- phaseHandle "entry"
  ok      <- phaseHandle "ok"
  failure <- phaseHandle "SNS abort failed."

  let route (AbortSNSOperation pool uuid) = getPoolRepairStatus pool >>= \case
        Nothing -> do
          Log.rcLog' Log.DEBUG $ "Abort requested on " ++ show pool
                           ++ "but no repair seems to be happening."
          return $ Right (AbortSNSOperationSkip pool, [finish])
        Just (M0.PoolRepairStatus prt uuid' _) | uuid == uuid' -> do
          modify Local $ rlens fldPrt .~ (Field . Just $ prt)
          modify Local $ rlens fldRepairUUID .~ (Field . Just $ uuid')
          return $ Right (AbortSNSOperationFailure pool "default", [entry])
        Just (M0.PoolRepairStatus _ uuid' _) -> do
          Log.tagContext Log.Phase [ ("pool", show pool)
                                   , ("request.uuid", show uuid)
                                   , ("repair.uuid", show uuid')
                                   ] Nothing
          Log.rcLog' Log.DEBUG "Abort requested on UUIDs mismatch"
          let msg = show uuid ++ " /= " ++ show uuid'
          return $ Right (AbortSNSOperationFailure pool msg, [finish])

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
      M0.Repair -> do
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
    -- It appeared that HALON *should* put disk and pool back to the failed state
    -- After abort.
    -- https://seagate.slack.com/archives/mero-halon/p1487363284005215
    ds <- liftGraph2 Pool.getSDevsWithState pool M0_NC_REBALANCE
    _ <- applyStateChanges $ (`stateSet` Tr.sdevRebalanceAbort) <$> ds
    ds1 <- liftGraph2 Pool.getSDevsWithState pool M0_NC_REPAIR
    _ <- applyStateChanges $ (`stateSet` Tr.sdevRepairAbort) <$> ds1
    continue finish

  directly failure $ do
    Log.rcLog' Log.WARN "SNS abort failed - removing Pool repair info."
    Just (AbortSNSOperation pool _) <- getField . rget fldReq <$> get Local
    Just uuid <- getField . rget fldRepairUUID <$> get Local
    unsetPoolRepairStatusWithUUID pool uuid

    ds <- liftGraph2 Pool.getSDevsWithState pool M0_NC_REBALANCE
    _ <- applyStateChanges $ (`stateSet` Tr.sdevRebalanceAbort) <$> ds
    ds1 <- liftGraph2 Pool.getSDevsWithState pool M0_NC_REPAIR
    _ <- applyStateChanges $ (`stateSet` Tr.sdevRepairAbort) <$> ds1
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
        <+> fldSNSOperationRetryState =: defaultSNSOperationRetryState

-- | 'Job' used by 'ruleSNSOperationQuiesce'.
jobSNSQuiesce :: Job QuiesceSNSOperation QuiesceSNSOperationResult
jobSNSQuiesce = Job "castor::sns::quiesce"

-- | Quiesce the specified SNS operation. Uses 'jobSNSQuiesce'.
ruleSNSOperationQuiesce :: Definitions RC ()
ruleSNSOperationQuiesce = mkJobRule jobSNSQuiesce args $ \(JobHandle _ finish) -> do
  entry <- phaseHandle "execute operation"

  let route (QuiesceSNSOperation pool) = do
       Log.actLog "Quisce request." [ ("pool.fid", show (M0.fid pool)) ]
       mprs <- getPoolRepairStatus pool
       case mprs of
         Nothing -> do Log.rcLog' Log.WARN $ "no repair seems to be happening"
                       return $ Right (QuiesceSNSOperationSkip pool, [finish])
         Just (M0.PoolRepairStatus prt uuid _) -> do
           modify Local $ rlens fldPrt .~ (Field . Just $ prt)
           modify Local $ rlens fldUUID .~ (Field . Just $ uuid)
           return $ Right (QuiesceSNSOperationFailure pool "default", [entry])

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
      M0.Repair -> do
        quiesceRepair pool
        continue ph_repair_quiesced
      M0.Rebalance -> do
        quiesceRebalance pool
        continue ph_rebalance_quiesced

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
        <+> fldSNSOperationRetryState =: defaultSNSOperationRetryState

jobSNSOperationRestart :: Job RestartSNSOperationRequest RestartSNSOperationResult
jobSNSOperationRestart = Job "castor::sns::restart"

-- | Abort an ongoing SNS operation and restart it. Returns one of the
--   following:
--   'RestartSNSOperationSuccess' - if operation was restarted
--   'RestartSNSOperationFailed' - if operation could not be restarted
--   'RestartSNSOperationSkip' - if no operation was running
--   This rule itself just invokes 'abort' and subsequently 'start' rules.
ruleSNSOperationRestart :: Definitions RC ()
ruleSNSOperationRestart = mkJobRule jobSNSOperationRestart args $ \(JobHandle _ finish) -> do
  abort_req <- phaseHandle "abort_req"
  start_req <- phaseHandle "start_req"
  result <- phaseHandle "result"

  directly abort_req $ do
    Just (RestartSNSOperationRequest pool uuid) <- getField . rget fldReq <$> get Local
    mprs <- getPoolRepairStatus pool
    case mprs of
      Just _ -> do
        promulgateRC $ AbortSNSOperation pool uuid
        continue start_req
      Nothing -> do
        Log.rcLog' Log.DEBUG "Skipping repair as pool repair status is not set."
        modify Local $ rlens fldRep . rfield .~ (Just $ RestartSNSOperationSkip pool)
        continue finish

  setPhase start_req $ \absns -> do
    Just (RestartSNSOperationRequest pool _) <- getField . rget fldReq <$> get Local
    case absns of
      AbortSNSOperationOk pool' | pool == pool' -> do
        promulgateRC $ PoolRepairRequest pool
        continue result
      AbortSNSOperationFailure pool' err | pool == pool' -> do
        modify Local $ rlens fldRep . rfield .~ (Just $ RestartSNSOperationFailed pool err)
        continue finish
      AbortSNSOperationSkip pool' | pool == pool' -> do
        modify Local $ rlens fldRep . rfield .~ (Just $ RestartSNSOperationSkip pool)
        continue finish
      _ -> continue start_req

  setPhase result $ \prsr -> do
    Just (RestartSNSOperationRequest pool _) <- getField . rget fldReq <$> get Local
    case prsr of
      PoolRepairStarted pool' | pool == pool' -> do
        modify Local $ rlens fldRep . rfield .~ (Just $ RestartSNSOperationSuccess pool)
        continue finish
      PoolRepairFailedToStart pool' err | pool == pool' -> do
        modify Local $ rlens fldRep . rfield .~ (Just $ RestartSNSOperationFailed pool err)
        continue finish
      _ -> continue result

  return $ \(RestartSNSOperationRequest pool _) ->
    return $ Right (RestartSNSOperationFailed pool "default", [abort_req])
  where
    fldReq = Proxy :: Proxy '("request", Maybe RestartSNSOperationRequest)
    fldRep = Proxy :: Proxy '("reply", Maybe RestartSNSOperationResult)

    args =  fldUUID =: Nothing
        <+> fldRep =: Nothing
        <+> fldReq =: Nothing

-- | If Quiesce operation on pool failed - we need to abort SNS operation.
ruleOnSnsOperationQuiesceFailure :: Definitions RC ()
ruleOnSnsOperationQuiesceFailure = defineSimple "castor::sns::abort-on-quiesce-error" $ \result ->
   case result of
    (QuiesceSNSOperationFailure pool _) -> do
       mprs <- getPoolRepairStatus pool
       case mprs of
         Nothing -> return ()
         Just prs  -> promulgateRC . AbortSNSOperation pool $ prsRepairUUID prs
    _ -> return ()

-- | Log 'StobIoqError' and abort repair if it's on-going.
ruleStobIoqError :: Definitions RC ()
ruleStobIoqError = defineSimpleTask "stob_ioq_error" $ \(HAMsg stob meta) -> do
  Log.actLog "stob ioq error" [ ("meta", show meta)
                              , ("stob", show stob) ]
  rg <- getGraph
  case M0.lookupConfObjByFid (_sie_conf_sdev stob) rg of
    Nothing -> Log.rcLog' Log.WARN $ "SDev for " ++ show (_sie_conf_sdev stob) ++ " not found."
    Just sdev -> getSDevPool sdev >>= \pool -> getPoolRepairStatus pool >>= \case
      Nothing -> Log.rcLog' Log.DEBUG $ "No repair on-going on " ++ showFid pool
      Just prs -> promulgateRC . AbortSNSOperation pool $ prsRepairUUID prs

--------------------------------------------------------------------------------
-- Actions                                                                    --
--------------------------------------------------------------------------------


-- | Continue a previously-quiesced SNS operation.
continueSNS :: M0.Pool  -- ^ Pool under SNS operation
            -> M0.PoolRepairType
            -> PhaseM RC l ()
continueSNS pool prt = do
  -- We check what we have actualy registered in graph in order to
  -- understand what can we do. Theoretically it should not be needed
  -- and we could be able to get all info in runtime, without storing
  -- data in the graph.
  mprs <- getPoolRepairStatus pool
  case mprs of
    Nothing -> Log.rcLog' Log.WARN $
      "continue repair was called, when no SNS operation were registered\
       \- ignoring"
    Just prs ->
      if prsType prs == prt
      then promulgateRC $ ContinueSNS (prsRepairUUID prs) pool prt
      else Log.rcLog' Log.WARN $
             "Continue for " ++ show prt
                             ++ "was requested, but "
                             ++ show (prsType prs) ++ "is registered."

-- | Quiesce the repair on the given pool if the repair is on-going.
quiesceSNS :: M0.Pool -> PhaseM RC l ()
quiesceSNS pool = promulgateRC $ QuiesceSNSOperation pool

-- | Complete the given pool repair by notifying mero about all the
-- devices being repaired and marking the message as processed.
--
-- If the repair/rebalance has not finished on every device in the
-- pool, will send information about devices that did complete and
-- continue with the process.
--
-- Starts rebalance if we were repairing and have fully completed.
completeRepair :: Pool -> PoolRepairType -> Maybe UUID -> PhaseM RC l ()
completeRepair pool prt muid = do
  -- if no status is found for SDev, assume M0_NC_ONLINE
  let getSDevState :: M0.SDev -> PhaseM RC l' ConfObjectState
      getSDevState d = getConfObjState d <$> getGraph

  iosvs <- length <$> R.getIOServices pool
  mdrive_updates <- fmap M0.priStateUpdates <$> getPoolRepairInformation pool
  case mdrive_updates of
    Nothing -> Log.rcLog' Log.WARN $ "No pool repair information were found for " ++ show pool
    Just drive_updates -> do
      sdevs <- liftGraph Pool.getSDevs pool
      sts <- mapM (\d -> (,d) <$> getSDevState d) sdevs

      let -- devices that are under operation
          repairing_sdevs = Set.fromList [ d | (t,d) <- sts, t == R.repairingNotificationMsg prt]
          -- drives that were fixed during operation
          repaired_sdevs = Set.fromList [ f | (f, v) <- drive_updates, v >= iosvs]
          -- drives that are under operation but were not fixed
          non_repaired_sdevs = repairing_sdevs `Set.difference` repaired_sdevs

          repairedSdevTr M0.Repair = Tr.sdevRepairComplete
          repairedSdevTr M0.Rebalance = Tr.sdevRebalanceComplete

      unless (null repaired_sdevs) $ do
        _ <- applyStateChanges $ map (`stateSet` repairedSdevTr prt) (Set.toList repaired_sdevs)

        when (prt == M0.Rebalance) $ forM_ repaired_sdevs unmarkSDevReplaced

        if Set.null non_repaired_sdevs
        then do Log.rcLog' Log.DEBUG $ "Full repair on " ++ show pool
                _ <- applyStateChanges [stateSet pool $ R.snsCompletedTransition prt]
                unsetPoolRepairStatus pool
                when (prt == M0.Repair) $ promulgateRC (PoolRebalanceRequest pool)
        else do Log.rcLog' Log.DEBUG $ "Some devices failed to repair: " ++ show (Set.toList non_repaired_sdevs)
                -- TODO: schedule next repair.
                unsetPoolRepairStatus pool
        traverse_ messageProcessed muid

-- | Dispatch appropriate repair/rebalance action as a result of the
-- notifications beign received.
--
-- TODO: add link to diagram.
--
-- TODO: Currently we don't handle a case where we have pool
-- information in the message set but also some disks which belong to
-- a different pool.
ruleHandleRepairNVec :: Definitions RC ()
ruleHandleRepairNVec = defineSimpleTask "castor::sns::handle-repair-nvec" $ \noteSet -> do
   getPoolInfo noteSet >>= traverse_ run
   where
     run (PoolInfo pool st m) = do
       Log.rcLog' Log.DEBUG $ "Processed as PoolInfo " ++ show (pool, st, m)
       mprs <- getPoolRepairStatus pool
       forM_ mprs $ \prs@(PoolRepairStatus _prt _ mpri) ->
         forM_ mpri $ \pri -> do
           let disks = getSDevs m st
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
ruleHandleRepair :: Definitions RC ()
ruleHandleRepair = defineSimpleTask "castor::sns::handle-repair" $ \msg ->
  getClusterStatus <$> getGraph >>= \case
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
      Log.rcLog' Log.DEBUG $ "Processed as " ++ show (DevicesOnly devices)
      for_ devices $ \(pool, diskMap) -> do

        tr <- liftGraph2 Pool.getSDevsWithState pool M0_NC_TRANSIENT
        fa <- liftGraph2 Pool.getSDevsWithState pool M0_NC_FAILED
        repairing <- liftGraph2 Pool.getSDevsWithState pool M0_NC_REPAIR

            -- If no devices are transient and something is failed, begin
            -- repair. It's up to caller to ensure any previous repair has
            -- been aborted/completed.
            -- TODO This is a bit crap. At least badly named. Redo it.
        let maybeBeginRepair =
              if null tr && not (null fa)
              then promulgateRC $ PoolRepairRequest pool
              else do Log.rcLog' Log.DEBUG $ "Failed: " ++ show fa ++ ", Transient: " ++ show tr
                      maybeBeginRebalance

            -- If there are neither failed nor transient, and no new transient
            -- devices were reported we could request pool rebalance procedure start.
            -- That procedure can decide itself if there any work to do.
            maybeBeginRebalance = when (and [ null tr
                                            , null repairing
                                            , null fa
                                            ])
              $ promulgateRC (PoolRebalanceRequest pool)

        getPoolRepairStatus pool >>= \case
          Just (M0.PoolRepairStatus prt uuid _)
            -- Repair happening, device failed, restart repair
            | fa' <- getSDevs diskMap M0_NC_FAILED
            , not (S.null fa') -> do
              Log.rcLog' Log.DEBUG $ "Repair happening, device failed, restart repair"
              promulgateRC $ RestartSNSOperationRequest pool uuid
            -- Repair happening, some devices are transient
            | tr' <- getSDevs diskMap M0_NC_TRANSIENT
            , not (S.null tr') -> do
                Log.rcLog' Log.DEBUG $ "Got M0_NC_TRANSIENT for " ++ show (pool, tr)
                                 ++ ", quescing repair."
                quiesceSNS pool
            -- Repair happening, something came online, check if
            -- nothing is left transient and continue repair if possible
            | Just ds <- allWithState diskMap M0_NC_ONLINE
            , ds' <- S.toList ds -> do
                sdevs <- filter (`notElem` ds') <$> liftGraph Pool.getSDevs pool
                sts <- getGraph >>= \rg ->
                  return $ (flip getConfObjState $ rg) <$> sdevs
                if M0_NC_TRANSIENT `notElem` sts
                then continueSNS pool prt
                else Log.rcLog' Log.DEBUG $ "Still some drives transient: " ++ show sts
            | otherwise -> Log.rcLog' Log.DEBUG $
                "Repair on-going but don't know what to do with " ++ show diskMap
          Nothing -> do
            Log.rcLog' Log.DEBUG "No ongoing repair found, maybe begin repair."
            maybeBeginRepair

-- | When the cluster has completed starting up, it's possible that
--   we have devices that failed during the startup process.
checkRepairOnClusterStart :: Definitions RC ()
checkRepairOnClusterStart = defineSimpleIf "check-repair-on-start" clusterOnBootLevel2 $ \() -> do
  pools <- Pool.getNonMD <$> getGraph
  forM_ pools $ promulgateRC . PoolRepairRequest
  where
    clusterOnBootLevel2 msg ls = barrierPass (\mcs -> _mcs_runlevel mcs >= M0.BootLevel 2) msg ls ()


-- | We have received information about a pool state change (as well
-- as some devices) so handle this here. Such a notification is likely
-- to have come from IOS indicating things like finished
-- repair/rebalance.
processPoolInfo :: M0.Pool
                -- ^ Pool to work on
                -> ConfObjectState
                -- ^ Status of the pool
                -> SDevStateMap
                -- ^ Status of the disks in the pool as received in a
                -- notification. Note this may not be the full set of
                -- disks belonging to the pool.
                -> PhaseM RC l ()

-- We are rebalancing and have received ONLINE for the pool and all
-- the devices: rebalance is finished so simply fall back to query
-- handler which will query the repair status and complete the
-- procedure.
processPoolInfo pool M0_NC_ONLINE m
  | Just _ <- allWithState m M0_NC_ONLINE = getPoolRepairStatus pool >>= \case
      Nothing -> Log.rcLog' Log.WARN $ "Got M0_NC_ONLINE for a pool but "
                                   ++ "no pool repair status was found."
      Just (M0.PoolRepairStatus M0.Rebalance _ _) -> do
        Log.rcLog' Log.DEBUG $ "Got M0_NC_ONLINE for a pool that is rebalancing."
        -- Will query spiel for repair status and complete the repair
        queryStartHandling pool
      _ -> Log.rcLog' Log.DEBUG $ "Got M0_NC_ONLINE but pool is repairing now."

-- We got a REPAIRED for a pool that was repairing before. Currently
-- we simply fall back to queryStartHandling which should conclude the
-- repair.
processPoolInfo pool M0_NC_REPAIRED _ = getPoolRepairStatus pool >>= \case
  Nothing -> Log.rcLog' Log.WARN $ "Got M0_NC_REPAIRED for a pool but "
                               ++ "no pool repair status was found."
  Just (M0.PoolRepairStatus prt _ _)
    | prt == M0.Repair -> queryStartHandling pool
  _ -> Log.rcLog' Log.DEBUG $ "Got M0_NC_REPAIRED but pool is rebalancing now."

-- Partial repair or problem during repair on a pool, if one of IOS
-- experienced problem - we abort repair.
processPoolInfo pool M0_NC_REPAIR _ = getPoolRepairStatus pool >>= \case
  Nothing -> Log.rcLog' Log.WARN $ "Got M0_NC_REPAIR for a pool but "
                               ++ "no pool repair status was found."
  Just (M0.PoolRepairStatus prt _ _)
    | prt == M0.Repair -> do
        getClusterStatus <$> getGraph >>= \case
          Just (M0.MeroClusterState M0.ONLINE _ _) -> do
            Log.rcLog' Log.DEBUG $ "Got partial repair -- aborting."
            promulgateRC $ DelayedAbort pool
          _ -> return ()
  _ -> Log.rcLog' Log.DEBUG $ "Got M0_NC_REPAIR but pool is rebalancing now."

-- Partial repair or problem during repair on a pool, if one of IOS
-- experienced problem - we abort repair.
processPoolInfo pool M0_NC_REBALANCE _ = getPoolRepairStatus pool >>= \case
  Nothing -> Log.rcLog' Log.WARN $ "Got M0_NC_REBALANCE for a pool but "
                               ++ "no pool repair status was found."
  Just (M0.PoolRepairStatus prt _ _)
    | prt == M0.Rebalance -> do
        getClusterStatus <$> getGraph >>= \case
          Just (M0.MeroClusterState M0.ONLINE _ _) -> do
            Log.rcLog' Log.DEBUG $ "Got partial rebalance -- aborting."
            promulgateRC $ DelayedAbort pool
          _ -> return ()
  _ -> Log.rcLog' Log.DEBUG $ "Got M0_NC_REBALANCE but pool is repairing now."

-- We got some pool state info but we don't care about what it is as
-- it seems some devices belonging to the pool failed, abort repair.
-- It should not hurt to keep around and process any M0_NC_FAILED that
-- mero still happens to send here: if it gets here before
-- m0_stob_ioq_error, we can start abort already and we know that we
-- shouldn't quiesce or something else. Abort is a job so requesting
-- it again when m0_stob_ioq_error arrives does not hurt us.
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
        sdevs <- filter (`notElem` ds') <$> liftGraph Pool.getSDevs pool
        sts <- getGraph >>= \rg ->
          return $ (flip getConfObjState $ rg) <$> sdevs
        if null $ filter (== M0_NC_TRANSIENT) sts
        then continueSNS pool prt
        else Log.rcLog' Log.DEBUG $ "Still some drives transient: " ++ show sts
      _ -> Log.rcLog' Log.DEBUG $ "Got some transient drives but repair not on-going on " ++ show pool
-- Some devices came up as transient, quiesce repair if it's on-going.
  | tr <- getSDevs m M0_NC_TRANSIENT
  , _:_ <- S.toList tr = getPoolRepairStatus pool >>= \case
      Nothing -> do
        Log.rcLog' Log.DEBUG $ "Got M0_NC_TRANSIENT for " ++ show (pool, tr)
                         ++ " but no repair is on-going, doing nothing."
      Just (M0.PoolRepairStatus _ _ _) -> do
        Log.rcLog' Log.DEBUG $ "Got M0_NC_TRANSIENT for " ++ show (pool, tr)
                         ++ ", quescing repair."
        quiesceSNS pool

processPoolInfo pool st m = Log.rcLog' Log.WARN $ unwords
  [ "Got", show st, "for a pool", show pool
  , "but don't know how to handle it: ", show m ]

--------------------------------------------------------------------------------
-- Helpers                                                                    --
--------------------------------------------------------------------------------

-- | Info about Pool repair update. Such sets are sent by the IO
-- services during repair and rebalance procedures.
data PoolInfo = PoolInfo M0.Pool ConfObjectState SDevStateMap deriving (Show)

-- | Given a 'Set', figure out if this update belongs to a 'PoolInfo' update.
--
-- TODO: this function do not support processing more than one set in one
-- message.
getPoolInfo :: Set -> PhaseM RC l (Maybe PoolInfo)
getPoolInfo (Set ns _) =
  mapMaybeM (\(Note fid' typ) -> fmap (typ,) <$> lookupConfObjByFid fid') ns >>= \case
    [(typ, pool)] -> do
      disks <- M.fromListWith (<>) . map (second S.singleton) <$> mapMaybeM noteToSDev ns
      return . Just . PoolInfo pool typ $ SDevStateMap disks
    _ -> return Nothing
  where
    mapMaybeM f xs = catMaybes <$> mapM f xs

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
                -> PhaseM RC l (Maybe DevicesOnly)
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
checkRepairOnServiceUp :: Definitions RC ()
checkRepairOnServiceUp = define "checkRepairOnProcessStarted" $ do
    init_rule <- phaseHandle "init_rule"

    setPhaseInternalNotification init_rule (\o n -> o /= M0.PSOnline &&  n == M0.PSOnline)
      $ \(eid, procs :: [(M0.Process, M0.ProcessState)]) -> do
      todo eid
      rg <- getGraph
      when (isJust $ find (flip isIOSProcess rg) (fst <$> procs)) $ do
        let failedIOS = [ p | p <- Process.getAll rg
                            , M0.PSFailed _ <- [getState p rg]
                            , isIOSProcess p rg ]
        case failedIOS of
          [] -> do
            pools <- Pool.getNonMD <$> getGraph
            for_ pools $ \pool -> case getState pool rg of
              -- TODO: we should probably be setting pool to failed too but
              -- after abort we lose information on what kind of repair was
              -- happening so we currently can't; perhaps we need to mark
              -- what kind of failure it was
              M0_NC_REBALANCE -> promulgateRC (PoolRebalanceRequest pool)
              M0_NC_REPAIR -> promulgateRC (PoolRepairRequest pool)
              M0_NC_ONLINE -> return ()
              st -> Log.rcLog' Log.WARN $
                "checkRepairOnProcessStart: Don't know how to deal with pool state " ++ show st
          ps -> Log.rcLog' Log.DEBUG $ "Still waiting for following IOS processes: " ++ show (M0.fid <$> ps)
      done eid

    start init_rule ()

  where
    isIOSProcess p rg = not . null $ [s | s <- G.connectedTo p M0.IsParentOf rg
                                        , CST_IOS <- [M0.s_type s] ]

-- | All rules exported by this module.
rules :: Definitions RC ()
rules = sequence_
  [ checkRepairOnClusterStart
  , checkRepairOnServiceUp
  , ruleRepairStart
  , ruleRebalanceStart
  , ruleStobIoqError
  , ruleSNSOperationAbort
  , ruleSNSOperationDelayedAbort
  , ruleSNSOperationQuiesce
  , ruleSNSOperationContinue
  , ruleSNSOperationRestart
  , ruleOnSnsOperationQuiesceFailure
  , ruleHandleRepair
  , ruleHandleRepairNVec
  , querySpiel
  , querySpielHourly
  ]

deriveSafeCopy 0 'base ''DelayedAbort
