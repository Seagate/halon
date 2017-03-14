{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase       #-}
{-# LANGUAGE TypeFamilies     #-}
{-# LANGUAGE TypeOperators    #-}
{-# LANGUAGE ViewPatterns     #-}

-- |
-- Module    : HA.RecoveryCoordinator.Castor.Process.Rules
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Process handling.
module HA.RecoveryCoordinator.Castor.Process.Rules
  ( rules ) where

import           Control.Distributed.Process (Process)
import           Control.Lens
import           Control.Monad (unless)
import           Data.Binary (Binary)
import           Data.Foldable
import           Data.List (nub)
import           Data.Maybe (isJust, listToMaybe)
import           Data.Typeable
import qualified Data.UUID as UUID
import           Data.Vinyl
import           GHC.Generics (Generic)
import           HA.EventQueue
import           HA.RecoveryCoordinator.Actions.Mero
import qualified HA.RecoveryCoordinator.Castor.Process.Actions as Process
import           HA.RecoveryCoordinator.Castor.Process.Events
import           HA.RecoveryCoordinator.Castor.Process.Rules.Keepalive
import           HA.RecoveryCoordinator.Job.Actions
import           HA.RecoveryCoordinator.Mero.Events
import           HA.RecoveryCoordinator.Mero.Notifications
import           HA.RecoveryCoordinator.Mero.State
import qualified HA.RecoveryCoordinator.Mero.Transitions as Tr
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.ResourceGraph as G
import           HA.Resources (Has(..), Runs(..), Node(..))
import           HA.Resources.Castor (Host(..), Is(..))
import           HA.Resources.HalonVars
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note (getState, NotifyFailureEndpoints(..), showFid)
import           HA.Service.Interface
import           HA.Services.Mero.Types
import           Mero.ConfC (ServiceType(..))
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
    rg <- getLocalGraph
    let procs' = [ p | (p, _) <- procs
                     , let srvs = G.connectedTo p M0.IsParentOf rg
                     , not $ any (\s -> M0.s_type s == CST_HA) srvs ]

    for_ procs' $ promulgateRC . ProcessStartRequest
    done eid

  startFork rule_init ()
  where
    -- Don't restart after we leave inhibited, for example after node
    -- recovery: other mechanisms should recover the processes
    -- explicitly
    isProcFailed (M0.PSInhibited _) (M0.PSFailed _) = False
    -- Don't restart if we change reason for failure
    isProcFailed (M0.PSFailed _) (M0.PSFailed _) = False
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
  start_process_complete <- phaseHandle "start_process_complete"
  start_process_timeout <- phaseHandle "start_process_timeout"
  start_process_failure <- phaseHandle "start_process_failure"
  start_process_retry <- phaseHandle "start_process_retry"
  dispatch <- mkDispatcher
  notifier <- mkNotifierSimple dispatch

  let defaultReply c m = do
        phaseLog "warn" m
        ProcessStartRequest p <- getRequest
        applyStateChanges [ stateSet p $ Tr.processFailed m ]
        return (c p m, [finish])

  let fail_start m = snd <$> defaultReply ProcessStartFailed m

  let route (ProcessStartRequest p) = do
        rg <- getLocalGraph
        case runChecks p rg of
          Just chkFailMsg ->
            Right <$> defaultReply ProcessStartInvalid chkFailMsg
          Nothing -> initResources p rg >>= \case
            Just failMsg -> Right <$> defaultReply ProcessStartFailed failMsg
            Nothing -> do
              forM_ (runWarnings p rg) $ phaseLog "warn"

              waitClear
              waitFor notifier
              onTimeout 20 starting_notify_timed_out

              -- It may seem risky doing this check early but it
              -- should be OK: if it's not configured now, it's not
              -- going to suddenly become configured in few seconds
              -- when notification gets ack'd. This job is the only
              -- place that can configure and attach this flag (modulo
              -- cluster reset).
              onSuccess $ case G.isConnected p Is M0.ProcessBootstrapped rg of
                False -> configure
                True -> start_process

              let notifications = [stateSet p Tr.processStarting]
              setExpectedNotifications notifications
              applyStateChanges notifications
              return $ Right (ProcessStartFailed p "default", [dispatch])

  directly starting_notify_timed_out $ do
    ProcessStartRequest p <- getRequest
    phaseLog "warn" $ "Failed to notify PSStarting for " ++ showFid p
    fail_start "Notification about PSStarting failed" >>= switch

  directly configure $ do
    Just sender <- getField . rget fldSender <$> get Local
    Just (toType -> runType) <- getField . rget fldLabel <$> get Local
    ProcessStartRequest p <- getRequest
    phaseLog "info" $ "Configuring " ++ showFid p
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
      phaseLog "warn" "Received process configure result from different invocation."
      messageProcessed uid
      t <- getHalonVar _hv_process_configure_timeout
      switch [configure_result, timeout t configure_timeout]
    ConfigureFailure uid failMsg -> do
      messageProcessed uid
      finisher <- fail_start $ "Configuration failed: " ++ failMsg
      switch finisher
    ConfigureSuccess uid -> do
      Just (ProcessStartRequest p) <- getField . rget fldReq <$> get Local
      Just label <- getField . rget fldLabel <$> get Local
      modifyGraph $ G.connect p Is M0.ProcessBootstrapped
      messageProcessed uid
      phaseLog "info" $ "Configuration successful for " ++ showFid p
      case label of
        M0.PLClovis _ True -> do
          Log.rcLog' Log.DEBUG
                      "Independent CLOVIS process; only writing configuration."
          modify Local $ rlens fldRep . rfield .~ Just (ProcessConfiguredOnly p)
          -- Put the process in unknown state again.
          applyStateChanges [ stateSet p Tr.processUnknown ]
          continue finish
        _ -> continue start_process

  directly configure_timeout $ do
    finisher <- fail_start "Configuration timed out"
    switch finisher

  -- XXX: Be more defensive; check invariants: ProcessBootstrapped,
  -- PSStarting, disposition still in ONLINE
  directly start_process $ do
    Just sender <- getField . rget fldSender <$> get Local
    Just (toType -> runType) <- getField . rget fldLabel <$> get Local
    Just (ProcessStartRequest p) <- getField . rget fldReq <$> get Local
    phaseLog "info" $ printf "Starting %s (%s)" (showFid p) (show runType)
    liftProcess . sender . ProcessMsg $! StartProcess runType p
    t <- _hv_process_start_cmd_timeout <$> getHalonVars
    switch [start_process_cmd_result, timeout t start_process_timeout]

  setPhaseIf start_process_cmd_result startCmdResult $ \case
    Left (uid, failMsg) -> do
      finisher <- fail_start $ "Process start command failed: " ++ failMsg
      messageProcessed uid
      switch finisher
    Right (uid, mpid) -> do
      Just (ProcessStartRequest p) <- getField . rget fldReq <$> get Local
      phaseLog "info" $ "systemctl OK for " ++ showFid p
      phaseLog "PID" $ show mpid
      messageProcessed uid
      -- Don't set PID for m0t1fs responses (PID 0)
      unless (mpid == Just 0) $ do
        forM_ mpid $ modifyGraph . G.connect p Has . M0.PID
      t <- _hv_process_start_timeout <$> getHalonVars
      switch [ start_process_complete, start_process_failure
             , timeout t start_process_timeout ]

  -- Wait for the process to come online - sent out by `ruleProcessOnline`
  setPhaseNotified start_process_complete (processState (== M0.PSOnline)) $ \_ -> do
    Just (ProcessStartRequest p) <- getField . rget fldReq <$> get Local
    modify Local $ rlens fldRep . rfield .~ Just (ProcessStarted p)
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
        finisher <- fail_start "Process failed while starting, exhausted retries"
        switch finisher

  directly start_process_timeout $ do
    finisher <- fail_start "Timed out waiting for process to come online."
    switch finisher

  directly start_process_retry $ do
    Just req@(ProcessStartRequest p) <- getField . rget fldReq <$> get Local
    retryCount <- getField . rget fldRetryCount <$> get Local
    restartMaxAttempts <- _hv_process_max_start_attempts <$> getHalonVars
    phaseLog "info" $ printf "%s: Retrying start (%d/%d)"
                             (showFid p) retryCount restartMaxAttempts

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
    fldLabel = Proxy :: Proxy '("label", Maybe M0.ProcessLabel)
    fldConfigureUUID = Proxy :: Proxy '("configure-uuid", Maybe UUID.UUID)

    args = fldReq           =: Nothing
       <+> fldRep           =: Nothing
       <+> fldHost          =: Nothing
       <+> fldSender        =: Nothing
       <+> fldLabel         =: Nothing
       <+> fldConfigureUUID =: Nothing
       <+> fldRetryCount    =: 0
       <+> fldNotifications =: []
       <+> fldDispatch      =: Dispatch [] (error "ruleProcessStart dispatcher") Nothing

    configureResult (HAEvent uid (ProcessControlResultConfigureMsg _ reqUid result)) _ l = do
      let Just (ProcessStartRequest p) = getField $ rget fldReq l
          Just confUid = getField $ rget fldConfigureUUID l
          whenUUIDMatches v = Just $ if confUid == reqUid then v else WrongUUID uid
      return $! case result of
        Left (p', failMsg) | p == p' -> whenUUIDMatches $ ConfigureFailure uid failMsg
        Right p' | p == p' -> whenUUIDMatches $ ConfigureSuccess uid
        _ -> Nothing
    configureResult _ _ _ = return Nothing

    startCmdResult (HAEvent uid (ProcessControlResultMsg _ result)) _ l = do
      let Just (ProcessStartRequest p) = getField . rget fldReq $ l
      return $ case result of
        Left (p', failMsg) | p == p' -> Just $ Left (uid, failMsg)
        Right (p', mpid) | p == p' -> Just $ Right (uid, mpid)
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
         mlabel = G.connectedTo p Has rg
     case (,,) <$> mh <*> msender <*> mlabel of
       Nothing -> return . Just $
         printf "Could not init resources: Host: %s, Sender: %s, Label: %s"
                (show mh) (show $ isJust msender) (show mlabel)
       Just (host, sender, label) -> do
         modify Local $ rlens fldHost .~ Field (Just host)
         modify Local $ rlens fldSender .~ Field (Just sender)
         modify Local $ rlens fldLabel .~ Field (Just label)
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

    checkBootlevel p rg = case (,) <$> Process.getLabel p rg <*> getClusterStatus rg of
      Nothing -> (False, "Can't retrieve process boot level or cluster status")
      Just (_, M0.MeroClusterState M0.OFFLINE _ _) ->
        (False, "Cluster disposition is offline")
      Just (M0.PLM0d pl, M0.MeroClusterState M0.ONLINE rl _) ->
        ( rl >= pl
        , printf "Can't start %s on cluster boot level %s" (showFid p) (show rl))
      Just (M0.PLM0t1fs, M0.MeroClusterState M0.ONLINE rl _) ->
        ( True -- Allow starting m0t1fs on any level.
        , printf "Can't start m0t1fs on cluster boot level %s" (show rl)
        )
      Just (M0.PLClovis _ _, M0.MeroClusterState M0.ONLINE rl _) ->
        ( rl >= m0t1fsBootLevel
        , printf "Can't start clovis on cluster boot level %s" (show rl)
        )
      Just (M0.PLHalon, _) ->
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

    toType M0.PLM0t1fs = M0T1FS
    toType (M0.PLClovis s _) = CLOVIS s
    toType _ = M0D

-- | Handle process Starting notifications.
ruleProcessStarting :: Definitions RC ()
ruleProcessStarting = define "castor::process::starting" $ do
  rule_init <- phaseHandle "rule_init"

  setPhaseIfConsume rule_init onlineProc $ \(eid, p, processPid) -> do
    Log.tagContext Log.SM p $ Just "Process sending M0_CONF_HA_PROCESS_STARTING"
    Log.tagContext Log.SM [("pid", show processPid)] Nothing

    rg <- getLocalGraph
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
        applyStateChanges [ stateSet p Tr.processStarting ]
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
      Just (M0.PLClovis _ True) -> True
      _ -> False
    onlineProc (HAEvent eid (HAMsg (ProcessEvent t pt pid) m)) ls _ = do
      let mpd = M0.lookupConfObjByFid (_hm_fid m) (lsGraph ls)
      return $ case (t, pt, mpd) of
        (TAG_M0_CONF_HA_PROCESS_STARTING, TAG_M0_CONF_HA_PROCESS_M0D, Just (p :: M0.Process)) | pid /= 0 ->
          Just (eid, p, M0.PID $ fromIntegral pid)
        (TAG_M0_CONF_HA_PROCESS_STARTING, TAG_M0_CONF_HA_PROCESS_KERNEL, Just (p :: M0.Process)) ->
          Just (eid, p, M0.PID $ fromIntegral pid)
        _ -> Nothing

-- | Handle process started notifications.
ruleProcessOnline :: Definitions RC ()
ruleProcessOnline = define "castor::process::online" $ do
  rule_init <- phaseHandle "rule_init"

  setPhaseIfConsume rule_init startedProc $ \(eid, p, processPid) -> do
    rg <- getLocalGraph
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
        phaseLog "debug" $
          "Process started notification for already online process with a PID. Do nothing."

      -- We have a process but no PID for it, somehow. This shouldn't
      -- normally happen as the only place that should set process to
      -- online is this rule and we receive the PID inside the
      -- message.
      (M0.PSOnline, Nothing) -> do
        phaseLog "warn" "Received process online notification for already online process without PID."
        modifyGraph $ G.connect p Has processPid

      (M0.PSStarting, _) -> do
        phaseLog "action" "Process started."
        phaseLog "info" $ "process.fid     = " ++ show (M0.fid p)
        phaseLog "info" $ "process.pid     = " ++ show processPid
        modifyGraph $ G.connect p Has processPid
        let nodeNotif = if any (\s -> M0.s_type s == CST_HA) (G.connectedTo p M0.IsParentOf rg)
                        then case G.connectedFrom M0.IsParentOf p rg of
                               Nothing -> []
                               Just n -> [stateSet n Tr.nodeOnline]
                        else []
        applyStateChanges $ stateSet p Tr.processOnline : nodeNotif

      -- TODO: Now that we set PSStarting for HA, we may not need this case.
      -- Think about it.
      (_, _)
        | any (\s -> M0.s_type s == CST_HA) (G.connectedTo p M0.IsParentOf rg) -> do
        phaseLog "action" "HA Process started."
        phaseLog "info" $ "process.fid     = " ++ show (M0.fid p)
        phaseLog "info" $ "process.pid     = " ++ show processPid
        modifyGraph $ G.connect p Has processPid
        case G.connectedFrom M0.IsParentOf p rg of
          Nothing -> do
            phaseLog "warn" $ "No node associated with " ++ show (M0.fid p)
            applyStateChanges [ stateSet p Tr.processHAOnline ]
          Just n -> applyStateChanges [ stateSet p Tr.processHAOnline
                                      , stateSet n Tr.nodeOnline ]
      st -> phaseLog "warn" $ "ruleProcessOnline: Unexpected state for"
            ++ " process " ++ show p ++ ", " ++ show st
    done eid

  start rule_init Nothing
  where
    startedProc (HAEvent eid (HAMsg (ProcessEvent t pt pid) m)) ls _ = do
      let mpd = M0.lookupConfObjByFid (_hm_fid m) (lsGraph ls)
      return $ case (t, pt, mpd) of
        (TAG_M0_CONF_HA_PROCESS_STARTED, TAG_M0_CONF_HA_PROCESS_M0D, Just (p :: M0.Process)) | pid /= 0 ->
          Just (eid, p, M0.PID $ fromIntegral pid)
        (TAG_M0_CONF_HA_PROCESS_STARTED, TAG_M0_CONF_HA_PROCESS_KERNEL, Just (p :: M0.Process)) ->
          Just (eid, p, M0.PID $ fromIntegral pid)
        _ -> Nothing

-- | Listen for process event notifications about a stopping process.
--   This is only of particular interest for ephemeral processes,
--   which may stop gracefully outside of Halon control.
ruleProcessStopping :: Definitions RC ()
ruleProcessStopping = define "castor::process::stopping" $ do
  rule_init <- phaseHandle "rule_init"

  setPhaseIfConsume rule_init stoppingProc $ \(eid, p, processPid) -> do
    Log.tagContext Log.SM p $ Just "Process sending M0_CONF_HA_PROCESS_STOPPING"
    Log.tagContext Log.SM [("pid", show processPid)] Nothing

    getLocalGraph >>= \rg -> case getState p rg of
      M0.PSOnline -> do
        Log.rcLog' Log.DEBUG "Ephemeral process stopping."
        applyStateChanges [ stateSet p Tr.processStopping ]
      (M0.PSInhibited M0.PSOnline) -> do
        Log.rcLog' Log.DEBUG "Ephemeral process stopping under inhibition."
        applyStateChanges [ stateSet p Tr.processStopping ]
      st -> do
        Log.rcLog' Log.WARN "Ephemeral process unexpectedly reported stopping."
        Log.rcLog' Log.WARN ("oldState", show st)

    done eid

  startFork rule_init ()
  where
    isEphemeral p rg = case G.connectedTo p Has rg of
      Just (M0.PLClovis _ True) -> True
      _ -> False
    stoppingProc (HAEvent eid (HAMsg (ProcessEvent t pt pid) meta)) ls _ = do
      let mpd = M0.lookupConfObjByFid (_hm_fid meta) (lsGraph ls)
      return $ case (t, pt, mpd) of
        (TAG_M0_CONF_HA_PROCESS_STOPPING, TAG_M0_CONF_HA_PROCESS_M0D, Just (p :: M0.Process))
          | pid /= 0 && isEphemeral p (lsGraph ls) ->
            Just (eid, p, M0.PID $ fromIntegral pid)
        _ -> Nothing

-- | Listen for process event notifications about a stopped process
-- and decide whether we want to fail the process. If we do fail the
-- process, 'ruleProcessRestarted' deals with the internal state
-- change notification.
ruleProcessStopped :: Definitions RC ()
ruleProcessStopped = define "castor::process::process-stopped" $ do
  rule_init <- phaseHandle "rule_init"

  setPhaseIfConsume rule_init stoppedProc $ \(eid, p, _) -> do
    getLocalGraph >>= \rg -> case alreadyFailed p rg of
      -- The process is already in what we consider a failed state:
      -- either we're already done dealing with it (it's offline or it
      -- failed).
      True -> phaseLog "warn" $
                "Failed notification for already failed process: " ++ show p

      -- Make sure we're not in PSStarting state: this means that SSPL
      -- restarted process or mero sent ONLINE (indicating a potential
      -- process restart) which means we shouldn't try to restart again
      False -> case getState p rg of
        M0.PSStarting ->
          phaseLog "warn" $ "Proceess in starting state, not restarting: "
                          ++ show p
        M0.PSStopping ->
          -- We are intending to stop this process. Either this or the
          -- notification from systemd should be sufficient to mark it
          -- as stopped.
          applyStateChanges [stateSet p Tr.processOffline]
        _ -> applyStateChanges [stateSet p $ Tr.processFailed "MERO-failed"]
    done eid

  startFork rule_init ()
  where
    alreadyFailed :: M0.Process -> G.Graph -> Bool
    alreadyFailed p rg = case getState p rg of
      M0.PSFailed _ -> True
      M0.PSOffline -> True
      _ -> False

    stoppedProc (HAEvent eid (HAMsg (ProcessEvent t pt pid) meta)) ls _ = do
      let mpd = M0.lookupConfObjByFid (_hm_fid meta) (lsGraph ls)
      case mpd of
        Just pd -> do
          let mpid = G.connectedTo pd Has (lsGraph ls)
          return $ case (t, pt, pd) of
            (TAG_M0_CONF_HA_PROCESS_STOPPED, TAG_M0_CONF_HA_PROCESS_M0D, p :: M0.Process)
               | pid /= 0
               , Just (M0.PID ppid) <- mpid
               , ppid == fromIntegral pid -> Just (eid, p, M0.PID $ fromIntegral pid)
            _ -> Nothing
        Nothing -> return Nothing

jobProcessStop :: Job StopProcessRequest StopProcessResult
jobProcessStop = Job "castor::process::stop"

-- | Stop a 'M0.Process' on the given node ('jobProcessStop').
ruleProcessStop :: Definitions RC ()
ruleProcessStop = mkJobRule jobProcessStop args $ \(JobHandle getRequest finish) -> do
  run_stopping <- phaseHandle "run_stopping"
  stop_process <- phaseHandle "stop_process"
  services_stopped <- phaseHandle "services_stopped"
  no_response <- phaseHandle "no_response"
  dispatch <- mkDispatcher
  notifier <- mkNotifierSimple dispatch

  let quiesce (StopProcessRequest p) = do
        showContext
        phaseLog "info" $ "Setting processes to quiesce."
        let notification = stateSet p Tr.processQuiescing
        waitFor notifier
        onTimeout 10 run_stopping
        onSuccess run_stopping
        setExpectedNotifications [notification]
        applyStateChanges [notification]
        return $ Right (StopProcessTimeout p, [dispatch])

  directly run_stopping $ do
    StopProcessRequest p <- getRequest
    phaseLog "info" $ "Notifying about process stopping."
    let notifications = [stateSet p Tr.processStopping]

    waitClear
    waitFor notifier
    onSuccess stop_process
    onTimeout 10 stop_process
    setExpectedNotifications notifications
    applyStateChanges notifications
    continue dispatch

  let notifyProcessFailed p failMsg = do
        let notifications = [stateSet p $ Tr.processFailed failMsg]
        setReply $ StopProcessResult (p, M0.PSFailed failMsg)
        waitClear
        waitFor notifier
        onSuccess finish
        onTimeout 10 finish
        setExpectedNotifications notifications
        applyStateChanges notifications
        continue dispatch

  directly stop_process $ do
    StopProcessRequest p <- getRequest
    rg <- getLocalGraph
    let msender = do
          m0n <- G.connectedFrom M0.IsParentOf p rg
          Node nid <- M0.m0nodeToNode m0n rg
          iface <- getRunningMeroInterface m0n rg
          return $ liftProcess . sendSvc iface nid
    case msender of
      Just sender -> do
        let runType = case G.connectedTo p Has rg of
              Just M0.PLM0t1fs -> M0T1FS
              Just (M0.PLClovis s False) -> CLOVIS s
              _                -> M0D
        sender . ProcessMsg $! StopProcess runType p
        t <- getHalonVar _hv_process_stop_timeout
        switch [services_stopped, timeout t no_response]
      Nothing -> do
        showContext
        phaseLog "error" "No process node found. Failing processes."
        let failMsg = "No process control channel found during stop."
        notifyProcessFailed p failMsg

  setPhaseIf services_stopped ourProcess $ \(eid, mFailure) -> do
    StopProcessRequest p <- getRequest
    messageProcessed eid
    case mFailure of
      Nothing -> do
        let notifications = [stateSet p Tr.processOffline]
        setReply $ StopProcessResult (p, M0.PSOffline)
        waitClear
        waitFor notifier
        onSuccess finish
        onTimeout 10 finish
        setExpectedNotifications notifications
        applyStateChanges notifications
        continue dispatch
      Just e -> do
        let failMsg = "Failed to stop: " ++ e
        notifyProcessFailed p failMsg

  directly no_response $ do
    StopProcessRequest p <- getRequest
    -- If we have no response, it possibly means the process is failed.
    -- However, it could be that we have had other notifications - e.g.
    -- from Mero itself, via @ruleProcessStopped@ - and we may have even
    -- restarted the process. So we should only mark those processes
    -- which are still @PSStopping@ as being failed.
    rg <- getLocalGraph
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

    args = fldReq           =: Nothing
       <+> fldRep           =: Nothing
       <+> fldUUID          =: Nothing
       <+> fldNotifications =: []
       <+> fldDispatch      =: Dispatch [] (error "ruleProcessStop dispatcher") Nothing

    setReply r = modify Local $ rlens fldRep . rfield .~ Just r

    showContext = do
      req <- gets Local (^. rlens fldReq . rfield)
      for_ req $ \(StopProcessRequest p) ->
        phaseLog "request-context" $
          printf "Process: %s" (showFid p)

    ourProcess (HAEvent eid (ProcessControlResultStopMsg _ r)) _ l =
      return $ case (l ^. rlens fldReq . rfield) of
        Just (StopProcessRequest p) -> case r of
          Left (p', e) | p == p' -> Just (eid, Just e)
          Right p' | p == p' -> Just (eid, Nothing)
          _ -> Nothing
        _ -> Nothing
    ourProcess _ _ _ = return Nothing

-- | Listens for 'NotifyFailureEndpoints' from notification mechanism.
-- Finds the non-failed processes which failed to be notified (through
-- endpoints of the services in question) and fails them. This allows
-- 'ruleProcessRestarted' to deal with them accordingly.
ruleFailedNotificationFailsProcess :: Definitions RC ()
ruleFailedNotificationFailsProcess =
  defineSimpleTask "notification-failed-fails-process" $ \(NotifyFailureEndpoints eps) -> do
    phaseLog "info" $ "Handling notification failure for: " ++ show eps
    rg <- getLocalGraph
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
      applyStateChanges $ map (\p -> stateSet p $ Tr.processFailed "notification-failed") procs
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
