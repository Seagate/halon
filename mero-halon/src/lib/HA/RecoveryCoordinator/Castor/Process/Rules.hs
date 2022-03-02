{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase       #-}
{-# LANGUAGE TypeFamilies     #-}
{-# LANGUAGE TypeOperators    #-}
{-# LANGUAGE ViewPatterns     #-}

-- |
-- Module    : HA.RecoveryCoordinator.Castor.Process.Rules
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Process handling.
module HA.RecoveryCoordinator.Castor.Process.Rules
  ( rules ) where

import           Control.Distributed.Process (Process, sendChan)
import           Control.Lens
import           Control.Monad (when, unless, void)
import           Data.Binary (Binary)
import           Data.Foldable
import           Data.List (nub)
import           Data.Maybe (isJust, listToMaybe)
import qualified Data.Text as T
import           Data.Typeable
import qualified Data.UUID as UUID
import           Data.Vinyl
import           GHC.Generics (Generic)
import           HA.EventQueue
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Castor.Cluster.Actions
import           HA.RecoveryCoordinator.Castor.Cluster.Events
import qualified HA.RecoveryCoordinator.Castor.Process.Actions as Process
import           HA.RecoveryCoordinator.Castor.Process.Events
import           HA.RecoveryCoordinator.Castor.Process.Rules.Keepalive
import           HA.RecoveryCoordinator.Job.Actions
import           HA.RecoveryCoordinator.Job.Events (JobFinished(..))
import           HA.RecoveryCoordinator.Mero.Events
import           HA.RecoveryCoordinator.Mero.Notifications
import           HA.RecoveryCoordinator.Mero.State
import qualified HA.RecoveryCoordinator.Mero.Transitions as Tr
import qualified HA.RecoveryCoordinator.Mero.Transitions.Internal as TrI
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.ResourceGraph as G
import           HA.Resources (Has(..), Runs(..), Node(..))
import           HA.Resources.Castor (Host(..), Is(..))
import qualified HA.Resources.Castor.Initial as CI
import           HA.Resources.HalonVars
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note (getState, NotifyFailureEndpoints(..), showFid)
import           HA.Service.Interface
import           HA.Services.Mero.Types
import           Mero.ConfC (ServiceType(CST_HA))
import           Mero.Notification.HAState
import           Network.CEP
import           Text.Printf

-- | Set of rules used for mero processes.
rules :: Definitions RC ()
rules = sequence_ [
    ruleProcessStarting
  , ruleProcessOnline
  , ruleProcessStopping
  , ruleProcessStopped
  , ruleProcessDispatchRestart
  , ruleProcessStart
  , ruleProcessStop
  , requestUserStopsProcess
  , ruleFailedNotificationFailsProcess
  , ruleProcessKeepaliveReply
  , ruleRpcEvent
  ]

-- | Catch 'InternalObjectStateChange's flying by and dispatch
-- 'ProcessRestartRequest' for every failed process, allowing
-- 'ruleProcessStart' to do its job while assuring only one on-going
-- restart per process.
ruleProcessDispatchRestart :: Definitions RC ()
ruleProcessDispatchRestart = define "rule-process-dispatch-restart" $ do
  rule_init <- phaseHandle "rule_init"

  setPhaseInternalNotification rule_init isProcFailed $ \(eid, procs) -> do
    todo eid
    -- Filter CST_HA processes out: if halon:m0d fails, process fails
    -- too (eventKernelFailed)
    rg <- getGraph
    let procs' = [ p | (p, _) <- procs
                     , let srvs = G.connectedTo p M0.IsParentOf rg
                     , not $ any (\s -> M0.s_type s == CST_HA) srvs ]

    for_ procs' $ promulgateRC . ProcessStartRequest
    Log.rcLog' Log.DEBUG $ "Restarting processes: " ++ show procs'
    done eid

  startFork rule_init ()
  where
    -- Don't restart after we leave inhibited, for example after node
    -- recovery: other mechanisms should recover the processes explicitly
    isProcFailed (M0.PSInhibited _) (M0.PSFailed _) = False
    -- Don't restart if we change reason for failure
    isProcFailed (M0.PSFailed _) (M0.PSFailed _) = False
    -- Don't restart when we were stopping the process
    isProcFailed M0.PSStopping _ = False
    isProcFailed M0.PSQuiescing _ = False

    isProcFailed _ (M0.PSFailed _) = True
    isProcFailed _ _ = False

-- | Job used in 'ruleProcessStart'
jobProcessStart :: Job ProcessStartRequest ProcessStartResult
jobProcessStart = Job "process-start"

-- | Start a process. Configure if necessary. Will restart if process
-- is already running. It is up to the user to check if process is
-- already running before invoking this job if they do not want to
-- risk restarting the process.
--
-- This rule is intended to be "the one true process starter".
-- Notably, this means that only process start logic that users should
-- concern themselves with is:
--
-- * Do we want to (re)start the process?
-- * Is halon:m0d up and running on the node?
-- * What is the result of the job?
--
-- This job always returns: it's not necessary for the caller to have
-- a timeout.
--
-- TODO: We need better invariant checking: for example we want to
-- verify process doesn't enter unexpected state, that node remains
-- online, that cluster remains online. Basically we have little
-- resilence towards cluster state changing after we have made initial
-- checks at start of the job.
ruleProcessStart :: Definitions RC ()
ruleProcessStart = mkJobRule jobProcessStart args $ \(JobHandle getRequest finish) -> do
  starting_notify_timed_out <- phaseHandle "starting_notify_timed_out"
  configure <- phaseHandle "configure"
  configure_result <- phaseHandle "configure_result"
  configure_timeout <- phaseHandle "configure_timeout"
  start_process <- phaseHandle "start_process"
  start_process_cmd_result <- phaseHandle "start_process_result"
  stop_finished <- phaseHandle "stop_finished"
  start_process_complete <- phaseHandle "start_process_complete"
  start_process_timeout <- phaseHandle "start_process_timeout"
  start_process_failure <- phaseHandle "start_process_failure"
  start_process_retry <- phaseHandle "start_process_retry"
  dispatch <- mkDispatcher
  notifier <- mkNotifierSimple dispatch

  let defaultReply c m = do
        Log.rcLog' Log.WARN m
        ProcessStartRequest p <- getRequest
        _ <- applyStateChanges [ stateSet p $ Tr.processFailed m ]
        return (c p m, [finish])

  let fail_start m = snd <$> defaultReply ProcessStartFailed m

  let route (ProcessStartRequest p) = do
        rg <- getGraph
        case runChecks p rg of
          Just chkFailMsg ->
            Right <$> defaultReply ProcessStartInvalid chkFailMsg
          Nothing -> initResources p rg >>= \case
            Just failMsg -> Right <$> defaultReply ProcessStartFailed failMsg
            Nothing -> do
              forM_ (runWarnings p rg) $ Log.rcLog' Log.WARN

              waitClear
              waitFor notifier
              onTimeout 120 starting_notify_timed_out

              -- It may seem risky doing this check early but it
              -- should be OK: if it's not configured now, it's not
              -- going to suddenly become configured in few seconds
              -- when notification gets ack'd. This job is the only
              -- place that can configure and attach this flag (modulo
              -- cluster reset).
              onSuccess $ if G.isConnected p Is M0.ProcessBootstrapped rg
                          then start_process
                          else configure

              notifications <- applyStateChanges [stateSet p Tr.processStarting]
              setExpectedNotifications notifications
              return $ Right (ProcessStartFailed p "default", [dispatch])

  directly starting_notify_timed_out $ do
    ProcessStartRequest p <- getRequest
    Log.rcLog' Log.WARN $ "Failed to notify PSStarting for " ++ showFid p
    fail_start "Notification about PSStarting failed" >>= switch

  directly configure $ do
    Just sender <- getField . rget fldSender <$> get Local
    Just (toType -> runType) <- getField . rget fldProcessType <$> get Local
    ProcessStartRequest p <- getRequest
    Log.rcLog' Log.DEBUG $ "Configuring " ++ showFid p
    confUUID <- configureMeroProcess sender p runType
    modify Local $ rlens fldConfigureUUID . rfield .~ Just confUUID
    t <- getHalonVar _hv_process_configure_timeout
    switch [configure_result, timeout t configure_timeout]

  setPhaseIf configure_result configureResult $ \case
    -- HALON-635: RC might have restarted before we received a
    -- configure result from the service which can result in multiple
    -- messages coming in. With unfortunate timing, this can mean we
    -- quickly go over configure_result and try to start the process
    -- while the configure command from this rule invocation is
    -- actually still on-going. Instead, identify the message with
    -- UUID and only listen to results from the invocation from this
    -- rule run.
    WrongUUID uid -> do
      Log.rcLog' Log.WARN "Received process configure result from different invocation."
      messageProcessed uid
      t <- getHalonVar _hv_process_configure_timeout
      switch [configure_result, timeout t configure_timeout]
    ConfigureFailure uid failMsg -> do
      messageProcessed uid
      fail_start ("Configuration failed: " ++ failMsg) >>= switch
    ConfigureSuccess uid -> do
      ProcessStartRequest p <- getRequest
      modifyGraph $ G.connect p Is M0.ProcessBootstrapped
      messageProcessed uid
      Log.rcLog' Log.DEBUG $ "Configuration successful for " ++ showFid p
      continue start_process

  directly configure_timeout $ do
    fail_start "Configuration timed out" >>= switch

  -- XXX: Be more defensive; check invariants: ProcessBootstrapped,
  -- PSStarting, disposition still in ONLINE
  directly start_process $ do
    Just sender <- getField . rget fldSender <$> get Local
    Just (toType -> runType) <- getField . rget fldProcessType <$> get Local
    ProcessStartRequest p <- getRequest
    Just procType <- getField . rget fldProcessType <$> get Local
    case procType of
      CI.PLClovis _ CI.Independent -> do
        Log.rcLog' Log.DEBUG
          "Independent Clovis process, we don't manage it."
        modify Local $ rlens fldRep . rfield .~ Just (ProcessConfiguredOnly p)
        -- Put the process in unknown state again.
        _ <- applyStateChanges [ stateSet p Tr.processUnknown ]
        continue finish
      _ -> do
        Log.rcLog' Log.DEBUG (printf "Requesting start of %s (%s)"
                              (showFid p) (show runType) :: String)
        liftProcess . sender . ProcessMsg $! StartProcess runType p
        t <- _hv_process_start_cmd_timeout <$> getHalonVars
        switch [start_process_cmd_result, timeout t start_process_timeout]

  setPhaseIf start_process_cmd_result startCmdResult $ \(uid, r) -> do
    messageProcessed uid
    case r of
      StartFailure _ failMsg -> do
        finisher <- fail_start $ "Process start command failed: " ++ failMsg
        messageProcessed uid
        switch finisher
      Started p pid -> do
        Log.actLog "systemctl OK" [ ("fid", showFid p)
                                  , ("pid", show pid) ]
        messageProcessed uid
        modifyGraph . G.connect p Has $ M0.PID pid
        t <- _hv_process_start_timeout <$> getHalonVars
        switch [ start_process_complete, start_process_failure
               , timeout t start_process_timeout ]
      RequiresStop p -> do
        let msg :: String
            msg = printf "Process %s already running, stopping first." (showFid p)
        Log.rcLog' Log.DEBUG msg
        l <- startJob $! StopProcessRequest p
        modify Local $ rlens fldStopJob . rfield .~ Just l
        -- ruleProcessStop should always reply
        continue stop_finished

  -- After we have received the result of stop job, try to restart the
  -- job from the beginning. This way we re-run all the checks and
  -- even if we get in a cycle of failed stop jobs, we'll eventually
  -- terminate the job. We do this for every possible stop result:
  -- this job itself should decide what to do with the process.
  setPhaseIf stop_finished ourStopJob $ \case
    StopProcessResult (p, M0.PSOffline) -> do
      let msg :: String
          msg = printf "%s stopped successfully, retrying start." (showFid p)
      Log.rcLog' Log.DEBUG msg
      continue start_process_retry
    StopProcessResult (p, pst) -> do
      let msg :: String
          msg = printf "%s ended up in %s, trying to start again anyway."
                       (showFid p) (show pst)
      Log.rcLog' Log.WARN msg
      continue start_process_retry
    StopProcessTimeout p -> do
      let msg :: String
          msg = printf "%s didn't stop in timely manner, retrying start." (showFid p)
      Log.rcLog' Log.WARN msg
      continue start_process_retry

  -- Wait for the process to come online - sent out by `ruleProcessOnline`
  setPhaseNotified start_process_complete (processState (== M0.PSOnline)) $ \(p, _) -> do
    modify Local $ rlens fldRep . rfield .~ Just (ProcessStarted p)
    continue finish

  setPhaseNotified start_process_failure
            (processState (== M0.PSFailed "node failure")) $ \(p, _) -> do
    let ff = ProcessStartFailed p "Process start failed due to node failure."
    modify Local $ rlens fldRep . rfield .~ Just ff
    continue finish

  setPhaseNotified start_process_failure (processState psFailed) $ \_ -> do
    retryCount <- getField . rget fldRetryCount <$> get Local
    modify Local $ rlens fldRetryCount . rfield +~ 1
    restartMaxAttempts <- _hv_process_max_start_attempts <$> getHalonVars
    case retryCount < restartMaxAttempts of
      True -> do
        t <- _hv_process_restart_retry_interval <$> getHalonVars
        continue $ timeout t start_process_retry
      False -> do
        fail_start "Process failed while starting, exhausted retries." >>= switch

  directly start_process_timeout $
    fail_start "Timed out waiting for process to come online." >>= switch

  directly start_process_retry $ do
    req@(ProcessStartRequest p) <- getRequest
    retryCount <- getField . rget fldRetryCount <$> get Local
    restartMaxAttempts <- _hv_process_max_start_attempts <$> getHalonVars
    Log.rcLog' Log.DEBUG $ (printf "%s: Retrying start (%d/%d)"
                             (showFid p) retryCount restartMaxAttempts :: String)

    -- We can make the most out of the rule by starting again from the
    -- very top: we get all the checks for free and we verify all the
    -- resources are still there. This way we'll never try to retry a
    -- process start on a cluster which changed disposition to OFFLINE
    -- for example.
    route req >>=  \case
      Left m -> defaultReply ProcessStartFailed ("Failed process start retry: " ++ m) >>= \case
        (rep, phs) -> do
          modify Local $ rlens fldRep . rfield .~ Just rep
          switch phs
      Right (_, phs) -> switch phs

  return route
  where
    fldReq = Proxy :: Proxy '("request", Maybe ProcessStartRequest)
    fldRep = Proxy :: Proxy '("reply", Maybe ProcessStartResult)
    fldHost = Proxy :: Proxy '("host", Maybe Host)
    fldSender = Proxy :: Proxy '("sender", Maybe (MeroToSvc -> Process ()))
    fldRetryCount = Proxy :: Proxy '("retries", Int)
    fldProcessType = Proxy :: Proxy '("process-type", Maybe CI.ProcessType)
    fldConfigureUUID = Proxy :: Proxy '("configure-uuid", Maybe UUID.UUID)
    fldStopJob = Proxy :: Proxy '("stop-listener", Maybe ListenerId)

    args = fldReq           =: Nothing
       <+> fldRep           =: Nothing
       <+> fldHost          =: Nothing
       <+> fldSender        =: Nothing
       <+> fldProcessType   =: Nothing
       <+> fldConfigureUUID =: Nothing
       <+> fldStopJob       =: Nothing
       <+> fldRetryCount    =: 0
       <+> fldNotifications =: []
       <+> fldDispatch      =: Dispatch [] (error "ruleProcessStart dispatcher") Nothing

    configureResult (HAEvent uid (ProcessControlResultConfigureMsg reqUid result)) _ l = do
      let Just (ProcessStartRequest p) = getField $ rget fldReq l
          Just confUid = getField $ rget fldConfigureUUID l
          whenUUIDMatches v = Just $ if confUid == reqUid then v else WrongUUID uid
      return $! case result of
        Left (p', failMsg) | p == p' -> whenUUIDMatches $ ConfigureFailure uid failMsg
        Right p' | p == p' -> whenUUIDMatches $ ConfigureSuccess uid
        _ -> Nothing
    configureResult _ _ _ = return Nothing

    ourStopJob (JobFinished lis r) _ l = return $!
      case getField $ rget fldStopJob l of
        Just l' | l' `elem` lis -> Just r
        _ -> Nothing

    startCmdResult (HAEvent uid (ProcessControlResultMsg res)) _ l = return $!
      let Just (ProcessStartRequest p) = getField $ rget fldReq l
      in case res of
           r@(StartFailure p' _) | p == p' -> Just (uid, r)
           r@(Started p' _) | p == p' -> Just (uid, r)
           r@(RequiresStop p') | p == p' -> Just (uid, r)
           _ -> Nothing
    startCmdResult _ _ _ = return Nothing

    processState state l = case getField . rget fldReq $ l of
      Just (ProcessStartRequest p) -> Just (p, state)
      -- ‘impossible’ has happened!
      Nothing -> Nothing

    psFailed M0.PSFailed{} = True
    psFailed _             = False

    -- initResources should be runnable multiple times without
    -- ill-effects
    initResources p rg = do
     let mn = G.connectedFrom M0.IsParentOf p rg
         mh = mn >>= \n -> G.connectedFrom Runs n rg
         msender = do
           m0node <- mn
           iface <- getRunningMeroInterface m0node rg
           Node nid <- M0.m0nodeToNode m0node rg
           return $ liftProcess . sendSvc iface nid
         mProcType = G.connectedTo p Has rg
     case (,,) <$> mh <*> msender <*> mProcType of
       Nothing -> return . Just $
         printf "Could not init resources: Host: %s, Sender: %s, ProcessType: %s"
                (show mh) (show $ isJust msender) (show mProcType)
       Just (host, sender, procType) -> do
         modify Local $ rlens fldHost .~ Field (Just host)
         modify Local $ rlens fldSender .~ Field (Just sender)
         modify Local $ rlens fldProcessType .~ Field (Just procType)
         return Nothing

    checks :: [M0.Process -> G.Graph -> (Bool, String)]
    checks = [ checkBootlevel, checkIsNotHA, checkNodeOnline ]

    warnings :: [M0.Process -> G.Graph -> (Bool, String)]
    warnings = [ warnProcessAlreadyOnline ]

    runChecks :: M0.Process -> G.Graph -> Maybe String
    runChecks p rg = listToMaybe
      [ failMsg | c <- checks, let (r, failMsg) = c p rg, not r ]

    runWarnings :: M0.Process -> G.Graph -> [String]
    runWarnings p rg = [ warnMsg | w <- warnings, let (r, warnMsg) = w p rg, r ]

    checkBootlevel p rg = case (,) <$> Process.getType p rg <*> getClusterStatus rg of
      Nothing -> (False, "Can't retrieve process boot level or cluster status")
      Just (_, M0.MeroClusterState M0.OFFLINE _ _) ->
        (False, "Cluster disposition is offline")
      Just (CI.PLM0d pl, M0.MeroClusterState M0.ONLINE rl _) ->
        ( rl >= (M0.BootLevel pl)
        , printf "Can't start %s on cluster boot level %s" (showFid p) (show rl))
      Just (CI.PLM0t1fs, M0.MeroClusterState M0.ONLINE rl _) ->
        ( True -- Allow starting m0t1fs on any level.
        , printf "Can't start m0t1fs on cluster boot level %s" (show rl)
        )
      Just (CI.PLClovis _ _, M0.MeroClusterState M0.ONLINE rl _) ->
        ( rl >= m0t1fsBootLevel
        , printf "Can't start clovis on cluster boot level %s" (show rl)
        )
      Just (CI.PLHalon, _) ->
        (False, "Halon process should be started in halon:m0d.")

    checkIsNotHA p rg =
      let srvs = G.connectedTo p M0.IsParentOf rg
      in ( not $ any (\s -> M0.s_type s == CST_HA) srvs
         , "HA process is special, start halon:m0d instead")

    checkNodeOnline p rg = case G.connectedFrom M0.IsParentOf p rg of
      Nothing -> (False, "Can't find node hosting the process")
      Just (m0n :: M0.Node) -> ( getState m0n rg == M0.NSOnline
                               , "Node hosting the process is not online")

    warnProcessAlreadyOnline p rg = ( getState p rg == M0.PSOnline
                                    , "Process already online, restart will occur")

    toType CI.PLM0t1fs = M0T1FS
    toType (CI.PLClovis s _) = CLOVIS s
    toType _ = M0D

-- | Handle process Starting notifications.
ruleProcessStarting :: Definitions RC ()
ruleProcessStarting = define "castor::process::starting" $ do
  rule_init <- phaseHandle "rule_init"

  setPhaseIfConsume rule_init onlineProc $ \(eid, p, processPid) -> do
    Log.tagContext Log.SM p $ Just "Process sending M0_CONF_HA_PROCESS_STARTING"
    Log.tagContext Log.SM [("pid", show processPid)] Nothing

    rg <- getGraph
    case (getState p rg, G.connectedTo p Has rg) of

      -- We already know the process is starting.
      (M0.PSStarting, Just pid) | pid == processPid -> do
        Log.rcLog' Log.DEBUG "Process already STARTING with matching pid."

      -- We already know the process is starting, but have no PID. This
      -- message has arrived before `ProcessControlResultMsg`. This isn't a
      -- problem, but we would prefer to trust the PID from there.
      (M0.PSStarting, Nothing) -> do
        Log.rcLog' Log.DEBUG "Process already STARTING, but no PID info."

      -- Process is ephemeral. In this case, we allow a bunch of other
      -- transitions, because we may have not received all status updates.
      (st, _) | isEphemeral p rg -> do
        Log.rcLog' Log.DEBUG "Ephemeral process starting."
        Log.rcLog' Log.DEBUG ("oldState", show st)
        _ <- applyStateChanges [ stateSet p Tr.processStarting ]
        modifyGraph $ G.connect p Has processPid

      -- Process is not ephemeral, and we are not expecting this transition.
      -- Log a warning.
      (st, _) -> do
        Log.rcLog' Log.WARN "Unexpected STARTING notification for non-ephemeral process."
        Log.rcLog' Log.WARN ("oldState", show st)

    done eid

  start rule_init Nothing
  where
    isEphemeral p rg = case G.connectedTo p Has rg of
      Just (CI.PLClovis _ CI.Independent) -> True
      _ -> False
    onlineProc = select TAG_M0_CONF_HA_PROCESS_STARTING

select :: Monad m
       => ProcessEventType
       -> HAEvent (HAMsg ProcessEvent)
       -> LoopState
       -> l
       -> m (Maybe (UUID.UUID, M0.Process, M0.PID))
select pet (HAEvent eid (HAMsg (ProcessEvent et pt pid) m)) ls _ | pet == et =
  -- XXX TODO: Report error if
  -- (pt == TAG_M0_CONF_HA_PROCESS_KERNEL) /= (pid == 0)
  let mp = M0.lookupConfObjByFid (_hm_fid m) (lsGraph ls)
      rpid = M0.PID (fromIntegral pid)
  in return $ case (pt, mp) of
    (TAG_M0_CONF_HA_PROCESS_KERNEL, Just p) -> Just (eid, p, rpid)
    (TAG_M0_CONF_HA_PROCESS_M0MKFS, _)      -> Nothing
    (_, Just p) | pid /= 0                  -> Just (eid, p, rpid)
    _                                       -> Nothing
select _ _ _ _ = return Nothing

-- | Handle process started notifications.
ruleProcessOnline :: Definitions RC ()
ruleProcessOnline = define "castor::process::online" $ do
  rule_init <- phaseHandle "rule_init"

  setPhaseIfConsume rule_init startedProc $ \(eid, p, processPid) -> do
    rg <- getGraph
    case (getState p rg, G.connectedTo p Has rg) of
      -- Somehow we already have an online process and it has a PID:
      -- we don't care what the PID is as it either is the PID we
      -- already know about which suggest duplicate message or a new
      -- PID which suggests a duplicate message. Notably, unlike in
      -- the past, we should never receive a legitimate started
      -- notification for already started process as long as halon
      -- governs over process restart. Such a notification could
      -- happen if someone manually starts up a service but it's not a
      -- valid usecase.
      (M0.PSOnline, Just (M0.PID _)) -> do
        Log.rcLog' Log.DEBUG $
          "Process started notification for already online process with a PID. Do nothing."

      -- We have a process but no PID for it, somehow. This shouldn't
      -- normally happen as the only place that should set process to
      -- online is this rule and we receive the PID inside the
      -- message.
      (M0.PSOnline, Nothing) -> do
        Log.rcLog' Log.WARN "Received process online notification for already online process without PID."
        modifyGraph $ G.connect p Has processPid

      (M0.PSStarting, _) -> do
        Log.actLog "Process started." [ ("fid", show (M0.fid p))
                                      , ("pid", show processPid) ]
        modifyGraph $ G.connect p Has processPid
        let nodeNotif = if any (\s -> M0.s_type s == CST_HA) (G.connectedTo p M0.IsParentOf rg)
                        then case G.connectedFrom M0.IsParentOf p rg of
                               Nothing -> []
                               Just n -> [stateSet n Tr.nodeOnline]
                        else []
        void . applyStateChanges $ stateSet p Tr.processOnline : nodeNotif

      -- TODO: We need this case because when node rejoins, we do not
      -- set PSStarting on halon:m0d which is already in RG, it just
      -- springs back to life.
      (_, _)
        | any (\s -> M0.s_type s == CST_HA) (G.connectedTo p M0.IsParentOf rg) -> do
        Log.actLog "HA process started." [ ("fid", show (M0.fid p))
                                         , ("pid", show processPid) ]
        modifyGraph $ G.connect p Has processPid
        void $! case G.connectedFrom M0.IsParentOf p rg of
          Nothing -> do
            Log.rcLog' Log.WARN $ "No node associated with " ++ show (M0.fid p)
            applyStateChanges [ stateSet p Tr.processHAOnline ]
          Just n -> applyStateChanges [ stateSet p Tr.processHAOnline
                                      , stateSet n Tr.nodeOnline ]
      st -> Log.rcLog' Log.WARN $ "ruleProcessOnline: Unexpected state for"
            ++ " process " ++ show p ++ ", " ++ show st
    done eid

  start rule_init Nothing
  where
    startedProc = select TAG_M0_CONF_HA_PROCESS_STARTED

-- | Listen for process event notifications about a stopping process.
--   This is only of particular interest for ephemeral processes,
--   which may stop gracefully outside of Halon control.
ruleProcessStopping :: Definitions RC ()
ruleProcessStopping = define "castor::process::stopping" $ do
  rule_init <- phaseHandle "rule_init"

  setPhaseIfConsume rule_init stoppingProc $ \(eid, p, processPid) -> do
    Log.tagContext Log.SM p $ Just "Process sending M0_CONF_HA_PROCESS_STOPPING"
    Log.tagContext Log.SM [("pid", show processPid)] Nothing

    getGraph >>= \rg -> case getState p rg of
      M0.PSOnline -> do
        Log.rcLog' Log.DEBUG "Ephemeral process stopping."
        void $ applyStateChanges [ stateSet p Tr.processStopping ]
      (M0.PSInhibited M0.PSOnline) -> do
        Log.rcLog' Log.DEBUG "Ephemeral process stopping under inhibition."
        void $ applyStateChanges [ stateSet p Tr.processStopping ]
      st -> do
        Log.rcLog' Log.WARN "Ephemeral process unexpectedly reported stopping."
        Log.rcLog' Log.WARN ("oldState", show st)

    done eid

  startFork rule_init ()
  where
    isEphemeral p rg = case G.connectedTo p Has rg of
      Just (CI.PLClovis _ CI.Independent) -> True
      _ -> False

    stoppingProc (HAEvent eid (HAMsg (ProcessEvent et _ pid) meta)) ls _ = do
      let mp = M0.lookupConfObjByFid (_hm_fid meta) (lsGraph ls)
      return $ case (et, mp) of
        (TAG_M0_CONF_HA_PROCESS_STOPPING, Just (p :: M0.Process))
          | pid /= 0 && isEphemeral p (lsGraph ls)
            -> Just (eid, p, M0.PID $ fromIntegral pid)
        _   -> Nothing

-- | Listen for process event notifications about a stopped process
-- and decide whether we want to fail the process. If we do fail the
-- process, 'ruleProcessRestarted' deals with the internal state
-- change notification.
ruleProcessStopped :: Definitions RC ()
ruleProcessStopped = define "castor::process::process-stopped" $ do
  rule_init <- phaseHandle "rule_init"

  setPhaseIfConsume rule_init stoppedProc $ \(eid, p, _) -> do
    rg <- getGraph
    if alreadyFailed p rg
    then
      -- The process is already in what we consider a failed state:
      -- either we're already done dealing with it (it's offline or it
      -- failed).
      Log.rcLog' Log.WARN $ "Failed notification for already failed process: "
                          ++ show p
    else
      case getState p rg of
        M0.PSStarting ->
          -- SSPL restarted process or mero sent ONLINE (indicating a potential
          -- process restart). We shouldn't try to restart again.
          Log.rcLog' Log.WARN $ "Process in starting state, not restarting: "
                              ++ show p
        M0.PSStopping ->
          -- We are intending to stop this process. Either this or the
          -- notification from systemd should be sufficient to mark it
          -- as stopped.
          void $ applyStateChanges [stateSet p Tr.processOffline]
        M0.PSOffline ->
          -- Harmless case, we have probably just stopped the process
          -- through ruleProcessStop already.
          Log.rcLog' Log.DEBUG $ "PROCESS_STOPPED for already-offline process"
        _ -> void $ applyStateChanges [stateSet p $ Tr.processFailed "MERO-failed"]
    done eid

  startFork rule_init ()
  where
    alreadyFailed :: M0.Process -> G.Graph -> Bool
    alreadyFailed p rg = case getState p rg of
      M0.PSFailed _ -> True
      M0.PSOffline -> True
      _ -> False

    stoppedProc (HAEvent eid (HAMsg (ProcessEvent et _ pid) meta)) ls _ = do
      let rg = lsGraph ls
          mp = M0.lookupConfObjByFid (_hm_fid meta) rg
      return $ case (et, mp) of
        (TAG_M0_CONF_HA_PROCESS_STOPPED, Just (p :: M0.Process))
          | pid /= 0
          , Just (M0.PID pid') <- G.connectedTo p Has rg
          , pid' == fromIntegral pid
            -> Just (eid, p, M0.PID $ fromIntegral pid)
        _   -> Nothing

jobProcessStop :: Job StopProcessRequest StopProcessResult
jobProcessStop = Job "castor::process::stop"

-- | Stop a 'M0.Process' on the given node ('jobProcessStop').
ruleProcessStop :: Definitions RC ()
ruleProcessStop = mkJobRule jobProcessStop args $ \(JobHandle getRequest finish) -> do
  run_stopping <- phaseHandle "run_stopping"
  stop_process <- phaseHandle "stop_process"
  system_process_stopped <- phaseHandle "system_process_stopped"
  process_services_offline <- phaseHandle "process_services_offline"
  no_response <- phaseHandle "no_response"
  dispatch <- mkDispatcher
  notifier <- mkNotifier dispatch

  let quiesce (StopProcessRequest p) = do
        showContext
        rg <- getGraph
        when (getState p rg == M0.PSOffline) $ do
          Log.rcLog' Log.DEBUG "The Process is already Offline."
          continue finish
        Log.rcLog' Log.DEBUG "Setting processes to quiesce."
        waitFor notifier
        onTimeout 10 run_stopping
        onSuccess run_stopping
        notifications <- applyStateChanges [stateSet p Tr.processQuiescing]
        setExpectedNotifications $ map (==) notifications
        return $ Right (StopProcessTimeout p, [dispatch])

  directly run_stopping $ do
    StopProcessRequest p <- getRequest
    Log.rcLog' Log.DEBUG $ "Notifying about process stopping."
    waitClear
    waitFor notifier
    onSuccess stop_process
    onTimeout 10 stop_process
    notifications <- applyStateChanges [stateSet p Tr.processStopping]
    setExpectedNotifications $ map (==) notifications
    continue dispatch

  let notifyProcessFailed p failMsg = do
        setReply $ StopProcessResult (p, M0.PSFailed failMsg)
        waitClear
        waitFor notifier
        onSuccess finish
        onTimeout 10 finish
        notifications <- applyStateChanges [stateSet p $ Tr.processFailed failMsg]
        setExpectedNotifications $ map (==) notifications
        continue dispatch

  directly stop_process $ do
    StopProcessRequest p <- getRequest
    rg <- getGraph
    let msender = do
          m0n <- G.connectedFrom M0.IsParentOf p rg
          Node nid <- M0.m0nodeToNode m0n rg
          iface <- getRunningMeroInterface m0n rg
          return $ liftProcess . sendSvc iface nid
    case msender of
      Just sender -> do
        let runType = case G.connectedTo p Has rg of
              Just CI.PLM0t1fs -> M0T1FS
              Just (CI.PLClovis s CI.Managed) -> CLOVIS s
              _                -> M0D
        sender . ProcessMsg $! StopProcess runType p
        t <- getHalonVar _hv_process_stop_timeout
        switch [system_process_stopped, timeout t no_response]
      Nothing -> do
        showContext
        Log.rcLog' Log.ERROR "No process node found. Failing processes."
        let failMsg = "No process control channel found during stop."
        notifyProcessFailed p failMsg

  -- We have received the result of @systemctl stop@ command. Before
  -- failing the process itself, wait for any stopping services for
  -- that process to go to offline state: this should be caused by
  -- 'ruleNotificationHandler'.
  setPhaseIf system_process_stopped ourProcess $ \(eid, mFailure) -> do
    StopProcessRequest p <- getRequest
    messageProcessed eid
    case mFailure of
      Nothing -> do
        rg <- getGraph
        let svcs = [ s | s :: M0.Service <- G.connectedTo p M0.IsParentOf rg
                       , getState s rg == M0.SSStopping
                       ]
        let notifications = map (\s -> simpleNotificationToPred $ stateSet s Tr.serviceOffline) svcs
        waitClear
        waitFor notifier
        onSuccess process_services_offline
        onTimeout 60 no_response
        setExpectedNotifications notifications
        continue dispatch
      Just e -> do
        let failMsg = "Failed to stop: " ++ e
        notifyProcessFailed p failMsg

  -- All services have been stopped, set process to offline. We could
  -- wait for process STOPPED event (or ruleProcessStopped) but it's
  -- not necessary:
  --
  -- - Those messages contain PID of the process: we don't run a
  --   (real) risk of doing something bad there if we mark process
  --   offline early.
  --
  -- - ruleProcessStopped disallows any PID 0 messages which would
  --   force us to either allow those (and risk bad delayed messages)
  --   or run the following phase for client processes anyway.
  directly process_services_offline $ do
    StopProcessRequest p <- getRequest
    rg <- getGraph
    setReply $ StopProcessResult (p, M0.PSOffline)
    -- It may bee that the process STOPPED has already arrived in
    -- meantime and the process is offline. Finish straight away.
    if getState p rg == M0.PSOffline
    then continue finish
    else do
      waitClear
      waitFor notifier
      onSuccess finish
      onTimeout 20 no_response
      notifications <- applyStateChanges [stateSet p Tr.processOffline]
      setExpectedNotifications $ map (==) notifications
      continue dispatch

  directly no_response $ do
    StopProcessRequest p <- getRequest
    -- If we have no response, it possibly means the process is failed.
    -- However, it could be that we have had other notifications - e.g.
    -- from Mero itself, via @ruleProcessStopped@ - and we may have even
    -- restarted the process. So we should only mark those processes
    -- which are still @PSStopping@ as being failed.
    rg <- getGraph
    case getState p rg of
      M0.PSStopping -> do
        let failMsg = "Timeout while stopping."
        notifyProcessFailed p failMsg
      _ -> do
        setReply $ StopProcessTimeout p
        continue finish

  return quiesce
  where
    fldReq :: Proxy '("request", Maybe StopProcessRequest)
    fldReq = Proxy
    fldRep :: Proxy '("reply", Maybe StopProcessResult)
    fldRep = Proxy
    fldN = Proxy :: Proxy '("notifications", [AnyStateChange -> Bool])

    args = fldReq      =: Nothing
       <+> fldRep      =: Nothing
       <+> fldUUID     =: Nothing
       <+> fldN        =: []
       <+> fldDispatch =: Dispatch [] (error "ruleProcessStop dispatcher") Nothing

    setReply r = modify Local $ rlens fldRep . rfield .~ Just r

    showContext = do
      req <- gets Local (^. rlens fldReq . rfield)
      for_ req $ \(StopProcessRequest p) -> do
        Log.rcLog' Log.DEBUG $ (printf "Process: %s" (showFid p) :: String)

    ourProcess (HAEvent eid (ProcessControlResultStopMsg _ r)) _ l =
      return $ case (l ^. rlens fldReq . rfield) of
        Just (StopProcessRequest p) -> case r of
          Left (p', e) | p == p' -> Just (eid, Just e)
          Right p' | p == p' -> Just (eid, Nothing)
          _ -> Nothing
        _ -> Nothing
    ourProcess _ _ _ = return Nothing

-- | Handle user request for stopping a process.
requestUserStopsProcess :: Definitions RC ()
requestUserStopsProcess = defineSimpleTask "castor::process:stop_user_request" $
  \(StopProcessUserRequest pfid force replyChan) -> lookupConfObjByFid pfid >>= \case
    Nothing -> liftProcess $ sendChan replyChan NoSuchProcess
    Just p -> do
      if force
      then do
        l <- startJob $ StopProcessRequest p
        liftProcess . sendChan replyChan $ StopProcessInitiated l
      else do
        rg <- getGraph
        let (_, DeferredStateChanges f _ _) = createDeferredStateChanges
              [stateSet p $ TrI.constTransition M0.PSOffline] rg
        -- Do we want to check for SNS? For example if this is IOS
        -- process.
        ClusterLiveness pvs _ quorum rm <- calculateClusterLiveness (f rg)
        let errors = T.unlines $ concat
              [ if pvs then [] else [T.pack "No writeable PVers found."]
              , if quorum then [] else [T.pack "Quorum would be lost."]
              , if rm then [] else [T.pack "No principle RM chosen."]
              ]
        if T.null errors
        then do
          l <- startJob $ StopProcessRequest p
          liftProcess . sendChan replyChan $ StopProcessInitiated l
        else liftProcess . sendChan replyChan $ StopWouldBreakCluster errors

-- | Listens for 'NotifyFailureEndpoints' from notification mechanism.
-- Finds the non-failed processes which failed to be notified (through
-- endpoints of the services in question) and fails them. This allows
-- 'ruleProcessRestarted' to deal with them accordingly.
ruleFailedNotificationFailsProcess :: Definitions RC ()
ruleFailedNotificationFailsProcess =
  defineSimpleTask "notification-failed-fails-process" $ \(NotifyFailureEndpoints eps) -> do
    Log.rcLog' Log.DEBUG $ "Handling notification failure for: " ++ show eps
    rg <- getGraph
    -- Get procs which have servicess
    let procs = nub $
          [ p | p <- Process.getAll rg
              -- Don't consider already failed processes: if a process has
              -- failed and we try to notify about it below and that still
              -- fails, we'll just run ourselves in circles
              , not . isProcFailed $ getState p rg
              , s <- G.connectedTo p M0.IsParentOf rg
              , any (`elem` M0.s_endpoints s) eps ]

    -- We don't wait for confirmation of the notification, we're after
    -- a state change and internal notification. And this is already a
    -- handler for failed notifications so there isn't anything sane
    -- we could do here anyway.
    unless (null procs) $ do
      failProcs <- getHalonVar _hv_failed_notification_fails_process
      if failProcs
      then void . applyStateChanges $
        map (\p -> stateSet p $ Tr.processFailed "notification-failed") procs
      else do
        Log.rcLog' Log.WARN $ "Failing process due to notification failure is disabled."
        for_ procs $ \proc -> Log.tagContext Log.SM proc Nothing
  where
    isProcFailed (M0.PSFailed _) = True
    isProcFailed _ = False

-- | Listen for 'RpcEvent's. Currently just log the event.
ruleRpcEvent :: Definitions RC ()
ruleRpcEvent = defineSimpleTask "rpc-event" $ \(HAMsg (rpc :: RpcEvent) meta) -> do
  Log.rcLog' Log.DEBUG
    [ ("rpc-event" , show rpc)
    , ("meta", show meta)
    ]

-- * Utils

-- | Union for possible process configuration results
data ConfigureResult
  = WrongUUID UUID.UUID
  -- ^ The UUID of the reply was not the same as the UUID of request.
  -- Note that this is not the UUID that's presented here: this UUID
  -- is the 'HAEvent' UUID that needs to be processed
  -- ('messageProcessed').
  | ConfigureFailure UUID.UUID String
  -- ^ Process configuration has failed with the given reason. The
  -- UUID is the 'HAEvent' UUID.
  | ConfigureSuccess UUID.UUID
  -- ^ Process configuration succeeded. UUID is the 'HAEVent' UUID.
  deriving (Show, Eq, Ord, Typeable, Generic)
instance Binary ConfigureResult
