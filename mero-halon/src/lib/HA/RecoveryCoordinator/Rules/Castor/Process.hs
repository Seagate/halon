{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase       #-}
{-# LANGUAGE TypeFamilies     #-}
{-# LANGUAGE TypeOperators    #-}

-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Process handling.
module HA.RecoveryCoordinator.Rules.Castor.Process
  ( rules ) where

import           HA.EventQueue.Types
import           HA.RecoveryCoordinator.Actions.Core
import           HA.RecoveryCoordinator.Job.Actions
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Events.Castor.Process
import           HA.RecoveryCoordinator.Events.Castor.Cluster
import           HA.RecoveryCoordinator.Events.Mero
import           HA.RecoveryCoordinator.Rules.Castor.Process.Keepalive
import           HA.RecoveryCoordinator.Rules.Mero.Conf
import qualified HA.ResourceGraph as G
import           HA.Resources (Has(..), Runs(..))
import           HA.Resources.Castor (Host(..), Is(..))
import           HA.Resources.HalonVars
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note (getState, NotifyFailureEndpoints(..), showFid)
import           HA.Services.Mero.RC.Actions (meroChannel)
import           HA.Services.Mero.Types
import           Mero.Notification.HAState
import           Mero.ConfC (ServiceType(..))
import           Network.CEP

import           Control.Exception (SomeException)
import           Control.Distributed.Process (sendChan)
import           Control.Lens
import           Control.Monad (unless)
import           Control.Monad.Catch (try)
import           Data.Foldable
import           Data.List (nub, sort)
import           Data.Maybe (isJust, listToMaybe, mapMaybe)
import           Data.Typeable
import           Data.Vinyl
import           Text.Printf

rules :: Definitions RC ()
rules = sequence_ [
    ruleProcessOnline
  , ruleProcessStopped
  , ruleProcessDispatchRestart
  , ruleProcessStart
  , ruleStop
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

  setPhaseInternalNotificationWithState rule_init isProcFailed $ \(eid, procs) -> do
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
ruleProcessStart = mkJobRule jobProcessStart args $ \finish -> do
  configure <- phaseHandle "configure"
  configure_result <- phaseHandle "configure_result"
  configure_timeout <- phaseHandle "configure_timeout"
  start_process <- phaseHandle "start_process"
  start_process_cmd_result <- phaseHandle "start_process_result"
  start_process_complete <- phaseHandle "start_process_complete"
  start_process_timeout <- phaseHandle "start_process_timeout"
  start_process_failure <- phaseHandle "start_process_failure"
  start_process_retry <- phaseHandle "start_process_retry"

  let fail_start m = do
        phaseLog "warn" m
        Just (ProcessStartRequest p) <- getField . rget fldReq <$> get Local
        modify Local $ rlens fldRep . rfield .~ Just (ProcessStartFailed p m)
        applyStateChanges [ stateSet p $ M0.PSFailed m ]
        return [finish]

  run_notification <- mkPhaseNotify 20
    (\l -> case getField $ l ^. rlens fldReq of
             Just (ProcessStartRequest p) -> Just (p, M0.PSStarting)
             Nothing -> Nothing)
    (do phaseLog "warn" "Failed to notify."
        finisher <- fail_start "Notification about PSStarting failed"
        switch finisher)
    (\p _ -> G.isConnected p Is M0.ProcessBootstrapped <$> getLocalGraph >>= \case
        True -> return [start_process]
        False -> return [configure])

  let route (ProcessStartRequest p) = do
        rg <- getLocalGraph
        case runChecks p rg of
          Just failMsg -> Just <$> fail_start failMsg
          Nothing -> initResources p rg >>= \case
            Just failMsg -> Just <$> fail_start failMsg
            Nothing -> do
              forM_ (runWarnings p rg) $ phaseLog "warn"
              notification_phases <- run_notification p M0.PSStarting
              return $ Just notification_phases

  directly configure $ do
    Just chan <- getField . rget fldChan <$> get Local
    Just runType <- getField . rget fldRunType <$> get Local
    Just (ProcessStartRequest p) <- getField . rget fldReq <$> get Local
    phaseLog "info" $ "Configuring " ++ showFid p
    try (configureMeroProcess chan p runType (runType /= M0T1FS)) >>= \case
      Left (e :: SomeException) -> do
        finisher <- fail_start $ "Configuration failed with exception: " ++ show e
        switch finisher
      Right _ -> return ()
    t <- _hv_process_configure_timeout <$> getHalonVars
    switch [configure_result, timeout t configure_timeout]

  setPhaseIf configure_result configureResult $ \case
    Left (uid, failMsg) -> do
      messageProcessed uid
      finisher <- fail_start $ "Configuration failed: " ++ failMsg
      switch finisher
    Right uid -> do
      Just (ProcessStartRequest p) <- getField . rget fldReq <$> get Local
      modifyGraph $ G.connect p Is M0.ProcessBootstrapped
      messageProcessed uid
      phaseLog "info" $ "Configuration successful for " ++ showFid p
      continue start_process

  directly configure_timeout $ do
    finisher <- fail_start "Configuration timed out"
    switch finisher

  -- XXX: Be more defensive; check invariants: ProcessBootstrapped,
  -- PSStarting, disposition still in ONLINE
  directly start_process $ do
    Just (TypedChannel chan) <- getField . rget fldChan <$> get Local
    Just runType <- getField . rget fldRunType <$> get Local
    Just (ProcessStartRequest p) <- getField . rget fldReq <$> get Local
    phaseLog "info" $ printf "Starting %s (%s)" (showFid p) (show runType)
    liftProcess . sendChan chan $ StartProcess runType p
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
             , timeout t start_process_complete]

  -- Wait for the process to come online - sent out by `ruleProcessOnline`
  setPhaseNotified start_process_complete (processState (== M0.PSOnline)) $ \_ -> do
    Just (ProcessStartRequest p) <- getField . rget fldReq <$> get Local
    modify Local $ rlens fldRep . rfield .~ Just (ProcessStarted p)
    continue finish

  directly start_process_timeout $ do
    finisher <- fail_start "Timed out waiting for process to come online."
    switch finisher

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

  directly start_process_retry $ do
    Just (ProcessStartRequest p) <- getField . rget fldReq <$> get Local
    retryCount <- getField . rget fldRetryCount <$> get Local
    restartMaxAttempts <- _hv_process_max_start_attempts <$> getHalonVars
    phaseLog "info" $ printf "%s: Retrying restart (%d/%d)"
                             (showFid p) retryCount restartMaxAttempts
    notification_phases <- run_notification p M0.PSStarting
    switch notification_phases

  return route
  where
    fldReq = Proxy :: Proxy '("request", Maybe ProcessStartRequest)
    fldRep = Proxy :: Proxy '("reply", Maybe ProcessStartResult)
    fldHost = Proxy :: Proxy '("host", Maybe Host)
    fldChan = Proxy :: Proxy '("chan", Maybe (TypedChannel ProcessControlMsg))
    fldRunType = Proxy :: Proxy '("label", Maybe ProcessRunType)
    fldRetryCount = Proxy :: Proxy '("retries", Int)

    args = fldReq        =: Nothing
       <+> fldRep        =: Nothing
       <+> fldHost       =: Nothing
       <+> fldChan       =: Nothing
       <+> fldRunType    =: Nothing
       <+> fldRetryCount =: 0

    configureResult (HAEvent uid (ProcessControlResultConfigureMsg _ result) _) _ l = do
      let Just (ProcessStartRequest p) = getField . rget fldReq $ l
      case result of
        Left (p', failMsg) | p == p' -> return . Just $ Left (uid, failMsg)
        Right p' | p == p' -> return . Just $ Right uid
        _ -> return Nothing

    startCmdResult (HAEvent uid (ProcessControlResultMsg _ result) _) _ l = do
      let Just (ProcessStartRequest p) = getField . rget fldReq $ l
      return $ case result of
        Left (p', failMsg) | p == p' -> Just $ Left (uid, failMsg)
        Right (p', mpid) | p == p' -> Just $ Right (uid, mpid)
        _ -> Nothing

    processState state l = case getField . rget fldReq $ l of
      Just (ProcessStartRequest p) -> Just (p, state)
      -- ‘impossible’ has happened!
      Nothing -> Nothing

    psFailed M0.PSFailed{} = True
    psFailed _             = False

    initResources p rg = do
     let mn = G.connectedFrom M0.IsParentOf p rg
         mh = mn >>= \n -> G.connectedFrom Runs n rg
         mchan = mn >>= \n -> M0.m0nodeToNode n rg >>= meroChannel rg
         mlabel = listToMaybe $ G.connectedTo p Has rg
     case (,,) <$> mh <*> mchan <*> mlabel of
       Nothing -> return . Just $
         printf "Could not init resources: Host: %s, Chan: %s, Label: %s"
                (show mh) (show $ isJust mchan) (show mlabel)
       Just (host, chan, label) -> do
         let toType M0.PLM0t1fs = M0T1FS
             toType _           = M0D
         modify Local $ rlens fldHost .~ Field (Just host)
         modify Local $ rlens fldChan .~ Field (Just chan)
         modify Local $ rlens fldRunType .~ Field (Just $ toType label)
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

    checkBootlevel p rg = case (,) <$> getProcessBootLevel p rg <*> getClusterStatus rg of
      Nothing -> (False, "Can't retrieve process boot level or cluster status")
      Just (_, M0.MeroClusterState M0.OFFLINE _ _) ->
        (False, "Cluster disposition is offline")
      Just (pl, M0.MeroClusterState M0.ONLINE rl _) ->
        (rl >= pl, printf "Can't start %s on cluster boot level %s" (showFid p) (show rl))

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

-- | Handle process started notifications.
ruleProcessOnline :: Definitions RC ()
ruleProcessOnline = define "castor::process::online" $ do
  rule_init <- phaseHandle "rule_init"

  setPhaseIfConsume rule_init onlineProc $ \(eid, p, processPid) -> do
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

      -- TODO: We can use TAG_M0_CONF_HA_PROCESS_STARTING notification
      -- now if we desire.
      (M0.PSStarting, _) -> do
        phaseLog "action" "Process started."
        phaseLog "info" $ "process.fid     = " ++ show (M0.fid p)
        phaseLog "info" $ "process.pid     = " ++ show processPid
        modifyGraph $ G.connect p Has processPid
        applyStateChanges [ stateSet p M0.PSOnline ]
      (_, _)
        | any (\s -> M0.s_type s == CST_HA) (G.connectedTo p M0.IsParentOf rg) -> do
        phaseLog "action" "HA Process started."
        phaseLog "info" $ "process.fid     = " ++ show (M0.fid p)
        phaseLog "info" $ "process.pid     = " ++ show processPid
        modifyGraph $ G.connect p Has processPid
        applyStateChanges [ stateSet p M0.PSOnline ]
      st -> phaseLog "warn" $ "ruleProcessOnline: Unexpected state for"
            ++ " process " ++ show p ++ ", " ++ show st
    done eid

  start rule_init Nothing
  where
    onlineProc (HAEvent eid (HAMsg (ProcessEvent t pt pid) m) _) ls _ = do
      let mpd = M0.lookupConfObjByFid (_hm_fid m) (lsGraph ls)
      return $ case (t, pt, mpd) of
        (TAG_M0_CONF_HA_PROCESS_STARTED, TAG_M0_CONF_HA_PROCESS_M0D, Just (p :: M0.Process)) | pid /= 0 ->
          Just (eid, p, M0.PID $ fromIntegral pid)
        (TAG_M0_CONF_HA_PROCESS_STARTED, TAG_M0_CONF_HA_PROCESS_KERNEL, Just (p :: M0.Process)) ->
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
          applyStateChanges [stateSet p $ M0.PSOffline]
        _ -> applyStateChanges [stateSet p $ M0.PSFailed "MERO-failed"]
    done eid

  startFork rule_init ()
  where
    alreadyFailed :: M0.Process -> G.Graph -> Bool
    alreadyFailed p rg = case getState p rg of
      M0.PSFailed _ -> True
      M0.PSOffline -> True
      _ -> False

    stoppedProc (HAEvent eid (HAMsg (ProcessEvent t pt pid) meta) _) ls _ = do
      let mpd = M0.lookupConfObjByFid (_hm_fid meta) (lsGraph ls)
      return $ case (t, pt, mpd) of
        (TAG_M0_CONF_HA_PROCESS_STOPPED, TAG_M0_CONF_HA_PROCESS_M0D, Just (p :: M0.Process)) | pid /= 0 ->
          Just (eid, p, M0.PID $ fromIntegral pid)
        _ -> Nothing

jobStop :: Job StopProcessesRequest StopProcessesResult
jobStop = Job "castor::process::stop"

ruleStop :: Definitions RC ()
ruleStop = mkJobRule jobStop args $ \finish -> do
  quiesce <- phaseHandle "quiesce"
  quiesce_ack <- phaseHandle "quiesce_ack"
  quiesce_timeout <- phaseHandle "quiesce_timeout"
  stop_service <- phaseHandle "stop_service"
  services_stopped <- phaseHandle "services_stopped"
  no_response <- phaseHandle "no_response"

  directly quiesce $ do
    (Just (StopProcessesRequest _ p))
      <- gets Local (^. rlens fldReq . rfield)
    showContext
    phaseLog "info" $ "Setting processes to quiesce."
    let notifications = (flip stateSet M0.PSQuiescing) <$> p
    modify Local $ rlens fldNotifications . rfield .~ (Just notifications)
    applyStateChanges notifications
    switch [quiesce_ack, timeout notificationTimeout quiesce_timeout]

  setPhaseAllNotified quiesce_ack (rlens fldNotifications . rfield) $ do
    showContext
    phaseLog "info" "All processes marked as quiesced."
    continue (timeout 30 stop_service)

  directly quiesce_timeout $ do
    showContext
    phaseLog "warning" "Acknowledgement of quiesce not received."
    continue (timeout 30 stop_service)

  directly stop_service $ do
    (Just (StopProcessesRequest m0node p))
      <- gets Local (^. rlens fldReq . rfield)
    rg <- getLocalGraph
    let nodes = m0nodeToNode m0node rg
        mchan = listToMaybe $ mapMaybe (meroChannel rg) nodes
    case mchan of
      Just ch -> do
        stopNodeProcesses ch p
        switch [services_stopped, timeout stopTimeout no_response]
      Nothing -> do
        showContext
        phaseLog "error" "No process control channel found. Failing processes."
        let failState = M0.PSFailed "No process control channel found during stop."
        applyStateChanges $ (flip stateSet failState) <$> p
        modify Local $ rlens fldRep . rfield .~
          (Just $ StopProcessesResult m0node ((,failState) <$> p))
        continue finish

  setPhaseIf services_stopped processControlForProcs $ \(eid, results) -> do
    todo eid
    (Just (StopProcessesRequest m0node _))
      <- gets Local (^. rlens fldReq . rfield)
    showContext
    rg <- getLocalGraph
    let resultProcs :: [(M0.Process, M0.ProcessState)]
        resultProcs = mapMaybe (\case
          Right x ->  (,M0.PSOffline) <$> M0.lookupConfObjByFid x rg
          Left (x,s) -> (,M0.PSFailed $ "Failed to stop: " ++ show s)
                      <$> M0.lookupConfObjByFid x rg
          )
          results
    applyStateChanges $ (uncurry stateSet) <$> resultProcs

    modify Local $ rlens fldRep . rfield .~
      (Just $ StopProcessesResult m0node resultProcs)

    done eid
    continue finish

  directly no_response $ do
    (Just (StopProcessesRequest m0node ps))
      <- gets Local (^. rlens fldReq . rfield)
    -- If we have no response, it possibly means the process is failed.
    -- However, it could be that we have had other notifications - e.g.
    -- from Mero itself, via @ruleProcessStopped@ - and we may have even
    -- restarted the process. So we should only mark those processes
    -- which are still @PSStopping@ as being failed.
    rg <- getLocalGraph
    let failState = M0.PSFailed "Timeout while stopping."
        stoppingProcs = filter (\p -> getState p rg == M0.PSStopping) ps
        resultProcs = (\p -> case getState p rg of
            M0.PSStopping -> (p, failState)
            x -> (p, x)
          ) <$> ps

    applyStateChanges $ (flip stateSet failState)
                    <$> stoppingProcs

    modify Local $ rlens fldRep . rfield .~
      (Just $ StopProcessesResult m0node resultProcs)

    continue finish

  return $ \(StopProcessesRequest _ _) -> return $ Just [quiesce]

  where
    fldReq :: Proxy '("request", Maybe StopProcessesRequest)
    fldReq = Proxy
    fldRep :: Proxy '("reply", Maybe StopProcessesResult)
    fldRep = Proxy
    -- Notifications to wait for
    fldNotifications :: Proxy '("notifications", Maybe [AnyStateSet])
    fldNotifications = Proxy

    args = fldReq =: Nothing
       <+> fldRep =: Nothing
       <+> fldNotifications =: Nothing
       <+> fldUUID =: Nothing

    notificationTimeout = 60 -- Seconds

    stopTimeout = 120 -- Seconds

    showContext = do
      req <- gets Local (^. rlens fldReq . rfield)
      for_ req $ \(StopProcessesRequest n p) ->
        phaseLog "request-context" $
          printf "Node: %s, Processes: %s"
                 (show n) (show p)

    processControlForProcs (HAEvent eid (ProcessControlResultStopMsg _ results) _) _ l =
      case (l ^. rlens fldReq . rfield) of
        Just (StopProcessesRequest _ p)
          | sort (M0.fid <$> p) == sort ((either fst id) <$> results)
          -> return $ Just (eid, results)
        _ -> return Nothing

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
          [ p | p <- getAllProcesses rg
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
      applyStateChanges $ map (\p -> stateSet p $ M0.PSFailed "notification-failed") procs
  where
    isProcFailed (M0.PSFailed _) = True
    isProcFailed _ = False

-- | Listen for 'RpcEvent's. Currently just log the event.
ruleRpcEvent :: Definitions RC ()
ruleRpcEvent = defineSimpleTask "rpc-event" $ \(HAMsg (rpc :: RpcEvent) meta) -> do
  phaseLog "rpc-event" $ show rpc
  phaseLog "meta" $ show meta
