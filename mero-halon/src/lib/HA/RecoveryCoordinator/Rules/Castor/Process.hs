{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase       #-}
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
import           HA.Resources (Has(..), Node(..))
import           HA.Resources.Castor (Is(..))
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note (getState, NotifyFailureEndpoints(..), showFid)
import           HA.Services.Mero.RC.Actions (meroChannel)
import           HA.Services.Mero.Types
import           Mero.Notification.HAState
import           Mero.ConfC (ServiceType(..))
import           Network.CEP

import           Control.Distributed.Process (usend)
import           Control.Lens
import           Control.Monad (unless)
import           Data.Either (partitionEithers, rights, lefts)
import           Data.Foldable
import           Data.List (nub, sort)
import           Data.Maybe (listToMaybe, mapMaybe)
import           Data.Typeable
import           Data.Vinyl
import           Text.Printf

rules :: Definitions LoopState ()
rules = sequence_ [
    ruleProcessOnline
  , ruleProcessStopped
  , ruleProcessDispatchRestart
  , ruleProcessRestart
  , ruleProcessConfigured
  , ruleStop
  , ruleProcessControlStart
  , ruleFailedNotificationFailsProcess
  , ruleProcessKeepaliveReply
  ]

-- | Catch 'InternalObjectStateChange's flying by and dispatch
-- 'ProcessRestartRequest' for every failed process, allowing
-- 'ruleProcessRestart' to do its job while assuring only one on-going
-- restart per process.
ruleProcessDispatchRestart :: Definitions LoopState ()
ruleProcessDispatchRestart = define "rule-process-dispatch-restart" $ do
  rule_init <- phaseHandle "rule_init"

  setPhaseInternalNotificationWithState rule_init isProcFailed $ \(eid, procs) -> do
    todo eid
    for_ procs $ promulgateRC . ProcessRestartRequest . fst
    done eid

  startFork rule_init ()
  where
    isProcFailed _ (M0.PSFailed _) = True
    isProcFailed _ _ = False

-- | Job used in 'ruleProcessRestart'
jobProcessRestart :: Job ProcessRestartRequest ProcessRecoveryResult
jobProcessRestart = Job "process-restarted"

-- | Listen for 'ProcessRestartRequest' and trigger the restart of the
-- process in question, dealing with timeout and systemd exit codes.
ruleProcessRestart :: Definitions LoopState ()
ruleProcessRestart = mkJobRule jobProcessRestart args $ \finish -> do
  restart_result <- phaseHandle "restart_result"
  process_online <- phaseHandle "process_online"
  process_failed <- phaseHandle "process_failed"
  retry_restart <- phaseHandle "retry_restart"
  restart_timeout <- phaseHandle "restart_timeout"

  run_notification <- mkPhaseNotify 20
    (\l -> case getField $ l ^. rlens fldReq of
             Nothing -> Nothing
             Just (ProcessRestartRequest p) -> Just (p, M0.PSStarting))
    (phaseLog "warn" "Failed to notify." >> continue finish)
    (\_ _ -> do
        Just (ProcessRestartRequest p) <- getField . rget fldReq <$> get Local
        Just ch <- getField . rget fldRestartCh <$> get Local
        phaseLog "info" $ "Requesting restart for " ++ showFid p
        restartNodeProcesses ch [p]
        return [restart_result, timeout 180 restart_timeout])

  let resetNodeGuard (HAEvent eid (ProcessControlResultRestartMsg nid results) _) ls l = do
        let Just (ProcessRestartRequest p) = getField . rget fldReq $ l
            Just n = getField . rget fldNode $ l
            mnode = M0.m0nodeToNode n $ lsGraph ls
            resultFids = either fst fst <$> results
        return $ if maybe False (== Node nid) mnode && M0.fid p `elem` resultFids
                 then Just (eid, results) else Nothing

      rule_init (ProcessRestartRequest p) = do
        rg <- getLocalGraph
        case (,) <$> getProcessBootLevel p rg <*> getClusterStatus rg of
          Just (pl, M0.MeroClusterState M0.ONLINE rl _) | rl >= pl -> do
            case listToMaybe [ n | n <- G.connectedFrom M0.IsParentOf p rg ] of
              Nothing -> do
                phaseLog "warn" $ "Couldn't find node associated with " ++ show p
                setFailure (M0.fid p) "No node info in RG"
                return $ Just [finish]
              Just (m0node :: M0.Node) -> do
                modify Local $ rlens fldNode .~ Field (Just m0node)
                case M0.m0nodeToNode m0node rg >>= meroChannel rg of
                  Nothing -> do
                    phaseLog "warn" $ "Couldn't begin restart for " ++ show p
                    return $ Just [finish]
                  Just _
                    | any (\s -> M0.s_type s == CST_HA) (G.connectedTo p M0.IsParentOf rg) -> do
                    phaseLog "warn" $ "Process restart rule doesn't restart halon process."
                    return Nothing
                  Just ch -> do
                    modify Local $ rlens fldRestartCh .~ Field (Just ch)
                    phs <- run_notification p M0.PSStarting
                    return $ Just phs
          Just (pl, cst) -> do
            phaseLog "warn" "Requested process restart but process can't restart on this cluster boot level"
            phaseLog "process.bootlevel" $ show pl
            phaseLog "cluster.status" $ show cst
            setNotNeeded (M0.fid p)
            return $ Just [finish]
          Nothing -> do
            phaseLog "error" "Couldn't find process bootlevel or cluster status in RG"
            setNotNeeded (M0.fid p)
            return $ Just [finish]

  setPhaseIf restart_result resetNodeGuard $ \(eid', results) -> do
    todo eid'
    phaseLog "debug" $ "Got restart results: " ++ show results
    Just (ProcessRestartRequest p) <- getField . rget fldReq <$> get Local
    case filter (\(fid', _) -> fid' == M0.fid p) <$> partitionEithers results of
      (okFids, []) -> do
        -- Record the PID for each started process, although don't yet
        -- mark them as ONLINE - this will be handled when Mero sends its
        -- notification of ONLINE.
        for_ okFids $ \(fid, mpid) -> do
          phaseLog "info" $ "Process restart successfully initiated by systemd."
          phaseLog "fid" $ show fid
          phaseLog "pid" $ show mpid

          (mres :: Maybe M0.Process) <- M0.lookupConfObjByFid fid
                                      <$> getLocalGraph
          forM_ ((,) <$> mres <*> mpid) $ \(res, pid) ->
              modifyGraph $ G.connectUniqueFrom res Has (M0.PID pid)

        done eid'
        switch [process_online, process_failed, timeout 180 restart_timeout]

      -- TODO: it's only an implementation detail that this (pfid,
      -- msg) happens to be ‘the right one’ because we check that
      -- M0.fid is in results and we only request one process to
      -- restart so the result happens to only hold one process. It's
      -- not unimaginable however that something else requests restart
      -- of more processes at once in which case these values may be
      -- wrong.
      (_, failures@((pfid, msg) : _)) -> do
        phaseLog "warn" $ "Following processes failed to restart: " ++ show failures
        setFailure pfid msg
        done eid'
        continue finish

  -- Wait for the process to come online - sent out by `ruleProcessOnline`
  setPhaseNotified process_online (procState (== M0.PSOnline)) $ \_ ->
    continue finish

  -- If process fails during starting, check the reset count, wait 5s, and
  -- try again. Currently the only way we can tell that the process fails
  -- is for SSPL to inform us that it died.
  setPhaseNotified process_failed (procState psFailed) $ \(p, _) -> do
    restartCount <- gets Local (^. rlens fldRestartCount . rfield)
    modify Local $ rlens fldRestartCount . rfield +~ 1
    if restartCount < restartMaxAttempts
    then do
      continue $ timeout 5 retry_restart
    else do
      phaseLog "warn" $ "Restart for " ++ show p ++ " failed too many times."
      setFailure (M0.fid p) "Did not start correctly."
      continue finish

  directly retry_restart $ do
    Just (ProcessRestartRequest p) <- getField . rget fldReq <$> get Local
    phs <- run_notification p M0.PSStarting
    switch phs

  directly restart_timeout $ do
    Just (ProcessRestartRequest p) <- getField . rget fldReq <$> get Local
    phaseLog "warn" $ "Restart for " ++ show p ++ " taking too long, bailing."
    setFailure (M0.fid p) "Restart timed out"
    continue finish

  return rule_init
  where
    setFailure pfid msg = modify Local $ rlens fldRep .~ Field (Just $ ProcessRecoveryFailure (pfid, msg))
    setNotNeeded pfid = modify Local $ rlens fldRep . rfield .~ (Just $ ProcessRecoveryNotNeeded pfid)

    psFailed (M0.PSFailed _) = True
    psFailed _ = False

    procState state l = case getField . rget fldReq $ l of
      Just (ProcessRestartRequest p) -> Just (p, state)
      Nothing -> Nothing

    restartMaxAttempts = 5

    fldReq = Proxy :: Proxy '("request", Maybe ProcessRestartRequest)
    fldRep = Proxy :: Proxy '("reply", Maybe ProcessRecoveryResult)
    fldNode = Proxy :: Proxy '("node", Maybe M0.Node)
    fldRestartCh = Proxy :: Proxy '("restart-ch", Maybe (TypedChannel ProcessControlMsg))
    fldRestartCount = Proxy :: Proxy '("restart-count", Int)

    args = fldUUID          =: Nothing
       <+> fldReq           =: Nothing
       <+> fldRep           =: Nothing
       <+> fldNode          =: Nothing
       <+> fldRestartCh     =: Nothing
       <+> fldRestartCount  =: 0

-- | Handle process started notifications.
ruleProcessOnline :: Definitions LoopState ()
ruleProcessOnline = define "castor::process::online" $ do
  rule_init <- phaseHandle "rule_init"

  setPhaseIfConsume rule_init onlineProc $ \(eid, p, processPid) -> do
    rg <- getLocalGraph
    case (getState p rg, listToMaybe $ G.connectedTo p Has rg) of
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
      -- We have a process but no PID for it, somehow. This can happen
      -- if the process was set to online through all its services
      -- coming up online and now we're receiving the process
      -- notification itself. Just store the PID.x
      (M0.PSOnline, Nothing) -> modifyGraph $ G.connectUniqueFrom p Has processPid

      -- Process was starting: we don't care what the PID was because
      -- it's now out of date. We log it anyway, it's probably PID of
      -- the old process.
      --
      -- TODO: We can use TAG_M0_CONF_HA_PROCESS_STARTING notification
      -- now if we desire.
      (M0.PSStarting, oldPid) -> do
        phaseLog "action" "Process started."
        phaseLog "info" $ "process.fid     = " ++ show (M0.fid p)
        phaseLog "info" $ "process.old_pid = " ++ show oldPid
        phaseLog "info" $ "process.pid     = " ++ show processPid
        modifyGraph $ G.connectUniqueFrom p Has processPid
        applyStateChanges [ stateSet p M0.PSOnline ]
      (_, _)
        | any (\s -> M0.s_type s == CST_HA) (G.connectedTo p M0.IsParentOf rg) -> do
        phaseLog "action" "HA Process started."
        phaseLog "info" $ "process.fid     = " ++ show (M0.fid p)
        phaseLog "info" $ "process.pid     = " ++ show processPid
        modifyGraph $ G.connectUniqueFrom p Has processPid
        applyStateChanges [ stateSet p M0.PSOnline ]
      st -> phaseLog "warn" $ "ruleProcessOnline: Unexpected state for"
            ++ " process " ++ show p ++ ", " ++ show st
    done eid

  startFork rule_init Nothing
  where
    onlineProc (HAEvent eid (m@HAMsgMeta{}, ProcessEvent t pt pid) _) ls _ = do
      let mpd = M0.lookupConfObjByFid (_hm_fid m) (lsGraph ls)
      return $ case (t, pt, mpd) of
        (TAG_M0_CONF_HA_PROCESS_STARTED, TAG_M0_CONF_HA_PROCESS_M0D, Just (p :: M0.Process)) | pid /= 0 ->
          Just (eid, p, M0.PID $ fromIntegral pid)
        (TAG_M0_CONF_HA_PROCESS_STARTED, TAG_M0_CONF_HA_PROCESS_KERNEL, Just (p :: M0.Process)) ->
          Just (eid, p, M0.PID $ fromIntegral pid)
        _ -> Nothing

-- | Handled process configure event.
--
-- Properties:
--
--   [Idempotent] yes
--   [Nonblocking] yes
--   [Emits] 'ProcessConfigured' events
ruleProcessConfigured :: Definitions LoopState ()
ruleProcessConfigured = defineSimpleTask "castor::process::handle-configured" $
  \(ProcessControlResultConfigureMsg node results) -> do
    phaseLog "begin" $ "Mero process configured"
    phaseLog "info" $ "node = " ++ show node
    rg <- getLocalGraph
    let
      resultProcs :: [Either M0.Process (M0.Process, String)]
      resultProcs = mapMaybe (\case
        Left x -> Left <$> M0.lookupConfObjByFid x rg
        Right (x,s) ->Right . (,s) <$> M0.lookupConfObjByFid x rg) results
    unless (null $ rights resultProcs) $ do
      applyStateChanges $ (\(x, s) -> stateSet x (M0.PSFailed $ "Failed to start: " ++ s))
        <$> rights resultProcs
    for_ (rights resultProcs) $ \(p, s) -> do
       phaseLog "error" $ printf "failed to configure %s : %s" (showFid p) s
    for_ (lefts resultProcs) $ \p -> do
       phaseLog "info" $ printf "%s: configured" (showFid p)
       modifyGraph $ G.connectUniqueFrom p Is M0.ProcessBootstrapped
    -- XXX: use notification somehow
    registerSyncGraphProcess $ \rc -> do
      for_ results $ \r -> case r of
        Left x -> usend rc (ProcessConfigured x)
        Right (x,_) -> usend rc (ProcessConfigureFailed x)
    phaseLog "end" $ "Mero process configured."

-- | Listen for process event notifications about a stopped process
-- and decide whether we want to fail the process. If we do fail the
-- process, 'ruleProcessRestarted' deals with the internal state
-- change notification.
ruleProcessStopped :: Definitions LoopState ()
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

    stoppedProc (HAEvent eid (m@HAMsgMeta{}, ProcessEvent t pt pid) _) ls _ = do
      let mpd = M0.lookupConfObjByFid (_hm_fid m) (lsGraph ls)
      return $ case (t, pt, mpd) of
        (TAG_M0_CONF_HA_PROCESS_STOPPED, TAG_M0_CONF_HA_PROCESS_M0D, Just (p :: M0.Process)) | pid /= 0 ->
          Just (eid, p, M0.PID $ fromIntegral pid)
        _ -> Nothing

-- | Handles halon:m0d reply about service start and set Process
-- as failed if error occur.
ruleProcessControlStart :: Definitions LoopState ()
ruleProcessControlStart = defineSimpleTask "handle-process-start" $ \(ProcessControlResultMsg node results) -> do
  phaseLog "info" $ printf "Mero proceses started on %s" (show node)
  rg <- getLocalGraph
  let
    resultProcs :: [Either (M0.Process, Maybe M0.PID) (M0.Process, String)]
    resultProcs = mapMaybe (\case
      Left (x,mpid) -> Left . (,M0.PID <$> mpid) <$> M0.lookupConfObjByFid x rg
      Right (x,s) -> Right . (,s) <$> M0.lookupConfObjByFid x rg)
      results
  unless (null $ rights resultProcs) $ do
    applyStateChanges $ (\(x, s) -> stateSet x (M0.PSFailed $ "Failed to start: " ++ s))
      <$> rights resultProcs
  for_ (rights results) $ \(x,s) ->
    phaseLog "error" $ printf "failed to start service %s : %s" (show x) s
  for_ (nub $ lefts results) $ \(fid, mpid) -> do
    phaseLog "info" $ printf "Process started: %s (PID %s)" (show fid) (show mpid)
    -- Record the PID for each started process, although don't yet
    -- mark them as ONLINE - this will be handled when Mero sends its
    -- notification of ONLINE.
    (mres :: Maybe M0.Process) <- M0.lookupConfObjByFid fid
                                <$> getLocalGraph
    for_ ((,) <$> mres <*> mpid) $ \(res, pid) ->
        modifyGraph $ G.connectUniqueFrom res Has (M0.PID pid)


jobStop :: Job StopProcessesRequest StopProcessesResult
jobStop = Job "castor::process::stop"

ruleStop :: Definitions LoopState ()
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
          Left x ->  (,M0.PSOffline) <$> M0.lookupConfObjByFid x rg
          Right (x,s) -> (,M0.PSFailed $ "Failed to stop: " ++ show s)
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
          | sort (M0.fid <$> p) == sort ((either id fst) <$> results)
          -> return $ Just (eid, results)
        _ -> return Nothing

-- | Listens for 'NotifyFailureEndpoints' from notification mechanism.
-- Finds the non-failed processes which failed to be notified (through
-- endpoints of the services in question) and fails them. This allows
-- 'ruleProcessRestarted' to deal with them accordingly.
ruleFailedNotificationFailsProcess :: Definitions LoopState ()
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
