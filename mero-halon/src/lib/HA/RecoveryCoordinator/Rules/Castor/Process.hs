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
  ( handleProcessFailureE
  , handleProcessOnlineE
  , ruleProcessRestarted
  , ruleStopMeroProcess
  , ruleProcessControlStop
  , ruleProcessControlStart
  ) where

import           HA.Encode
import           Control.Monad.Trans.Maybe
import           Data.Either (partitionEithers, rights)
import           Data.Maybe (catMaybes, listToMaybe, mapMaybe)
import           HA.EventQueue.Types
import           HA.RecoveryCoordinator.Actions.Core
import           HA.RecoveryCoordinator.Actions.Hardware
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Actions.Service (lookupRunningService)
import           HA.RecoveryCoordinator.Events.Mero
import           HA.RecoveryCoordinator.Rules.Mero.Conf
import qualified HA.ResourceGraph as G
import           HA.Resources (Has(..), Node(..), Cluster(..))
import           HA.Resources.Castor (Is(..))
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note (ConfObjectState(..), getState)
import           HA.Services.Mero (m0d)
import           HA.Services.Mero.CEP (meroChannel)
import           HA.Services.Mero.Types
import           Mero.Notification (Set(..))
import           Mero.Notification.HAState (Note(..))
import           Network.CEP


import           Control.Monad (when)
import           Data.Typeable
import           Data.Foldable
import           Text.Printf

-- * Process handlers

