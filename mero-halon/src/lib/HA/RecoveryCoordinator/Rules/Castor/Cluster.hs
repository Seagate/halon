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
{-# LANGUAGE ScopedTypeVariables   #-}
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

import qualified HA.ResourceGraph as G
import           HA.RecoveryCoordinator.Actions.Core
import           HA.RecoveryCoordinator.Actions.Hardware
      ( findHostStorageDevices, findStorageDeviceIdentifiers )
import           HA.RecoveryCoordinator.Actions.Castor.Cluster
     ( notifyOnClusterTransition )
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Actions.Mero.Node
import           HA.RecoveryCoordinator.Events.Castor.Cluster
import           HA.RecoveryCoordinator.Events.Mero
import           HA.RecoveryCoordinator.Rules.Mero.Conf (applyStateChanges)
import           HA.RecoveryCoordinator.Job.Actions
import           HA.Services.Mero.RC (meroChannel)
import           Mero.ConfC (ServiceType(..))
import           Network.CEP

import           Control.Applicative
import           Control.Category
import           Control.Distributed.Process hiding (catch, try)
import           Control.Exception (SomeException)
import           Control.Lens
import           Control.Monad (join, unless, when)
import           Control.Monad.Catch (try)
import           Control.Monad.Trans.Maybe
import           Control.Monad.Trans.State (execState)
import qualified Control.Monad.Trans.State as State

import           Data.Maybe ( catMaybes, listToMaybe, maybeToList, mapMaybe
                            , isJust, isNothing
                            )
import           Data.Ratio
import           Data.Foldable
import qualified Data.Map.Strict as M
import           Data.Traversable (forM)
import           Data.Typeable
import           Data.Vinyl hiding ((:~:))
import qualified Data.Set as Set
import           Text.Printf (printf)

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
  , requestClusterReset
  , ruleMarkProcessesBootstrapped
  , ruleClusterMonitorStop
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
          return $ mapMaybe (\(AnyStateChange (a :: a) old new _) ->
                       case eqT :: Maybe (a Data.Typeable.:~: M0.Process) of
                         Just Refl -> Just (a, old, new)
                         Nothing   -> Nothing) chs
        formatProcess :: (M0.Process, M0.ProcessState, M0.ProcessState) -> String
        formatProcess (p, o, n) = printf "%s: %s -> %s" (show $ M0.fid p) (show o) (show n)
    procChanges <- findChanges
    unless (null procChanges) $ do
      phaseLog "debug" $ "Process changes: " ++ show (map formatProcess procChanges)
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
          stats = filesystem >>= \fs -> G.connectedTo fs R.Has rg
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
     let procs =
           [ m0proc
           | Just (m0prof :: M0.Profile) <- [G.connectedTo R.Cluster R.Has rg]
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

    let appendServerFailure s = do
           modify Local $ rlens fldRep . rfield %~
             (\x -> Just $ case x of
                 Just (ClusterStartFailure n xs ys) -> ClusterStartFailure n (s:xs) ys
                 Just ClusterStartTimeout{} -> ClusterStartFailure "server start failure" [s] []
                 _ -> ClusterStartFailure "server start failure" [s] [])

    let appendClientFailure s =
           modify Local $ rlens fldRep . rfield %~
             (\x -> Just $ case x of
                 Just (ClusterStartFailure n xs ys) -> ClusterStartFailure n xs (s:ys)
                 Just ClusterStartTimeout{} -> ClusterStartFailure "client start failure" [] [s]
                 _ -> ClusterStartFailure "client start failure" [] [s])

    let fail_job st = do
          modify Local $ rlens fldRep . rfield .~ Just st
          return $ Just [finalize]
        start_job = do
          rg <- getLocalGraph
          -- Randomly select principal RM, it may be switched if another
          -- RM will appear online before this one.
          let pr = [ ps
                   | Just (prf :: M0.Profile) <- [G.connectedTo R.Cluster R.Has rg]
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
          modifyGraph $ G.connect R.Cluster R.Has (M0.ONLINE)
          servers <- fmap (map snd) $ getMeroHostsNodes
            $ \(host::R.Host) (node::M0.Node) rg' -> G.isConnected host R.Has R.HA_M0SERVER rg'
                            && M0.getState node rg' /= M0.NSFailed
                            && M0.getState node rg' /= M0.NSFailedUnrecoverable
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
       (node, result) <- case s of
         NodeProcessesStarted node ->
           return (node, "success")
         s'@(NodeProcessesStartTimeout node _) -> do
           modify Local $ rlens fldNext . rfield .~ Just finalize
           appendServerFailure s'
           return (node, "timeout")
         s'@(NodeProcessesStartFailure node _) -> do
           modify Local $ rlens fldNext . rfield .~ Just finalize
           appendServerFailure s'
           return (node, "failure")
       servers <- getField . rget fldNodes <$> get Local
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
       rg <- getLocalGraph
       let status = [ (n, ps) | h :: R.Host <- G.connectedTo R.Cluster R.Has rg
                              , n <- G.connectedTo h R.Runs rg
                              , let ps = getUnstartedProcesses n rg
                              , not $ null ps ]

       modify Local $ rlens fldRep . rfield .~ Just (ClusterStartTimeout status)
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
      modifyGraph $ G.connect R.Cluster R.Has (M0.OFFLINE)
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
    -- Mark all nodes, processes and services as unknown.
    nodes <- getLocalGraph <&> \rg -> [ node
              | host <- G.connectedTo R.Cluster R.Has rg :: [R.Host]
              , node <- take 1 (G.connectedTo host R.Runs rg) :: [M0.Node]
              ]
    procs <- getLocalGraph <&> M0.getM0Processes
    srvs <- getLocalGraph <&> \rg -> join
      $ (\p -> G.connectedTo p M0.IsParentOf rg :: [M0.Service])
      <$> procs
    modifyGraph $ foldl' (.) id (flip M0.setState M0.NSUnknown <$> nodes)
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
                  <&> G.connectedFrom M0.IsParentOf proc
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
      let chans = [ch | Just m0node <- [G.connectedFrom M0.IsParentOf proc rg]
                      , node   <- m0nodeToNode m0node rg
                      , Just ch <- return $ meroChannel rg node
                      ]
      case listToMaybe chans of
        Just chan -> do
           phaseLog "info" $ "Starting client"
           -- TODO switch to 'StartProcessesRequest' (HALON-373)
           eresult <- try $ configureMeroProcesses chan [proc] M0.PLM0t1fs False
           case eresult of
             Left e -> do phaseLog "error" "Exception during client start."
                          phaseLog "text" $ show (e :: SomeException)
             Right _ -> startMeroProcesses chan [proc] M0.PLM0t1fs
        Nothing -> phaseLog "warning" $ "can't find mero channel."
    else phaseLog "warning" $ show fid ++ " is not a client process."

-- | Caller 'ProcessId' signals that it's interested in cluster
-- stopping ('MonitorClusterStop') and wants to receive information
-- about it. The idea behind this rule is that it passively (i.e.
-- without actually invoking any cluster-changing actions itself)
-- monitors events relevant to cluster stopping that are flying by and
-- reports progress back to the caller. The caller can choose to block
-- until it's satisfied, report to the user with progress and so on.
ruleClusterMonitorStop :: Definitions LoopState ()
ruleClusterMonitorStop = define "castor::cluster::stop::monitoring" $ do
  start_monitoring <- phaseHandle "start-monitoring"
  caller_died <- phaseHandle "caller-died"
  isc_watcher <- phaseHandle "internal-state-change-watcher"
  cluster_level_watcher <- phaseHandle "cluster-level-watcher"
  finish <- phaseHandle "finish"

  let watchForChanges = switch [caller_died, isc_watcher, cluster_level_watcher]

  setPhase start_monitoring $ \(HAEvent uuid (MonitorClusterStop caller) _) -> do
    todo uuid
    st <- calculateStoppingState
    mref <- liftProcess $ monitor caller
    modify Local $ rlens fldCallerPid . rfield .~ Just caller
    modify Local $ rlens fldClusterStopProgress . rfield .~ Just st
    modify Local $ rlens fldUUID . rfield .~ Just uuid
    modify Local $ rlens fldMonitorRef . rfield .~ Just mref
    watchForChanges

  setPhaseIf isc_watcher iscGuard $ \() -> do
    notifyCallerWithDiff finish
    watchForChanges

  setPhase cluster_level_watcher $ \ClusterStateChange{} -> do
    notifyCallerWithDiff finish
    watchForChanges

  setPhaseIf caller_died monitorGuard $ \() -> do
    caller <- getField . rget fldCallerPid <$> get Local
    phaseLog "info" "Calling process died: did user ^C?"
    phaseLog "caller.ProcessId" $ show caller
    continue finish

  directly finish $ do
    getField . rget fldMonitorRef <$> get Local >>= \case
      Nothing -> phaseLog "warn" "No monitor ref"
      Just mref -> liftProcess $ unmonitor mref
    getField . rget fldUUID <$> get Local >>= \case
      Nothing -> phaseLog "warn" "No UUID"
      Just uuid -> done uuid

  startFork start_monitoring args
  where
    fldCallerPid :: Proxy '("caller-pid", Maybe ProcessId)
    fldCallerPid = Proxy
    fldClusterStopProgress :: Proxy '("cluster-stop-progress", Maybe ClusterStoppingState)
    fldClusterStopProgress = Proxy
    fldMonitorRef :: Proxy '("monitor-ref", Maybe MonitorRef)
    fldMonitorRef = Proxy

    args = fldCallerPid =: Nothing
       <+> fldClusterStopProgress =: Nothing
       <+> fldMonitorRef =: Nothing
       <+> fldUUID =: Nothing

    -- Look for any service or process notification. If things are
    -- going wrong with processes transitioning out of offline, this
    -- gives us a chance to notify the user about it.
    --
    -- We check if the transitions are interesting early on: it may
    -- just be process going from online to to quescing which we don't
    -- care about for stop purposes so we save ourselves work and
    -- empty sends.
    iscGuard :: HAEvent InternalObjectStateChangeMsg -> g -> l -> Process (Maybe ())
    iscGuard (HAEvent _ msg _) _ _ = decodeP msg >>= \(InternalObjectStateChange iosc) ->
      let isInteresting :: forall t. Typeable t
                        => (t -> M0.StateCarrier t -> M0.StateCarrier t -> Bool)
                        -> AnyStateChange -> Bool
          isInteresting p (AnyStateChange (obj :: t') o n _) =
            case eqT :: Maybe (t :~: t') of
              Just Refl -> p obj o n
              _ -> False
          interestingServ :: M0.Service -> M0.ServiceState -> M0.ServiceState -> Bool
          interestingServ obj o n = isJust $ servTransitioned obj o n
          interestingProc :: M0.Process -> M0.ProcessState -> M0.ProcessState -> Bool
          interestingProc obj o n = isJust $ procTransitioned obj o n
      in if any (\c -> isInteresting interestingServ c || isInteresting interestingProc c) iosc
         then return $ Just ()
         else return Nothing

    monitorGuard :: forall g l s. ( '("monitor-ref", Maybe MonitorRef) ∈ s
                                  , l ~ Rec ElField s )
                 => ProcessMonitorNotification -> g -> l -> Process (Maybe ())
    monitorGuard (ProcessMonitorNotification mref _ _) _ l =
      return $ case getField $ rget fldMonitorRef l of
        Just mref' | mref == mref' -> Just ()
        _ -> Nothing

    notifyCallerWithDiff finish = do
      newSt <- calculateStoppingState
      moldSt <- getField . rget fldClusterStopProgress <$> get Local
      mcaller <- getField . rget fldCallerPid <$> get Local
      modify Local $ rlens fldClusterStopProgress . rfield .~ Just newSt
      case (moldSt, mcaller) of
        (Nothing, _) -> do
          phaseLog "warn" "No previous cluster state known (‘impossible’)"
          continue finish
        (_, Nothing) -> do
          phaseLog "warn" "No caller known (‘impossible’)"
          continue finish
        (Just oldSt, Just caller) -> do
          let diff = calculateStopDiff oldSt newSt
          when (not $ isEmptyDiff diff) $ do
            liftProcess $ usend caller diff
            when (_csp_cluster_stopped diff) $ continue finish

    calculateStoppingState :: PhaseM LoopState l ClusterStoppingState
    calculateStoppingState = do
      rg <- getLocalGraph
      let ps = [ (p, M0.getState p rg)
               | Just (pr :: M0.Profile) <- [G.connectedTo R.Cluster R.Has rg]
               , fs :: M0.Filesystem <- G.connectedTo pr M0.IsParentOf rg
               , mn :: M0.Node <- G.connectedTo fs M0.IsParentOf rg
               , p  :: M0.Process  <- G.connectedTo mn M0.IsParentOf rg ]
          donePs = filter ((== M0.PSOffline) . snd) ps
          svs = [ (s, M0.getState s rg)
                | (p, _) <- ps
                , s :: M0.Service <- G.connectedTo p M0.IsParentOf rg  ]
          doneSvs = filter ((== M0.SSOffline) . snd) svs

          disp :: [M0.Disposition]
          disp = maybeToList $ G.connectedTo R.Cluster R.Has rg
          doneDisp = filter (== M0.OFFLINE) disp

          allParts = toInteger $ length ps + length svs + length disp
          doneParts = toInteger $ length donePs + length doneSvs + length doneDisp

          progress :: Rational
          progress = (100 % allParts) * (doneParts % 1)

          allDone = allParts == doneParts
      return $ ClusterStoppingState ps svs disp progress allDone

    -- It may happen that previously sent state already covered all
    -- interesting changes and the newly calculated diff is just empty
    -- and boring in which case we detect this and don't send anything.
    isEmptyDiff :: ClusterStopDiff -> Bool
    isEmptyDiff ClusterStopDiff{..} =
      null _csp_procs && null _csp_servs && isNothing _csp_disposition
      && fst _csp_progress == snd _csp_progress && not _csp_cluster_stopped
      && null _csp_warnings

    calculateStopDiff :: ClusterStoppingState -> ClusterStoppingState
                      -> ClusterStopDiff
    calculateStopDiff old new =
      let (nPs, wps) = diffProcs (M.fromList $ _css_procs old) (_css_procs new)
          (nSs, wss) = diffServs (M.fromList $ _css_svs old) (_css_svs new)
          (nDs, wds) = diffDisps (listToMaybe $ _css_disposition old) (listToMaybe $ _css_disposition new)
      in ClusterStopDiff { _csp_procs = nPs
                         , _csp_servs = nSs
                         , _csp_disposition = nDs
                         , _csp_progress = (_css_progress old, _css_progress new)
                         , _csp_cluster_stopped = _css_done new
                         , _csp_warnings = wps ++ wss ++ wds
                         }

    -- compare object to some old version
    filterWithWarnings :: forall a b. Ord a
                       => M.Map a b
                       -> [(a, b)]
                       -> b
                       -> (a -> b -> b -> Maybe (a, b, b, [String]))
                       -> ([(a, b, b)], [String])
    filterWithWarnings mo new def f =
      let n :: [(a, b, b, [String])]
          n = flip mapMaybe new $ \(a, b) -> f a (M.findWithDefault def a mo) b
      in (map (\(a, b, b', _) -> (a, b, b')) n, concatMap (\(_, _, _, w) -> w) n)

    diffProcs mold new = filterWithWarnings mold new M0.PSUnknown procTransitioned
    diffServs mold new = filterWithWarnings mold new M0.SSUnknown servTransitioned

    diffDisps dold dnew | dold == dnew = (Nothing, [])
    diffDisps Nothing _ = (Nothing, ["Cluster disposition was not previously set"])
    diffDisps _ Nothing = (Nothing, ["Cluster disposition no longer set"])
    diffDisps (Just o@M0.OFFLINE) (Just n@M0.ONLINE) = (Just (o, n), ["Cluster disposition went back to online"])
    diffDisps (Just o@M0.ONLINE) (Just n@M0.OFFLINE) = (Just (o, n), [])
    diffDisps _ _ = (Nothing, [])

    procTransitioned _ o n | o == n = Nothing
    procTransitioned p o n@M0.PSOffline = Just (p, o, n, [])
    procTransitioned p o@M0.PSOffline n = Just (p, o, n, [M0.showFid p ++ " transitioned out of offline to " ++ show n])
    procTransitioned _ _ _ = Nothing

    servTransitioned _ o n | o == n = Nothing
    servTransitioned s o n@M0.SSOffline = Just (s, o, n, [])
    servTransitioned s o@M0.SSOffline n = Just (s, o, n, [M0.showFid s ++ " transitioned out of offline to " ++ show n])
    servTransitioned _ _ _ = Nothing

-- | State used throughout 'ruleClusterMonitorStop'.
data ClusterStoppingState = ClusterStoppingState
  { _css_procs :: [(M0.Process, M0.ProcessState)]
  , _css_svs :: [(M0.Service, M0.ServiceState)]
  , _css_disposition :: [M0.Disposition]
  , _css_progress :: Rational
  , _css_done :: Bool
  }
