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
import           HA.RecoveryCoordinator.Actions.Job
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
import           Network.CEP

import           Control.Distributed.Process (usend)
import           Control.Lens
import           Control.Monad (unless)
import           Control.Monad.Trans.Maybe
import           Data.Binary (Binary)
import           Data.Either (partitionEithers, rights, lefts)
import           Data.Foldable
import           Data.List (nub, sort)
import           Data.Maybe (listToMaybe, mapMaybe)
import           Data.Typeable
import           Data.Vinyl
import           GHC.Generics
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

newtype ProcessRestartRequest = ProcessRestartRequest M0.Process
  deriving (Show, Eq, Ord, Typeable, Generic)
instance Binary ProcessRestartRequest

-- | Catch 'InternalObjectChange's flying by and dispatch
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
jobProcessRestart :: Job ProcessRestartRequest ProcessRecoveryFailure
jobProcessRestart = Job "process-restarted"

-- | Watch for internal process failure notifications and orchestrate
-- their restart. Common scenario is:
--
-- * Fail the services associated with the process
-- * Request restart of the process through systemd
-- * Wait for the systemd process exit code. Deal with non-successful
--   exit code here. If successful, do nothing more here and let other
--   rules handle ONLINE notifications as they come in.
ruleProcessRestart :: Definitions LoopState ()
ruleProcessRestart = mkJobRule jobProcessRestart args $ \finish -> do
  services_notified <- phaseHandle "process_notified"
  notification_timeout <- phaseHandle "notification_timeout"
  restart_result <- phaseHandle "restart_result"
  restart_timeout <- phaseHandle "restart_timeout"

  let resetNodeGuard (HAEvent eid (ProcessControlResultRestartMsg nid results) _) ls l = do
        let Just (ProcessRestartRequest p) = getField . rget fldReq $ l
            Just n = getField . rget fldNode $ l
            mnode = M0.m0nodeToNode n $ lsGraph ls
            resultFids = either id fst <$> results
        return $ if maybe False (== Node nid) mnode && M0.fid p `elem` resultFids
                 then Just (eid, results) else Nothing

      rule_init (ProcessRestartRequest p) = do
        rg <- getLocalGraph
        phaseLog "info" $ "Starting restart procedure for " ++ show (M0.fid p)
        let mpl = getProcessBootLevel p rg
        case (,,) <$> mpl <*> getClusterStatus rg <*> pure (getState p rg) of
          Just (pl, M0.MeroClusterState M0.ONLINE rl _, M0.PSFailed _) | rl >= pl -> do
            let notificationSet = [ stateSet srv (M0.SSInhibited M0.SSFailed)
                                  | (srv :: M0.Service) <- G.connectedTo p M0.IsParentOf rg ]

            case listToMaybe [ n | n <- G.connectedFrom M0.IsParentOf p rg ] of
              Nothing -> do
                phaseLog "warn" $ "Couldn't find node associated with " ++ show p
                return $ Just [finish]
              Just (m0node :: M0.Node) -> do
                modify Local $ rlens fldNode .~ Field (Just m0node)
                modify Local $ rlens fldNotifications .~ Field (Just notificationSet)
                applyStateChanges notificationSet
                return $ Just [services_notified, timeout 5 notification_timeout]
          cst -> do
            phaseLog "warn" $ "Process restart requested for "
                           ++ "(process state, cluster state): "
                           ++ show cst
            return $ Just [finish]

  setPhaseAllNotified services_notified (rlens fldNotifications . rfield) $ do
    Just (ProcessRestartRequest p) <- getField . rget fldReq <$> get Local
    Just m0node <- getField . rget fldNode <$> get Local

    phaseLog "info" $ "Notification for " ++ show (M0.fid p) ++ " landed."
    rg <- getLocalGraph
    mrunRestart <- runMaybeT $ do
      node <- MaybeT . return $ M0.m0nodeToNode m0node rg
      ch <- MaybeT . return $ meroChannel rg node
      return $ do
        phaseLog "info" $ "Requesting restart for " ++ show p
        -- TODO: Probably should check that the controller we're on
        -- (if any) is still online, might not want to try and restart
        -- the process if it's the last one on controller to fail (and
        -- therefore failing the controller)
        restartNodeProcesses ch [p]
    case mrunRestart of
      Nothing -> do
        phaseLog "warn" $ "Couldn't begin restart for " ++ show p
        continue finish
      Just act -> do
        act
        switch [restart_result, timeout 180 restart_timeout]

  setPhaseIf restart_result resetNodeGuard $ \(eid', results) -> do
    todo eid'
    phaseLog "debug" $ "Got restart results: " ++ show results
    Just (ProcessRestartRequest p) <- getField . rget fldReq <$> get Local
    case filter (\(fid', _) -> fid' == M0.fid p) <$> partitionEithers results of
      (okFids, []) -> do
        -- We don't have to do much here: mero should send ONLINE for
        -- services belonging to the process, if all services for the
        -- process are up then process is brought up
        -- (ruleServiceNotificationHandler). Further, if the process is up (as
        -- per mero) and all the processes on the node are up then
        -- node is up (ruleProcessOnline).
        phaseLog "info" $ "Managed to initiate restart following processes: " ++ show okFids
        continue finish

      (_, failures@(fl : _)) -> do
        phaseLog "warn" $ "Following processes failed to restart: " ++ show failures
        modify Local $ rlens fldRep .~ Field (Just $ ProcessRecoveryFailure fl)
    done eid'
    continue finish

  directly restart_timeout $ do
    Just (ProcessRestartRequest p) <- getField . rget fldReq <$> get Local
    phaseLog "warn" $ "Restart for " ++ show p ++ " taking too long, bailing."
    modify Local $ rlens fldRep .~ Field (Just $ ProcessRecoveryFailure (M0.fid p, "Restart timed out"))
    continue finish

  return rule_init
  where
    fldReq = Proxy :: Proxy '("request", Maybe ProcessRestartRequest)
    fldRep = Proxy :: Proxy '("reply", Maybe ProcessRecoveryFailure)
    fldNode = Proxy :: Proxy '("node", Maybe M0.Node)
    fldNotifications = Proxy :: Proxy '("notifications", Maybe [AnyStateSet])

    args = fldUUID          =: Nothing
       <+> fldReq           =: Nothing
       <+> fldRep           =: Nothing
       <+> fldNode          =: Nothing
       <+> fldNotifications =: Nothing

-- | Handle process started notifications.
ruleProcessOnline :: Definitions LoopState ()
ruleProcessOnline = define "castor::process::online" $ do
  rule_init <- phaseHandle "rule_init"

  setPhaseIf rule_init onlineProc $ \(eid, p, processPid) -> do
    todo eid
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
        applyStateChanges [ stateSet p M0.PSOnline ]  -- XXX: registerSyncGraph
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

  setPhaseIf rule_init stoppedProc $ \(eid, p, _) -> do
    todo eid
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
    resultProcs :: [Either M0.Process (M0.Process, String)]
    resultProcs = mapMaybe (\case
      Left x -> Left <$> M0.lookupConfObjByFid x rg
      Right (x,s) -> Right . (,s) <$> M0.lookupConfObjByFid x rg)
      results
  unless (null $ rights resultProcs) $ do
    applyStateChanges $ (\(x, s) -> stateSet x (M0.PSFailed $ "Failed to start: " ++ s))
      <$> rights resultProcs
  for_ (rights results) $ \(x,s) ->
    phaseLog "error" $ printf "failed to start service %s : %s" (show x) s
  for_ (nub $ lefts results) $ \x ->
    phaseLog "info" $ printf "Process started: %s" (show x)

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

    -- TODO Remove this from here and handle in a separate node rule
    -- let failedProcs = rights results
    -- unless (null failedProcs) $ do
    --   forM_ failedProcs $ \(x,s) -> do
    --     phaseLog "error" $ printf "failed to stop process %s : %s" (show x) s
    --   -- We're trying to stop the processes on the node but it's
    --   -- failing. Fail the node.
    --   applyStateChanges $ (\n -> stateSet n M0_NC_FAILED) <$> nodeToM0Node (Node nid) rg
    --
    -- forM_ (lefts results) $ \x ->
    --   phaseLog "info" $ printf "process stopped: %s" (show x)

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
