-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Mero cluster rules
--
-- Relevant part of the resource graph.
-- @@@
--     R.Cluster
--       |  |
--       |  +-------M0.Root
--       |           |
--       |          M0.Profie
--       |           |
--       |          M0.FileSystem
--     R.Host          |
--      |  |           v
--      |  +--------->M0.Node
--      v
--     R.Node
-- @@@
--
--
--
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE ViewPatterns          #-}
{-# LANGUAGE GADTs                 #-}
module HA.RecoveryCoordinator.Rules.Castor.Cluster
  ( -- * All rules in one
    clusterRules
    -- ** Requests
    -- $requests
  , requestClusterStatus
  , requestClusterStart
  , requestClusterStop
    -- ** Event Handlers
  , eventUpdatePrincipalRM
  , eventAdjustClusterState
  , eventNodeFailedStart
  ) where

import           HA.EventQueue.Types
import           HA.Encode
import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           Mero.Notification.HAState

import qualified HA.ResourceGraph as G
import           HA.RecoveryCoordinator.Actions.Core
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Actions.Hardware
      ( findHostStorageDevices )
import           HA.RecoveryCoordinator.Actions.Service (lookupRunningService)
import           HA.RecoveryCoordinator.Actions.Castor.Cluster
     ( notifyOnClusterTransition )
import           HA.RecoveryCoordinator.Events.Castor.Cluster
import           HA.RecoveryCoordinator.Events.Mero
import           HA.RecoveryCoordinator.Rules.Mero.Conf
     ( applyStateChanges
     , setPhaseNotified
     )
import           HA.RecoveryCoordinator.Rules.Castor.Node
     ( maxTeardownLevel )
import           HA.Services.Mero
import           HA.Services.Mero.CEP (meroChannel)
import           Mero.ConfC (ServiceType(..))
import           Network.CEP

import           Control.Applicative
import           Control.Category
import           Control.Distributed.Process hiding (catch, try)
import           Control.Lens
import           Control.Monad (join, unless, when)
import           Control.Monad.Trans.Maybe

import           Data.List ((\\))
import           Data.Maybe (catMaybes, listToMaybe, mapMaybe, fromMaybe, isJust)
import           Data.Foldable
import           Data.Traversable (forM)
import           Data.Typeable

import           Prelude hiding ((.), id)

-- | All the rules that are required for cluster start.
clusterRules :: Definitions LoopState ()
clusterRules = sequence_
  [ requestClusterStatus
  , requestClusterStart
  , requestClusterStop
  , requestStartMeroClient
  , requestStopMeroClient
  , eventAdjustClusterState
  , eventUpdatePrincipalRM
  , eventNodeFailedStart
  , ruleServiceNotificationHandler
  ]

-------------------------------------------------------------------------------
-- Events handling
-------------------------------------------------------------------------------

-- | Fix we failed to load kernel modules on any server, then
-- we need to put cluster into a failed state.
eventNodeFailedStart :: Definitions LoopState ()
eventNodeFailedStart = defineSimpleTask "castor::cluster:node-failed-bootstrap" $
  \result -> do
    case result of
      KernelStarted{} -> return ()
      _ -> do modifyGraph $ G.connectUnique R.Cluster R.Has M0.MeroClusterFailed
      -- XXX: notify $ MeroClusterFailed
      -- XXX: check if it's a client node, in that case such failure should not
      -- be a panic


-- | Local state used in 'ruleServiceNotificationHandler'.
type ClusterTransitionLocal =
  Maybe ( UUID
        , Maybe (M0.Service, M0.ServiceState)
        , Maybe (M0.Process, M0.ProcessState)
        )


-- | Handle notification for service states. This rule is responsible
-- for logic that sets service states, decides what to do with the
-- parent process based on the service states and on unblocking the
-- cluster bootstrap barrier if bootstrap is happening.
ruleServiceNotificationHandler :: Definitions LoopState ()
ruleServiceNotificationHandler = define "service-notification-handler" $ do
   start_rule <- phaseHandle "start"
   service_notified <- phaseHandle "service-notified"
   process_notified <- phaseHandle "process-notified"
   timed_out <- phaseHandle "timed-out"
   finish <- phaseHandle "finish"

   let startState :: ClusterTransitionLocal
       startState = Nothing

       viewProc :: ClusterTransitionLocal -> Maybe (M0.Process, M0.ProcessState)
       viewProc = maybe Nothing (\(_, _, proci) -> proci)

       viewSrv :: ClusterTransitionLocal -> Maybe (M0.Service, M0.ServiceState)
       viewSrv = maybe Nothing (\(_,srvi,_) -> srvi)


       -- Check that the service has the given tag (predicate) and
       -- check that it's not in the given state in RG already.
       serviceTagged p typ (HAEvent eid (m@HAMsgMeta{}, ServiceEvent se st) _) ls _ = do
         let rg = lsGraph ls
             isStateChanged s = M0.getState s (lsGraph ls) /= typ
         return $ case M0.lookupConfObjByFid (_hm_fid m) rg of
           Just (s :: M0.Service) | p se && isStateChanged s -> Just (eid, s, typ, st)
           _ -> Nothing

       isServiceOnline = serviceTagged (== TAG_M0_CONF_HA_SERVICE_STARTED) M0.SSOnline
       isServiceStopped = serviceTagged (== TAG_M0_CONF_HA_SERVICE_STOPPED) M0.SSOffline

       startOrStop msg ls g = isServiceOnline msg ls g >>= \case
         Nothing -> isServiceStopped msg ls g
         Just x -> return $ Just x

   setPhaseIf start_rule startOrStop $ \(eid, service, st, typ) -> do
     todo eid
     phaseLog "info" $ concat [ "Cluster transition for [", M0.showFid service
                              , ": ", show st, " (", show typ, ")]" ]
     put Local $ Just (eid, Just (service, st), Nothing)
     applyStateChanges [stateSet service st]
     switch [service_notified, timeout 30 timed_out]

   setPhaseNotified service_notified viewSrv $ \(srv, st) -> do
     rg <- getLocalGraph
     Just (eid, _, _) <- get Local
     -- find the process, the service belongs to, check if all
     -- services are online, if yes then update process state and
     -- notify barrier
     case (st, listToMaybe $ G.connectedFrom M0.IsParentOf srv rg) of
       (M0.SSOnline, Just (p :: M0.Process)) -> do
         let allSrvs :: [M0.Service]
             allSrvs = G.connectedTo p M0.IsParentOf rg
             onlineSrvs = [ s | s <- allSrvs
                              , M0.SSOnline <- G.connectedTo s R.Is rg ]
             newProcessState = M0.PSOnline

         put Local $ Just (eid, Just (srv, st), Just (p, newProcessState))
         if length allSrvs == length onlineSrvs
         then do phaseLog "info" $
                   unwords [ "All services for", M0.showFid p
                           , "online, marking process as online" ]
                 modifyGraph $ G.connectUniqueFrom p R.Is M0.ProcessBootstrapped


                 -- TODO: maybe we should not notify here but instead
                 -- notify after mero itself sends the process
                 -- notification
                 applyStateChanges [stateSet p newProcessState]
                 switch [process_notified, timeout 30 timed_out]

         else do phaseLog "info" $ "Still waiting to hear from "
                                ++ show (map M0.fid $ allSrvs \\ onlineSrvs)
                 continue finish
       (M0.SSOffline, Just p) -> case M0.getState p rg of
         M0.PSInhibited{} -> do
           phaseLog "info" $ "Not notifying about process through service as it's inhibited"
           continue finish
         M0.PSOffline  -> do
           phaseLog "info" $ "Not notifying about process through service as it's offline"
           continue finish
         M0.PSStopping -> do
           phaseLog "info" $ "Not notifying about process through service as it's stopping"
           continue finish
         pst -> do
           phaseLog "info" $ "Service for process failed, process state was " ++ show pst
           let failMsg = "Underlying service failed: " ++ show (M0.fid srv)
           applyStateChanges [stateSet p . M0.PSFailed $ failMsg]
           continue finish
       err -> do phaseLog "warn" $ "Couldn't handle bad state for " ++ M0.showFid srv
                                ++ ": " ++ show err
                 continue finish

   setPhaseNotified process_notified viewProc $ \(p, pst) -> do
     phaseLog "info" $ "Process " ++ show (M0.fid p) ++ " => " ++ show pst
     Just (_, srvi, _) <- get Local
     rg <- getLocalGraph
     let cst = case listToMaybe $ G.connectedTo R.Cluster R.Has rg of
           Just (M0.MeroClusterStarting (M0.BootLevel 0)) ->
             Right $ M0.MeroClusterStarting (M0.BootLevel 1)
           Just (M0.MeroClusterStarting (M0.BootLevel 1)) ->
             Right M0.MeroClusterRunning
           Just M0.MeroClusterRunning -> Right M0.MeroClusterRunning
           st -> Left st
     case cst of
       Left st -> phaseLog "warn" $
         unwords [ "Received service notification about", show srvi
                 , "but cluster is in state" , show st ]
       Right _ -> return ()
     continue finish

   directly timed_out $ do
     phaseLog "warn" $ "Waited too long for a notification ack"
     continue finish

   directly finish $ get Local >>= \case
     Just (eid, _, _) -> done eid
     lst -> phaseLog "warn" $ "In finish with strange local state: " ++ show lst

   startFork start_rule startState

-- | This is a rule which interprets state change events and is responsible for
-- changing the state of the cluster accordingly'
--
-- Listens for:
--   - internal notifications
-- Emits:
--   - 'Event.BarrierPass'
-- Idempotent
-- Nonblocking
eventAdjustClusterState :: Definitions LoopState ()
eventAdjustClusterState = defineSimpleTask "castor::cluster::event::update-cluster-state" $ \msg -> do
    let findChanges = do --- XXX: move to common place
          InternalObjectStateChange chs <- liftProcess $ decodeP msg
          return $  mapMaybe (\(AnyStateChange (_ :: a) _old new _) ->
                       case eqT :: Maybe (a Data.Typeable.:~: M0.Process) of
                         Just Refl -> Just new
                         Nothing   -> Nothing) chs
    recordedState <- fromMaybe M0.MeroClusterStopped . listToMaybe
        . G.connectedTo R.Cluster R.Has <$> getLocalGraph
    case recordedState of
      M0.MeroClusterStarting{} -> do
        anyDown <- any checkDown <$> findChanges
        if anyDown
        then do phaseLog "error" "Some processes failed to start - put cluster into failed state."
                modifyGraph $ G.connectUnique R.Cluster R.Has M0.MeroClusterFailed
        else do anyUp <- any checkUp <$> findChanges
                when anyUp $ notifyOnClusterTransition (> recordedState) BarrierPass Nothing
      M0.MeroClusterStopping{} -> do
        anyDown <- any checkDown <$> findChanges
        when anyDown $ do
          phaseLog "debug" $ "at least one process up - trying: " ++ show recordedState
          notifyOnClusterTransition (> recordedState) BarrierPass Nothing
      -- TODO: transition cluster in some state while cluster is running
      --
      -- Note: we don't want to merge this with MeroClusterStarting
      -- case because if we get Inhibited during bootstrap then that's
      -- bad but if we get it while cluster is running already, that's
      -- still bad but it probably means node is rebooting (or some
      -- other failure we can recover from).
      M0.MeroClusterRunning -> do
        anyUp <- any checkUp <$> findChanges
        when anyUp $ do
          phaseLog "info" "Adjust while in running state"
          notifyOnClusterTransition (== recordedState) BarrierPass Nothing
      st -> phaseLog "info" $ "Not adjusting cluster from state " ++ show st
  where
    checkUp M0.PSOnline = True
    checkUp _        = False
    checkDown M0.PSFailed{} = True
    checkDown M0.PSOffline  = True
    checkDown M0.PSInhibited{} = True
    checkDown _             = False

-- | This is a rule catches death of the Principal RM and elects new one.
--
-- Listens for:
--   - internal notifications
-- Emits:
--   - internal notifications
-- Idempotent
-- Nonblocking
eventUpdatePrincipalRM :: Definitions LoopState ()
eventUpdatePrincipalRM = defineSimpleTask "castor::cluster::event::update-principal-rm" $ \msg -> do
    let findChanges = do -- XXX: move to the common place
          InternalObjectStateChange chs <- liftProcess $ decodeP msg
          return $ mapMaybe (\(AnyStateChange (a :: a) _old _new _) ->
                       case eqT :: Maybe (a Data.Typeable.:~: M0.Process) of
                         Just Refl -> Just a
                         Nothing   -> Nothing) chs
    mrm <- getPrincipalRM
    unless (isJust mrm) $ do
      changed_processes :: [M0.Process] <- findChanges
      unless (null changed_processes) $
        pickPrincipalRM >>= \msrv -> forM_ msrv $ \srv -> do
          procs :: [M0.Process] <- getParents srv
          applyStateChanges $! stateSet srv M0.SSOnline:((`stateSet` M0.PSOnline) <$> procs)

-------------------------------------------------------------------------------
-- Requests handling
-------------------------------------------------------------------------------
-- $requests.
-- User can control whole cluster state using following requests.
-- Each request trigger a long procedure of moving cluster into desired state
-- if those transition is possible.

-- | Query mero cluster status.
--
-- Nilpotent request.
requestClusterStatus :: Definitions LoopState ()
requestClusterStatus = defineSimple "castor::cluster::request::status"
  $ \(HAEvent eid  (ClusterStatusRequest ch) _) -> do
      rg <- getLocalGraph
      profile <- getProfile
      filesystem <- getFilesystem
      repairs <- fmap catMaybes $ traverse (\p -> fmap (p,) <$> getPoolRepairInformation p) =<< getPool
      let status = listToMaybe $ G.connectedTo R.Cluster R.Has rg
      hosts <- forM (G.connectedTo R.Cluster R.Has rg) $ \host -> do
            let nodes = G.connectedTo host R.Runs rg :: [M0.Node]
            let node_st = maybe M0.M0_NC_UNKNOWN (flip M0.getState rg) $ listToMaybe nodes
            prs <- forM nodes $ \node -> do
                     processes <- getChildren node
                     forM processes $ \process -> do
                       let st = M0.getState process rg
                       services <- getChildren process
                       let services' = map (\srv -> (srv, M0.getState srv rg)) services
                       return (process, ReportClusterProcess st services')
            let go (msdev::Maybe M0.SDev) = msdev >>= \sdev ->
                 let st = M0.getState sdev rg
                 in if st == M0.SDSOnline
                    then Nothing
                    else Just (sdev, st)
            devs <- fmap (\x -> mapMaybe go x) . traverse lookupStorageDeviceSDev
                      =<< findHostStorageDevices host
            return (host, ReportClusterHost node_st (join prs) devs)
      liftProcess $ sendChan ch $ ReportClusterState
        { csrStatus = status
        , csrSNS    = repairs
        , csrInfo   = (liftA2 (,) profile filesystem)
        , csrHosts  = hosts
        }
      messageProcessed eid

-- | Request cluster to bootstrap.
requestClusterStart :: Definitions LoopState ()
requestClusterStart = defineSimple "castor::cluster::request::start"
  $ \(HAEvent eid (ClusterStartRequest ch) _) -> do
      rg <- getLocalGraph
      fs <- getFilesystem
      let eresult = case (fs, listToMaybe $ G.connectedTo R.Cluster R.Has rg) of
            (Nothing, _) -> Left $ StateChangeError "Initial data not loaded."
            (_, Nothing) -> Left $ StateChangeError "Unknown current state."
            (_, Just st) -> case st of
               M0.MeroClusterStopped    -> Right $ do
                  -- Randomly select principal RM, it may be switched if another
                  -- RM will appear online before this one.
                  let pr = [ ps
                           | prf :: M0.Profile <- G.connectedTo R.Cluster R.Has rg
                           , fsm :: M0.Filesystem <- G.connectedTo prf M0.IsParentOf rg
                           , nd :: M0.Node <- G.connectedTo fsm M0.IsParentOf rg
                           , ps :: M0.Process <- G.connectedTo nd M0.IsParentOf rg
                           , sv :: M0.Service <- G.connectedTo ps M0.IsParentOf rg
                           , M0.s_type sv == CST_MGS
                           ]
                  let rms = listToMaybe [ srv
                                        | p <- pr
                                        , srv :: M0.Service <- G.connectedTo p M0.IsParentOf rg
                                        , M0.s_type srv == CST_RMS
                                        ]
                  traverse_ setPrincipalRMIfUnset rms
                  modifyGraph $ G.connectUnique R.Cluster R.Has (M0.MeroClusterStarting (M0.BootLevel 0))
                  announceMeroNodes

                  registerSyncGraphCallback $ \pid proc -> do
                    sendChan ch (StateChangeStarted pid)
                    proc eid
               M0.MeroClusterStarting{} -> Left $ StateChangeOngoing st
               M0.MeroClusterStopping{} -> Left $ StateChangeError $ "cluster is stopping: " ++ show st
               M0.MeroClusterFailed -> Left $ StateChangeError $ "cluster is failed: " ++ show st
               M0.MeroClusterRunning    -> Left $ StateChangeFinished
      case eresult of
        Left m -> liftProcess (sendChan ch m) >> messageProcessed eid
        Right action -> action

-- | Request cluster to teardown.
--   If the cluster is already tearing down, or is starting, this
--   rule will do nothing.
--   Sends 'StopProcessesOnNodeRequest' to all nodes.
--   TODO: Does this include stopping clients on the nodes?
requestClusterStop :: Definitions LoopState ()
requestClusterStop = defineSimple "castor::cluster::request::stop"
  $ \(HAEvent eid (ClusterStopRequest ch) _) -> do
      rg <- getLocalGraph
      let eresult = case listToMaybe $ G.connectedTo R.Cluster R.Has rg of
            Nothing -> Left $ StateChangeError "Unknown current state."
            Just st -> case st of
               M0.MeroClusterRunning    -> Right $ stopCluster rg ch eid
               M0.MeroClusterFailed     -> Right $ stopCluster rg ch eid
               M0.MeroClusterStopping{} -> Left $ StateChangeOngoing st
               M0.MeroClusterStarting{} -> Left $ StateChangeError $ "cluster is starting: " ++ show st
               M0.MeroClusterStopped    -> Left   StateChangeFinished
      case eresult of
        Left m -> liftProcess (sendChan ch m) >> messageProcessed eid
        Right action -> action
  where
    stopCluster rg ch eid = do
      modifyGraph $ G.connectUnique R.Cluster R.Has (M0.MeroClusterStopping (M0.BootLevel maxTeardownLevel))
      let nodes =
            [ node | host <- G.connectedTo R.Cluster R.Has rg :: [R.Host]
                   , node <- take 1 (G.connectedTo host R.Runs rg) :: [M0.Node] ]
      for_ nodes $ promulgateRC . StopProcessesOnNodeRequest
      registerSyncGraphCallback $ \pid proc -> do
        sendChan ch (StateChangeStarted pid)
        proc eid

-- | Stop m0t1fs service with given fid.
--   This may be triggered by the user using halonctl.
--
--   Sends 'StopProcessesRequest' which has an explicit
--   list of Processes.
--
-- 1. we check if there is halon:m0d service on the node
-- 2. find if there is m0t1fs service with a given fid
requestStopMeroClient :: Definitions LoopState ()
requestStopMeroClient = defineSimpleTask "castor::cluster::client::request::stop" $ \(StopMeroClientRequest fid) -> do
  phaseLog "info" $ "Stop mero client " ++ show fid ++ " requested."
  mnp <- runMaybeT $ do
    proc <- MaybeT $ lookupConfObjByFid fid
    node <- MaybeT $ getLocalGraph
                  <&> listToMaybe . G.connectedFrom M0.IsParentOf proc
    return (node, proc)
  forM_ mnp $ \(node, proc) -> do
    rg <- getLocalGraph
    if G.isConnected proc R.Has M0.PLM0t1fs rg
    then promulgateRC $ StopProcessesRequest node [proc]
    else phaseLog "warning" $ show fid ++ " is not a client process."

-- | Start already existing (in confd) mero client.
-- 1. Checks if client exists in database
-- 2. Tries to start a client by calling `startMeroProcesses`
requestStartMeroClient :: Definitions LoopState ()
requestStartMeroClient = defineSimpleTask "castor::cluser::client::request::start" $ \(StartMeroClientRequest fid) -> do
  phaseLog "info" $ "Stop mero client " ++ show fid ++ " requested."
  mproc <- lookupConfObjByFid fid
  forM_ mproc $ \proc -> do
    rg <- getLocalGraph
    if G.isConnected proc R.Has M0.PLM0t1fs rg
    then do
      let nodes = [node | m0node <- G.connectedFrom M0.IsParentOf proc rg
                        , node   <- m0nodeToNode m0node rg
                        ]
      m0svc <- runMaybeT $ asum
               $ map (\node -> MaybeT $ lookupRunningService node m0d) nodes
      case m0svc >>= meroChannel rg of
        Just chan -> do
           phaseLog "info" $ "Starting client"
           -- TODO switch to 'StartProcessesRequest' (HALON-373)
           configureMeroProcesses chan [proc] M0.PLM0t1fs False
           startMeroProcesses chan [proc] M0.PLM0t1fs
        Nothing -> phaseLog "warning" $ "can't find mero channel."
    else phaseLog "warning" $ show fid ++ " is not a client process."
