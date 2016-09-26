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
      ( findHostStorageDevices, findStorageDeviceIdentifiers )
import           HA.RecoveryCoordinator.Actions.Castor.Cluster
     ( notifyOnClusterTransition )
import           HA.RecoveryCoordinator.Events.Castor.Cluster
import           HA.RecoveryCoordinator.Events.Mero
import           HA.RecoveryCoordinator.Rules.Mero.Conf
     ( applyStateChanges
     , setPhaseNotified
     )
import           HA.RecoveryCoordinator.Actions.Job
import           HA.Services.Mero.RC (meroChannel)
import           Mero.ConfC (ServiceType(..))
import           Network.CEP

import           Control.Applicative
import           Control.Category
import           Control.Distributed.Process hiding (catch, try)
import           Control.Lens
import           Control.Monad (join, unless, when)
import           Control.Monad.Trans.Maybe
import           Control.Monad.Trans.State (execState)
import qualified Control.Monad.Trans.State as State

import           Data.List ((\\))
import           Data.Maybe (catMaybes, listToMaybe, mapMaybe, isJust)
import           Data.Foldable
import           Data.Traversable (forM)
import           Data.Typeable
import           Data.Vinyl
import qualified Data.Set as Set

import           Prelude hiding ((.), id)

-- | All the rules that are required for cluster start.
clusterRules :: Definitions LoopState ()
clusterRules = sequence_
  [ requestClusterStatus
  , ruleClusterStart
  , requestClusterStop
  , requestStartMeroClient
  , requestStopMeroClient
  , eventAdjustClusterState
  , eventUpdatePrincipalRM
  , eventNodeFailedStart
  , ruleServiceNotificationHandler
  , requestClusterReset
  , ruleMarkProcessesBootstrapped
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
      _ -> phaseLog "error" $ "Kernel module failed to start."
      -- _ -> do modifyGraph $ G.connectUnique R.Cluster R.Has M0.MeroClusterFailed
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
ruleServiceNotificationHandler = define "castor::service::notification-handler" $ do
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
     phaseLog "begin" "Service transition"
     phaseLog "info" $ "transaction.id = " ++ show eid
     phaseLog "info" $ "service.fid    = " ++ show (M0.fid service)
     phaseLog "info" $ "service.state  = " ++ show st
     phaseLog "info" $ "service.type   = " ++ show typ -- XXX: remove
     put Local $ Just (eid, Just (service, st), Nothing)
     applyStateChanges [stateSet service st]
     switch [service_notified, timeout 30 timed_out]

   setPhaseNotified service_notified viewSrv $ \(srv, st) -> do
     rg <- getLocalGraph
     let mproc = listToMaybe $ G.connectedFrom M0.IsParentOf srv rg :: Maybe M0.Process
     Just (eid, _, _) <- get Local
     phaseLog "action" $ "Check if all services for process are online"
     phaseLog "info" $ "transaction.id = " ++ show eid
     phaseLog "info" $ "process.fid = " ++ show (fmap M0.fid mproc)
     -- find the process, the service belongs to, check if all
     -- services are online, if yes then update process state and
     -- notify barrier
     case (st, mproc) of
       (M0.SSOnline, Just (p :: M0.Process)) -> do
         let allSrvs :: [M0.Service]
             allSrvs = G.connectedTo p M0.IsParentOf rg
             onlineSrvs = [ s | s <- allSrvs
                              , M0.SSOnline <- G.connectedTo s R.Is rg ]
             newProcessState = M0.PSOnline

         put Local $ Just (eid, Just (srv, st), Just (p, newProcessState))
         if length allSrvs == length onlineSrvs
         then do phaseLog "info" "all services online -> marking process as online" -- XXX: move to process rule.
                 -- TODO: maybe we should not notify here but instead
                 -- notify after mero itself sends the process
                 -- notification
                 applyStateChanges [stateSet p newProcessState]
                 switch [process_notified, timeout 30 timed_out]
         else do phaseLog "info" $ "waiting for = " ++ show (map M0.fid $ allSrvs \\ onlineSrvs)
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
     Just (eid, srvi, _) <- get Local
     phaseLog "info" $ "transaction.eid = " ++ show eid
     phaseLog "info" $ "process.fid    = " ++ show (M0.fid p)
     phaseLog "info" $ "process.status = " ++ show pst
     rg <- getLocalGraph
     when (G.isConnected R.Cluster R.Has M0.OFFLINE rg) $
      phaseLog "warn" $
         unwords [ "Received service start notification about", show srvi
                 , "but cluster disposition is OFFLINE" ]
     continue finish

   directly timed_out $ do
     phaseLog "warn" $ "Waited too long for a notification ack"
     continue finish

   directly finish $ get Local >>= \case
       Just (eid, _, _) -> do
         done eid
         phaseLog "info" $ "transaction.idg = " ++ show eid
         phaseLog "end" "Service transition."
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
eventAdjustClusterState = defineSimpleTask "castor::cluster::event::update-cluster-state"
  $ \msg -> do
    let findChanges = do -- XXX: move to the common place
          InternalObjectStateChange chs <- liftProcess $ decodeP msg
          return $ mapMaybe (\(AnyStateChange (a :: a) _old _new _) ->
                       case eqT :: Maybe (a Data.Typeable.:~: M0.Process) of
                         Just Refl -> Just a
                         Nothing   -> Nothing) chs
    procChanges :: [M0.Process] <- findChanges
    unless (null procChanges) $ do
      phaseLog "debug" $ "Process changes:" ++ show (map M0.fid procChanges)
      notifyOnClusterTransition Nothing

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
      let status = getClusterStatus rg
          stats = filesystem >>= \fs -> listToMaybe $ G.connectedTo fs R.Has rg
      hosts <- forM (G.connectedTo R.Cluster R.Has rg) $ \host -> do
            let nodes = G.connectedTo host R.Runs rg :: [M0.Node]
            let node_st = maybe M0.NSUnknown (flip M0.getState rg) $ listToMaybe nodes
            prs <- forM nodes $ \node -> do
                     processes <- getChildren node
                     forM processes $ \process -> do
                       let st = M0.getState process rg
                       services <- getChildren process
                       let services' = map (\srv -> (srv, M0.getState srv rg)) services
                       return (process, ReportClusterProcess st services')
            let go ( hdev :: R.StorageDevice
                    , ids :: [R.DeviceIdentifier]
                    , msdev :: Maybe M0.SDev)
                  = (\sdev -> (sdev, M0.getState sdev rg, hdev, ids)) <$> msdev
            devs <- fmap (mapMaybe go)
                  . traverse (\x -> (x,,) <$> findStorageDeviceIdentifiers x
                                          <*> lookupStorageDeviceSDev x)
                    =<< findHostStorageDevices host
            return (host, ReportClusterHost (listToMaybe nodes) node_st (join prs) devs)
      liftProcess $ sendChan ch $ ReportClusterState
        { csrStatus = status
        , csrSNS    = repairs
        , csrInfo   = (liftA2 (,) profile filesystem)
        , csrStats  = stats
        , csrHosts  = hosts
        }
      messageProcessed eid

-- | Timeout for cluster start rule
cluster_start_timeout :: Int
cluster_start_timeout = 10*60 -- 10m

jobClusterStart :: Job ClusterStartRequest ClusterStartResult
jobClusterStart = Job "castor::cluster::start"

-- | Mark all processes as finished mkfs.
--
-- This will make halon to skip mkfs step.
--
-- Note: This rule should be used with great care as if configuration data has
-- changed, or mkfs have not been completed, this call could put cluster into
-- a bad state.
ruleMarkProcessesBootstrapped :: Definitions LoopState ()
ruleMarkProcessesBootstrapped = defineSimpleTask "castor::server::mark-all-process-bootstrapped" $
  \(MarkProcessesBootstrapped ch) -> do
     rg <- getLocalGraph
     let procs = [ m0proc
                 | m0prof <- G.connectedTo R.Cluster R.Has rg :: [M0.Profile]
                 , m0fs   <- G.connectedTo m0prof M0.IsParentOf rg :: [M0.Filesystem]
                 , m0node <- G.connectedTo m0fs M0.IsParentOf rg :: [M0.Node]
                 , m0proc <- G.connectedTo m0node M0.IsParentOf rg :: [M0.Process]
                 ]
     modifyGraph $ execState $ do
       for_ procs $ \p -> State.modify (G.connect p R.Is M0.ProcessBootstrapped)
     registerSyncGraph $ do
       sendChan ch ()

-- | Statup a node in cluster.
--
-- Firt requests to start mero services on all nodes.
-- Once all nodes replied with exiter success failure or internal timeout -
-- either report a failure or start clients in case if everything is ok.
--
-- Nested jobs:
--   - 'processStartProcessesOnNode' - start all server processes on node
--   - 'processStartClientsOnNode'   - start all m0t1fs mounts on node
--
ruleClusterStart :: Definitions LoopState ()
ruleClusterStart = mkJobRule jobClusterStart args $ \finalize -> do
    wait_server_jobs  <- phaseHandle "wait_server_jobs"
    start_client_jobs <- phaseHandle "start_client_jobs"
    wait_client_jobs  <- phaseHandle "wait_client_jobs"
    job_timeout       <- phaseHandle "job_timeout"

    let getMeroHostsNodes p = do
         rg <- getLocalGraph
         return [ (host,node)
                | host <- G.connectedTo R.Cluster R.Has rg  :: [R.Host]
                , node <- G.connectedTo host R.Runs rg :: [M0.Node]
                , p host node rg
                ]

    let appendServerFailure s =
           modify Local $ rlens fldRep . rfield %~
             (\x -> Just $ case x of
                 Just (ClusterStartFailure n xs ys) -> ClusterStartFailure n (s:xs) ys
                 Just ClusterStartTimeout -> ClusterStartFailure "server start failure" [s] []
                 _ -> ClusterStartFailure "server start failure" [s] [])

    let appendClientFailure s =
           modify Local $ rlens fldRep . rfield %~
             (\x -> Just $ case x of
                 Just (ClusterStartFailure n xs ys) -> ClusterStartFailure n xs (s:ys)
                 Just ClusterStartTimeout -> ClusterStartFailure "client start failure" [] [s]
                 _ -> ClusterStartFailure "client start failure" [] [s])

    let fail_job st = do
          modify Local $ rlens fldRep . rfield .~ Just st
          return $ Just [finalize]
        start_job = do
          rg <- getLocalGraph
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
          traverse_ setPrincipalRMIfUnset $
            listToMaybe [ srv
                        | p <- pr
                        , srv :: M0.Service <- G.connectedTo p M0.IsParentOf rg
                        , M0.s_type srv == CST_RMS
                        ]
          -- Update cluster disposition
          phaseLog "update" $ "cluster.disposition=ONLINE"
          modifyGraph $ G.connectUnique R.Cluster R.Has (M0.ONLINE)
          servers <- fmap (map snd) $ getMeroHostsNodes
            $ \(host::R.Host) (node::M0.Node) rg -> G.isConnected host R.Has R.HA_M0SERVER rg
                            && M0.getState node rg /= M0.NSFailed
                            && M0.getState node rg /= M0.NSFailedUnrecoverable
          for_ servers $ \s -> do
            phaseLog "debug" $ "starting server processes on node=" ++ M0.showFid s
            promulgateRC $ StartProcessesOnNodeRequest s
          modify Local $ rlens fldNodes . rfield .~ Set.fromList servers
          modify Local $ rlens fldNext  . rfield .~ Just start_client_jobs
          return $ Just [wait_server_jobs, timeout cluster_start_timeout job_timeout]

    let route ClusterStartRequest{} = getFilesystem >>= \case
          Nothing -> fail_job $ ClusterStartFailure "Initial data not loaded." [] []
          Just _ -> do
            rg <- getLocalGraph
            case getClusterStatus rg of
              Nothing -> do
                phaseLog "error" "graph invariant violation: cluster have no attached state"
                fail_job $ ClusterStartFailure "Unknown cluster state." [] []
              Just _ -> if isClusterStopped rg
                        then start_job
                        else fail_job $ ClusterStartFailure "Cluster not fully stopped." [] []

    setPhase wait_server_jobs $ \s -> do
       servers <- getField . rget fldNodes <$> get Local
       (node, result) <- case s of
         NodeProcessesStarted node ->
           return (node, "success")
         s@(NodeProcessesStartTimeout node) -> do
           modify Local $ rlens fldNext . rfield .~ Just finalize
           appendServerFailure s
           return (node, "timeout")
         s@(NodeProcessesStartFailure node) -> do
           modify Local $ rlens fldNext . rfield .~ Just finalize
           appendServerFailure s
           return (node, "failure")
       phaseLog "job finished" $ "node=" ++ M0.showFid node
       phaseLog "job finished" $ "result=" ++ result
       let servers' = Set.delete node servers
       modify Local $ rlens fldNodes . rfield .~ servers'
       if Set.null servers'
       then do Just next <- getField . rget fldNext <$> get Local
               switch [next, timeout cluster_start_timeout job_timeout]
       else switch [wait_server_jobs, timeout cluster_start_timeout job_timeout]

    directly start_client_jobs $ do
       clients <- fmap (map snd) $ getMeroHostsNodes
            $ \(host::R.Host) (node::M0.Node) rg -> (G.isConnected host R.Has R.HA_M0CLIENT rg
                               || G.isConnected host R.Has R.HA_M0SERVER rg) -- XXX on devvm node do not have client label
                            && M0.getState node rg /= M0.NSFailed
                            && M0.getState node rg /= M0.NSFailedUnrecoverable
       case clients of
         [] -> do modify Local $ rlens fldRep . rfield .~ Just ClusterStartOk
                  continue finalize
         _  -> do
            for_ clients $ \s -> do
               phaseLog "debug" $ "starting client processes on node=" ++ M0.showFid s
               promulgateRC $ StartClientsOnNodeRequest s
            modify Local $ rlens fldNodes . rfield .~ Set.fromList clients
            continue wait_client_jobs

    setPhase wait_client_jobs $ \s -> do
       clients <- getField . rget fldNodes <$> get Local
       (node,result) <- case s of
         ClientsStartOk node ->
           return (node, "success")
         ClientsStartTimeout node -> do
           appendClientFailure s
           return (node, "timeout")
         ClientsStartFailure node _ -> do
           appendClientFailure s
           return (node, "failure")
       phaseLog "job finished" $ "node=" ++ M0.showFid node
       phaseLog "job finished" $ "result=" ++ result
       let clients' = Set.delete node clients
       modify Local $ rlens fldNodes . rfield .~ clients'
       if Set.null clients'
       then do
         modify Local $ rlens fldRep . rfield .~ Just ClusterStartOk
         continue finalize
       else switch [wait_client_jobs, timeout cluster_start_timeout job_timeout]

    directly job_timeout $ do
       modify Local $ rlens fldRep . rfield .~ Just ClusterStartTimeout
       continue finalize

    return route
  where
    fldReq :: Proxy '("request", Maybe ClusterStartRequest)
    fldReq = Proxy
    fldRep :: Proxy '("reply", Maybe ClusterStartResult)
    fldRep = Proxy
    fldNodes :: Proxy '("nodes", Set.Set M0.Node)
    fldNodes = Proxy
    fldNext :: Proxy '("next", Maybe (Jump PhaseHandle))
    fldNext = Proxy
    -- Notifications to wait for
    args = fldUUID =: Nothing
       <+> fldReq  =: Nothing
       <+> fldRep  =: Nothing
       <+> fldNodes =: Set.empty
       <+> fldNext  =: Nothing
       <+> RNil

-- | Request cluster to teardown.
--   Immediately set cluster disposition to OFFLINE.
--   If the cluster is already tearing down, or is starting, this
--   rule will do nothing.
--   Sends 'StopProcessesOnNodeRequest' to all nodes.
--   TODO: Does this include stopping clients on the nodes?
requestClusterStop :: Definitions LoopState ()
requestClusterStop = defineSimple "castor::cluster::request::stop"
  $ \(HAEvent eid (ClusterStopRequest ch) _) -> do
      rg <- getLocalGraph
      let eresult = if isClusterStopped rg
                    then Left StateChangeFinished
                    else Right $ stopCluster rg ch eid
      case eresult of
        Left m -> liftProcess (sendChan ch m) >> messageProcessed eid
        Right action -> action
  where
    stopCluster rg ch eid = do
      -- Set disposition to OFFLINE
      modifyGraph $ G.connectUniqueFrom R.Cluster R.Has (M0.OFFLINE)
      let nodes =
            [ node | host <- G.connectedTo R.Cluster R.Has rg :: [R.Host]
                   , node <- take 1 (G.connectedTo host R.Runs rg) :: [M0.Node] ]
      for_ nodes $ promulgateRC . StopProcessesOnNodeRequest
      registerSyncGraphCallback $ \pid proc -> do
        sendChan ch (StateChangeStarted pid)
        proc eid

-- | Reset the (mero) cluster. This should be used when something
--   has gone wrong and we cannot restore the cluster to ground
--   state under normal operation.
--
--   There are two 'levels' of reset. The first level will simply
--   revert the status of all Mero processes and services to 'Unknown'.
--   The second level will also purge all messages from the EQ and restart
--   the recovery co-ordinator. Note that this should only be done if the
--   cluster is in a 'steady state', which is to say there are no running
--   SMs and all 'midway' suspended SMs have timed out.
requestClusterReset :: Definitions LoopState ()
requestClusterReset = defineSimple "castor::cluster::reset"
  $ \(HAEvent eid (ClusterResetRequest deepReset) _) -> do
    phaseLog "info" "Cluster reset requested."
    -- Mark all processes and services as unknown.
    procs <- getLocalGraph <&> M0.getM0Processes
    srvs <- getLocalGraph <&> \rg -> join
      $ (\p -> G.connectedTo p M0.IsParentOf rg :: [M0.Service])
      <$> procs
    modifyGraph $ foldl' (.) id (flip M0.setState M0.SSUnknown <$> srvs)
    modifyGraph $ foldl' (.) id (flip M0.setState M0.PSUnknown <$> procs)
    if deepReset
    then do
      syncGraphBlocking
      phaseLog "info" "Clearing event queue."
      self <- liftProcess $ getSelfPid
      eqPid <- lsEQPid <$> get Global
      liftProcess $ usend eqPid (DoClearEQ self)
      -- Actually properly block the RC here - we do not want to allow
      -- other events to occur in the meantime.
      msg <- liftProcess $ expectTimeout (1*1000000) -- 1s
      case msg of
        Just DoneClearEQ -> phaseLog "info" "EQ cleared"
        Nothing -> do
          phaseLog "error" "Unable to clear the EQ!"
          -- Attempt to ack this message to avoid a reset loop
          messageProcessed eid
      -- Reset the recovery co-ordinator
      error "User requested `cluster reset --hard`"
    else
      messageProcessed eid

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
  phaseLog "info" $ "Start mero client " ++ show fid ++ " requested."
  mproc <- lookupConfObjByFid fid
  forM_ mproc $ \proc -> do
    rg <- getLocalGraph
    if G.isConnected proc R.Has M0.PLM0t1fs rg
    then do
      let chans = [ch | m0node <- G.connectedFrom M0.IsParentOf proc rg
                      , node   <- m0nodeToNode m0node rg
                      , Just ch <- return $ meroChannel rg node
                      ]
      case listToMaybe chans of
        Just chan -> do
           phaseLog "info" $ "Starting client"
           -- TODO switch to 'StartProcessesRequest' (HALON-373)
           configureMeroProcesses chan [proc] M0.PLM0t1fs False
           startMeroProcesses chan [proc] M0.PLM0t1fs
        Nothing -> phaseLog "warning" $ "can't find mero channel."
    else phaseLog "warning" $ show fid ++ " is not a client process."