-- | TODO: make it @[(M0.Node, [M0.Process])]@
getFailedProcs :: [Note] -> G.Graph -> [(M0.Node, M0.Process)]
getFailedProcs ns rg =
  [ (n, p) | Note fid' M0_NC_FAILED <- ns
           , Just p <- [M0.lookupConfObjByFid fid' rg]
           , n <- G.connectedFrom M0.IsParentOf p rg
           ]

-- | Handle failed process notifications from external sources.
-- Currently just send a failed notification out and let the internal
-- handler deal with the rest of the logic.
handleProcessFailureE :: Set -> PhaseM LoopState l ()
handleProcessFailureE (Set ns) = do
  rg <- getLocalGraph
  for_ (getFailedProcs ns rg) $ \(_, p) -> case alreadyFailed p rg of
    True -> phaseLog "warn" $
              "Failed notification for already failed process: " ++ show p

    -- Make sure we're not in PSStarting state: this means that SSPL
    -- restarted process or mero sent ONLINE (indicating a potential
    -- process restart) which means we shouldn't try to resart again
    False -> if getState p rg == M0.PSStarting
             then phaseLog "warn" $ "Proceess in starting state, not restarting: "
                                 ++ show p
             else applyStateChanges [stateSet p $ M0.PSFailed "MERO-failed"]
  where
    alreadyFailed :: M0.Process -> G.Graph -> Bool
    alreadyFailed p rg = case getState p rg of
      M0.PSFailed _ -> True
      M0.PSOffline -> True
      M0.PSStopping -> True
      _ -> False

ruleProcessRestarted :: Definitions LoopState ()
ruleProcessRestarted = define "processes-restarted" $ do
  initialize <- phaseHandle "initialize"
  services_notified <- phaseHandle "process_notified"
  node_notified <- phaseHandle "node_notified"
  notification_timeout <- phaseHandle "notification_timeout"
  restart_result <- phaseHandle "restart_result"
  restart_timeout <- phaseHandle "restart_timeout"
  finish <- phaseHandle "finish"
  end <- phaseHandle "end"

  let viewNotifySet = maybe Nothing (\(_, _, _, _, s) -> Just s)
      viewNode = maybe Nothing (\(_, _, m0node, st, _) -> (,) <$> m0node <*> st)

      resetNodeGuard (HAEvent eid (ProcessControlResultRestartMsg nid results) _) ls (Just (_, _, Just n, _, _)) = do
        let mnode = M0.m0nodeToNode n $ lsGraph ls
        return $ if maybe False (== Node nid) mnode then Just (eid, results) else Nothing
      resetNodeGuard _ _ _ = return Nothing

      nodeChange st = get Local >>= \case
        Just (eid, p, Just m0node, _, nset) -> do
          put Local $ Just (eid, p, Just m0node, Just st, nset)
          applyStateChanges [stateSet m0node st]
          switch [node_notified, timeout 5 notification_timeout]
        _ -> do
          phaseLog "warn" $ "Couldn't lookup node in local state"
          continue finish

      isProcFailed st = case st of
        M0.PSFailed _ -> True
        _ -> False

  setPhaseInternalNotificationWithState initialize isProcFailed $ \(eid, procs) -> do
    todo eid
    rg <- getLocalGraph
    for_ procs $ \(p, _) -> fork NoBuffer $ do
      todo eid
      phaseLog "info" $ "Starting restart procedure for " ++ show (M0.fid p)
      case getState p rg of
        M0.PSStopping -> do phaseLog "info" "service is already stopping - skipping restart"
                            stop
        M0.PSOffline  -> do phaseLog "info" "service is already stopped - skipping restart"
                            stop
        _ -> return ()


      put Local $ Just (eid, p, Nothing, Nothing, [])
      case listToMaybe $ G.connectedTo Cluster Has rg of
        Just M0.MeroClusterRunning -> do
          let srvs = [ stateSet srv (M0.SSInhibited M0.SSFailed)
                     | (srv :: M0.Service) <- G.connectedTo p M0.IsParentOf rg ]
              notificationSet = srvs

          case listToMaybe [ n | n <- G.connectedFrom M0.IsParentOf p rg ] of
            Nothing -> do
              phaseLog "warn" $ "Couldn't find node associated with " ++ show p
              continue finish
            Just (m0node :: M0.Node) -> do
              put Local $ Just (eid, p, Just m0node, Nothing, notificationSet)
              applyStateChanges notificationSet
              switch [services_notified, timeout 5 notification_timeout]
        cst -> do
          phaseLog "warn" $ "Process restart requested but cluster in state "
                         ++ show cst
          continue finish
    done eid

  setPhaseAllNotified services_notified viewNotifySet $ do
    Just (_, p, Just m0node, _, _) <- get Local
    phaseLog "info" $ "Notification for " ++ show (M0.fid p) ++ " landed."

    rg <- getLocalGraph
    mrunRestart <- runMaybeT $ do
      node <- MaybeT . return $ M0.m0nodeToNode m0node rg
      m0svc <- MaybeT $ lookupRunningService node m0d
      ch <- MaybeT . return $ meroChannel rg m0svc
      return $ do
        phaseLog "info" $ "Requesting restart for " ++ show p
        restartNodeProcesses ch [p]
    case mrunRestart of
      Nothing -> do
        phaseLog "warn" $ "Couldn't begin restart for " ++ show p
        continue finish
      Just act -> do
        act
        switch [restart_result, timeout 15 restart_timeout]

  setPhaseIf restart_result resetNodeGuard $ \(eid', results) -> do
    -- Process restart message early: if something goes wrong the rule
    -- starts fresh anyway
    messageProcessed eid'

    case partitionEithers results of
      (okFids, []) -> do
        -- We don't have to do much here: mero should send ONLINE for
        -- services belonging to the process, if all services for the
        -- process are up then process is brought up
        -- (handleServiceOnlineE). Further, if the process is up (as
        -- per mero) and all the processes on the node are up then
        -- node is up (handleProcessOnlineE).
        phaseLog "info" $ "Managed to restart following processes: " ++ show okFids
        continue finish

      (_, failures) -> do
        phaseLog "warn" $ "Following processes failed to restart: " ++ show failures
        nodeChange M0_NC_FAILED

  setPhaseNotified node_notified viewNode $ \(n, nst) -> do
    phaseLog "info" $ "Node notification in restart delivered: "
                   ++ show n ++ " => " ++ show nst
    continue finish

  directly restart_timeout $ do
    Just (_, p, _, _, _) <- get Local
    phaseLog "warn" $ "Restart for " ++ show p ++ " taking too long, bailing."
    nodeChange M0_NC_FAILED

  directly notification_timeout $ do
    Just (_, p, _, _, _) <- get Local
    phaseLog "warn" $ "Notification for " ++ show p ++ " timed out."
    continue finish

  directly finish $ do
    get Local >>= \case
      Nothing -> phaseLog "warn" $ "Finish without local state"
      Just (eid, p, _, _, _) -> do
        phaseLog "info" $ "Process restart rule finish for " ++ show p
        done eid
    continue end

  directly end stop

  start initialize Nothing


-- | Handle online notifications about processes. Part of process
-- restart procedure.
--
-- TODO: MERO-1666 needed for proper restart notifications. Currently
-- always notifies.
--
-- TODO: There are multiple notifications sent out that should
-- probably happen more or less in sequence. Rewrite as rule or use
-- ha_link when it lands.
handleProcessOnlineE :: Set -> PhaseM LoopState l ()
handleProcessOnlineE (Set ns) = do
  -- extract ONLINE processes
  procs <- catMaybes <$> mapM getProc ns
  rg <- getLocalGraph

  -- MERO-1666; this pid is used in test, don't change
  let expectedPid = M0.PID 1234

  for_ procs $ \p -> do
    case (getState p rg, listToMaybe $ G.connectedTo p Has rg) of
      (M0.PSOnline, _) -> do
        phaseLog "warn" $ "ONLINE for PSOnline process: " ++ show p
        -- TODO I think we shouldn't do this
        --applyStateChanges [stateSet p $ M0.PSStarting Nothing]

        notifyProcessRestarted p expectedPid
        -- If all processes on the node are online and node wasn't
        -- failed, mark node as online.
        case listToMaybe $ G.connectedFrom M0.IsParentOf p rg of
          Nothing -> phaseLog "warn" $ "Couldn't find node associated with: "
                                    ++ show p
          Just (n :: M0.Node) -> case getState n rg of
            M0_NC_TRANSIENT -> do
              let allProcs :: [(M0.Process, M0.ProcessState)]
                  allProcs = [ (p', st) | p' <- G.connectedTo n M0.IsParentOf rg
                                        , Just st <- [listToMaybe $ G.connectedTo p Is rg] ]
              case all (\(_, st) -> st == M0.PSOnline) allProcs of
                False -> do
                  let notOnline = filter (\(_, st) -> st /= M0.PSOnline) allProcs
                  phaseLog "info" $ "Some processes still not online: " ++ show notOnline
                True -> applyStateChanges [stateSet n M0_NC_ONLINE]

            st -> phaseLog "warn" $ "Process online for node in state " ++ show st

      (M0.PSStarting, Just pid')
        | eqPid expectedPid pid' -> notifyProcessRestarted p expectedPid
        | otherwise -> do
            phaseLog "warn" $
              "Was already waiting for notification for PID " ++ show pid'
            -- case going away after MERO-1666
            notifyProcessRestarted p expectedPid
      st -> phaseLog "warn" $ "handleProcessOnline: Unexpected state for"
            ++ " process " ++ show p ++ ", " ++ show st
  where
    -- TODO: MERO-1666
    -- Assume that all process notifications come for the process
    -- we're actually waiting for
    eqPid :: M0.PID -> M0.PID -> Bool
    eqPid _ _ = True

    getProc :: Note -> PhaseM LoopState l (Maybe M0.Process)
    getProc (Note fid' M0_NC_ONLINE) =
      HA.RecoveryCoordinator.Actions.Mero.lookupConfObjByFid fid'
    getProc _ = return Nothing

    notifyProcessRestarted p pid = do
      modifyLocalGraph $ return . G.connectUniqueFrom p Has pid
      applyStateChanges [ stateSet p M0.PSOnline ]

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
  phaseLog "debug" $ printf "Results of stopping: %s" (show resultProcs)
  --forM_ (lefts resultProcs) $ \p ->
  --  modifyGraph $ G.connectUniqueFrom p R.Is M0.ProcessBootstrapped
  applyStateChanges $ (\(x, s) -> stateSet x (M0.PSFailed $ "Failed to start: " ++ s))
    <$> rights resultProcs
  forM_ (rights results) $ \(x,s) ->
    phaseLog "error" $ printf "failed to start service %s : %s" (show x) s

-- | When any process goes to Quiescing state, we need to be able to
-- give some timeout for RM to clear caches before actually stopping
-- the service.
ruleStopMeroProcess :: Definitions LoopState ()
ruleStopMeroProcess = define "stop-process" $ do
  initial      <- phaseHandle "stop-process::initial"
  stop_service <- phaseHandle "stop-process::stop-service"
  finish       <- phaseHandle "stop-process::finish"

  setPhase initial $ \(HAEvent eid msg _) -> do
    todo eid
    InternalObjectStateChange chs <- liftProcess $ decodeP msg
    let changes = mapMaybe (\(AnyStateChange (a::a)  old new _) ->
                    case eqT :: Maybe (a :~: M0.Process) of
                      Just Refl -> Just (new, a)
                      Nothing   -> Nothing) chs
    forM_ (changes :: [(M0.ProcessState, M0.Process)]) $
      \(change, p) -> when (change == M0.PSStopping) $ do
        put Local $ Just p
        continue (timeout 30 stop_service)
    done eid

  directly stop_service $ do
    Just p <- get Local
    rg <- getLocalGraph
    maction <- runMaybeT $ do
      let nodes = [node | m0node <- G.connectedFrom M0.IsParentOf p rg
                        , node   <- m0nodeToNode m0node rg
                        ]
      (m0svc,node) <- asum $ map (\node -> MaybeT $ fmap (,node) <$> lookupRunningService node m0d) nodes
      host  <- MaybeT $ findNodeHost node
      ch    <- MaybeT . return $ meroChannel rg m0svc
      return $ do
        stopNodeProcesses ch [p]
        continue finish
    forM_ maction id

  directly finish stop

  start initial Nothing

ruleProcessControlStop :: Definitions LoopState ()
ruleProcessControlStop = defineSimpleTask "handle-process-stop" $ \(ProcessControlResultStopMsg node results) -> do
  phaseLog "info" $ printf "Mero processes stopped on %s" (show node)
  rg <- getLocalGraph
  let
    resultProcs :: [Either M0.Process (M0.Process, String)]
    resultProcs = mapMaybe (\case
      Left x -> Left <$> M0.lookupConfObjByFid x rg
      Right (x,s) -> Right . (,s) <$> M0.lookupConfObjByFid x rg)
      results
  phaseLog "debug" $ printf "Results of stopping: %s" (show resultProcs)
  applyStateChanges $ (\case
    Left x -> stateSet x M0.PSOffline
    Right (x,s) -> stateSet x (M0.PSFailed $ "Failed to stop: " ++ show s))
    <$> resultProcs
  forM_ (rights results) $ \(x,s) ->
    phaseLog "error" $ printf "failed to stop service %s : %s" (show x) s


