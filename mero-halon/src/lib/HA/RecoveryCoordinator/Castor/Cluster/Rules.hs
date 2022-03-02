-- |
-- Module    : HA.RecoveryCoordinator.Rules.Castor.Cluster
-- Copyright : (C) 2016-2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Mero cluster rules
--
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE ViewPatterns          #-}
module HA.RecoveryCoordinator.Castor.Cluster.Rules
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

import           HA.Encode
import           HA.EventQueue
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Castor.Cluster.Actions
  ( notifyOnClusterTransition )
import           HA.RecoveryCoordinator.Castor.Cluster.Events
import           HA.RecoveryCoordinator.Castor.Node.Events
import           HA.RecoveryCoordinator.Castor.Pool.Actions (getPools)
import           HA.RecoveryCoordinator.Castor.Process.Events
import           HA.RecoveryCoordinator.Job.Actions
import           HA.RecoveryCoordinator.Job.Events (JobFinished(..))
import           HA.RecoveryCoordinator.Mero (labelRecoveryCoordinator)
import           HA.RecoveryCoordinator.Mero.Events
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..), Has(..), Runs(..))
import qualified HA.Resources as R (Node(..))
import qualified HA.Resources.Castor as Cas
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           Mero.ConfC (ServiceType(CST_CONFD,CST_IOS,CST_MDS,CST_RMS))
import           Network.CEP

import           Control.Applicative
import           Control.Category
import           Control.Distributed.Process hiding (catch, try)
import           Control.Lens
import           Control.Monad (join, unless, void, when)
import           Control.Monad.Trans.State (execState)
import qualified Control.Monad.Trans.State as State
import           Data.Foldable
import           Data.List (sort)
import qualified Data.Map.Strict as M
import           Data.Maybe ( catMaybes, listToMaybe, maybeToList, mapMaybe
                            , isJust, isNothing, fromJust )
import           Data.Ratio
import qualified Data.Set as Set
import           Data.Traversable (forM, for)
import           Data.Typeable
import           Data.Vinyl hiding ((:~:))

import           Prelude hiding ((.), id)
import           Text.Printf (printf)

-- | All the rules that are required for cluster start.
clusterRules :: Definitions RC ()
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
eventNodeFailedStart :: Definitions RC ()
eventNodeFailedStart = defineSimpleTask "castor::cluster:node-failed-bootstrap" $ \case
  KernelStartFailure{} -> do
    Log.rcLog' Log.ERROR $ "Kernel module failed to start."
    -- _ -> do modifyGraph $ G.connectUnique Cluster Has M0.MeroClusterFailed
    -- XXX: notify $ MeroClusterFailed
    -- XXX: check if it's a client node, in that case such failure
    -- should not be a panic

-- | This is a rule which interprets state change events and is responsible for
-- changing the state of the cluster accordingly'
--
-- Listens for:
--   - internal notifications
-- Emits:
--   - 'Event.BarrierPass'
-- Idempotent
-- Nonblocking
eventAdjustClusterState :: Definitions RC ()
eventAdjustClusterState = defineSimpleTask "castor::cluster::event::update-cluster-state"
  $ \msg -> do
    let findChanges :: Process [()]
        findChanges = do -- XXX: move to the common place
          InternalObjectStateChange chs <- decodeP msg
          return $ mapMaybe (\(AnyStateChange (_ :: a) _ _ _) ->
                       case eqT :: Maybe (a Data.Typeable.:~: M0.Process) of
                         Just Refl -> Just ()
                         Nothing   -> Nothing) chs
    unlessM (null <$> liftProcess findChanges) notifyOnClusterTransition

-- | This is a rule catches death of the Principal RM and elects new one.
--
-- Listens for:
--   - internal notifications
-- Emits:
--   - internal notifications
-- Idempotent
-- Nonblocking
eventUpdatePrincipalRM :: Definitions RC ()
eventUpdatePrincipalRM = defineSimpleTask "castor::cluster::event::update-principal-rm" $ \msg -> do
    let findChanges = do -- XXX: move to the common place
          InternalObjectStateChange chs <- liftProcess $ decodeP msg
          return $ mapMaybe (\(AnyStateChange (a :: a) _old _new _) ->
                       case eqT :: Maybe (a Data.Typeable.:~: M0.Process) of
                         Just Refl -> Just a
                         Nothing   -> Nothing) chs
    mrm <- getPrincipalRM
    Log.rcLog' Log.DEBUG $ "principal RM: " ++ show mrm
    unless (isJust mrm) $ do
      changed_processes :: [M0.Process] <- findChanges
      Log.rcLog' Log.DEBUG $ "changed processes: " ++ show changed_processes
      unless (null changed_processes) $ void pickPrincipalRM

-------------------------------------------------------------------------------
-- Requests handling
-------------------------------------------------------------------------------
-- $requests
-- User can control whole cluster state using following requests.
-- Each request trigger a long procedure of moving cluster into desired state
-- if those transition is possible.

-- | Query mero cluster status.
--
-- Nilpotent request.
isRCNode :: NodeId -> Process Bool
isRCNode nid = do
    whereisRemoteAsync nid labelRecoveryCoordinator
    isJust . join <$> receiveTimeout 1000000 [ match $ \(WhereIsReply _ mp) -> return mp ]

requestClusterStatus :: Definitions RC ()
requestClusterStatus = defineSimpleTask "castor::cluster::request::status"
  $ \(ClusterStatusRequest ch) -> do
      rg <- getGraph
      let (snsPools, mdixPool) = getPools rg
      repairs <- fmap catMaybes $ traverse (\p -> fmap (p,) <$> getPoolRepairStatus p) snsPools
      hosts <- forM (sort $ G.connectedTo Cluster Has rg) $ \host -> do
            let nodes = sort $ G.connectedTo host Runs rg :: [M0.Node]
            prs <- forM nodes $ \node -> do
                     processes <- getChildren node
                     forM processes $ \process -> do
                       let st = M0.getState process rg
                           mpl = G.connectedTo process Has rg
                       services  <- sort <$> getChildren process
                       let ptyp = getType mpl services
                       services' <- forM services $ \service -> do
                          sdevs  <- sort <$> getChildren service
                          sdevs' <- forM sdevs $ \(sdev :: M0.SDev) -> do
                            let msd   = do disk :: M0.Disk <- G.connectedTo sdev M0.IsOnHardware rg
                                           sd :: Cas.StorageDevice <- G.connectedTo disk M0.At rg
                                           return sd
                                slot  = G.connectedTo sdev M0.At rg :: Maybe Cas.Slot
                                state = M0.getState sdev rg
                            return (sdev, state, slot, msd)
                          return (ReportClusterService (M0.getState service rg) service sdevs')
                       return (process, ReportClusterProcess ptyp st services')
            let mnid = case nodes of
                    -- XXX What's so special about the first element of `nodes`?
                    -- Why do we always ignore the remaining elements?
                    -- Is we are certain that this list may not contain
                    -- several elements, why do we use `Unbounded` cardinality
                    -- for Cas.Host-[R.Runs]->M0.Node relation then?
                    (node:_) -> M0.m0nodeToNode node rg <&> \(R.Node nid) -> nid
                    [] -> Nothing
            isRC <- maybe (return False) (liftProcess . isRCNode) mnid
            let node_st =
                  maybe M0.NSUnknown (flip M0.getState rg) $ listToMaybe nodes
            return ( host
                   , ReportClusterHost (listToMaybe nodes) node_st mnid isRC (sort $ join prs)
                   )
      Just root <- getRoot
      mprof <- theProfile
      liftProcess . sendChan ch $ ReportClusterState
        { csrStatus   = getClusterStatus rg
        , csrSnsPools = sort snsPools <&> \pool ->
                ( pool
                -- createSNSPool guarantees that every SNS pool has
                -- M0.PoolId attached.  'Nothing' is not possible.
                , fromJust $ G.connectedTo pool Has rg )
        , csrDixPool  = mdixPool
        , csrProfile  = mprof
        , csrSNS      = sort repairs
        , csrStats    = G.connectedTo root Has rg
        , csrHosts    = hosts
        , csrPrincipalRM = getPrincipalRM' rg
        }
  where
    getType (Just CI.PLHalon)           _ = "halon"
    getType (Just CI.PLM0t1fs)          _ = "m0t1fs"
    getType (Just (CI.PLClovis name _)) _ = name
    getType _ srvs
      | any (\(M0.Service _ t _) -> t == CST_IOS) srvs   = "ioservice"
      | any (\(M0.Service _ t _) -> t == CST_MDS) srvs   = "mdservice"
      | any (\(M0.Service _ t _) -> t == CST_CONFD) srvs = "confd"
      | otherwise                                        = "m0d"

jobClusterStart :: Job ClusterStartRequest ClusterStartResult
jobClusterStart = Job "castor::cluster::start"

-- | Mark all processes as finished mkfs.
--
-- This will make halon to skip mkfs step.
--
-- Note: This rule should be used with great care as if configuration data has
-- changed, or mkfs have not been completed, this call could put cluster into
-- a bad state.
ruleMarkProcessesBootstrapped :: Definitions RC ()
ruleMarkProcessesBootstrapped = defineSimpleTask "castor::server::mark-all-process-bootstrapped" $
  \(MarkProcessesBootstrapped ch) -> do
     rg <- getGraph
     modifyGraph . execState $
       for_ (M0.getM0Processes rg) $ \proc ->
         State.modify (G.connect proc Cas.Is M0.ProcessBootstrapped)
     registerSyncGraph $ sendChan ch ()

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
ruleClusterStart :: Definitions RC ()
ruleClusterStart = mkJobRule jobClusterStart args $ \(JobHandle _ finish) -> do
    wait_server_jobs  <- phaseHandle "wait_server_jobs"

    let getMeroHostsNodes p = do
         rg <- getGraph
         return [ (host, node)
                | host <- G.connectedTo Cluster Has rg  :: [Cas.Host]
                , node <- G.connectedTo host Runs rg :: [M0.Node]
                , p host node rg
                ]

    let appendServerFailure s = do
           modify Local $ rlens fldRep . rfield %~
             (\x -> Just $ case x of
                 Just (ClusterStartFailure n xs) -> ClusterStartFailure n (s:xs)
                 _ -> ClusterStartFailure "server start failure" [s] )

    let fail_job st = return $ Right (st, [finish])

    let start_job = do
          rg <- getGraph
          -- Randomly select principal RM, it may be switched if another
          -- RM will appear online before this one.
          let procsConfd = [ proc
                           | proc <- M0.getM0Processes rg
                           , svc <- G.connectedTo proc M0.IsParentOf rg
                           , M0.s_type svc == CST_CONFD
                           ]
          traverse_ setPrincipalRMIfUnset $
            listToMaybe [ svc
                        | proc <- procsConfd
                        , svc <- G.connectedTo proc M0.IsParentOf rg
                        , M0.s_type svc == CST_RMS
                        ]
          -- Update cluster disposition
          Log.rcLog' Log.DEBUG "cluster.disposition=ONLINE"
          modifyGraph $ G.connect Cluster Has M0.ONLINE
          servers <- fmap (map snd) $ getMeroHostsNodes
            $ \(host :: Cas.Host) (node::M0.Node) rg' ->
                   ( G.isConnected host Has Cas.HA_M0SERVER rg'
                  || G.isConnected host Has Cas.HA_M0CLIENT rg'
                   )
                && M0.getState node rg' /= M0.NSFailed
                && M0.getState node rg' /= M0.NSFailedUnrecoverable
          jobs <- forM servers $ \s -> do
            Log.rcLog' Log.DEBUG $ "starting processes on node=" ++ M0.showFid s
            startJob $ StartProcessesOnNodeRequest s
          modify Local $ rlens fldJobs . rfield .~ Set.fromList jobs

          case jobs of
            [] -> do
              Log.rcLog' Log.WARN $ "No nodes to start."
              return $ Right (ClusterStartOk, [finish])
            _ -> do
              modify Local $ rlens fldNext . rfield .~ Just finish
              return $ Right (ClusterStartTimeout [], [wait_server_jobs])

    let route ClusterStartRequest{} = getRoot >>= \case
          Nothing -> fail_job $ ClusterStartFailure "Initial data not loaded." []
          Just _ -> do
            rg <- getGraph
            case getClusterStatus rg of
              Nothing -> do
                Log.rcLog' Log.ERROR "graph invariant violation: cluster has no attached state"
                fail_job $ ClusterStartFailure "Unknown cluster state." []
              Just _ -> if (maybe False (== M0.ONLINE) $ G.connectedTo Cluster Has rg)
                            || isClusterStopped rg
                        then start_job
                        else fail_job $ ClusterStartFailure "Cluster not fully stopped." []

    setPhaseIf wait_server_jobs ourJob $ \(JobFinished l s) -> do
       (node, result) <- case s of
         NodeProcessesStarted node ->
           return (node, "success")
         s'@(NodeProcessesStartTimeout node _) -> do
           modify Local $ rlens fldNext . rfield .~ Just finish
           appendServerFailure s'
           return (node, "timeout")
         s'@(NodeProcessesStartFailure node _) -> do
           modify Local $ rlens fldNext . rfield .~ Just finish
           appendServerFailure s'
           return (node, "failure")
       Log.rcLog' Log.DEBUG (printf "node job finished for %s with %s"
                                    (M0.showFid node) (show result) :: String)
       modify Local $ rlens fldJobs . rfield %~ (`Set.difference` Set.fromList l)
       remainingJobs <- getField . rget fldJobs <$> get Local
       if Set.null remainingJobs
       then do
         modify Local $ rlens fldRep . rfield .~ Just ClusterStartOk
         Just next <- getField . rget fldNext <$> get Local
         continue next
       else continue wait_server_jobs

    return route
  where
    fldReq :: Proxy '("request", Maybe ClusterStartRequest)
    fldReq = Proxy
    fldRep :: Proxy '("reply", Maybe ClusterStartResult)
    fldRep = Proxy
    fldJobs :: Proxy '("nodes", Set.Set ListenerId)
    fldJobs = Proxy
    fldNext :: Proxy '("next", Maybe (Jump PhaseHandle))
    fldNext = Proxy
    fldClientsWaitStart = Proxy :: Proxy '("clients-wait-start", Maybe M0.TimeSpec)
    args = fldUUID =: Nothing
       <+> fldReq  =: Nothing
       <+> fldRep  =: Nothing
       <+> fldJobs =: Set.empty
       <+> fldNext  =: Nothing
       <+> fldClientsWaitStart =: Nothing

    ourJob msg@(JobFinished l _) _ ls =
      if Set.null $ Set.fromList l `Set.intersection` getField (rget fldJobs ls)
      then return $ Nothing
      else return $ Just msg

jobClusterStop :: Job ClusterStopRequest ClusterStopResult
jobClusterStop = Job "castor::cluster::request::stop"

-- | Request cluster to teardown.
--   Immediately set cluster disposition to OFFLINE.
--   If the cluster is already tearing down, or is starting, this
--   rule will do nothing.
--   Sends 'StopProcessesOnNodeRequest' to all nodes.
--   TODO: Does this include stopping clients on the nodes?
requestClusterStop :: Definitions RC ()
requestClusterStop = mkJobRule jobClusterStop args $ \(JobHandle _ finish) -> do
  let mkNodesAwait name = mkLoop name (return [])
        (\(JobFinished lis v) l -> case v of
            StopProcessesOnNodeOk{} -> return . Right $
              (rlens fldJobs %~ fieldMap (filter (`notElem` lis))) l
            _ -> do
              modify Local $ rlens fldRep . rfield .~ Just (ClusterStopFailed (show v))
              return $ Left finish)
        (getField . rget fldJobs <$> get Local >>= \case
            [] -> do
              revertSdevStates
              modify Local $ rlens fldRep . rfield .~ Just ClusterStopOk
              return $ Just [finish]
            _ -> return Nothing)

  wait_for_nodes_stop <- mkNodesAwait "wait_for_nodes_stop"

  let route (ClusterStopRequest _reason ch) = do
        rg <- getGraph
        if isClusterStopped rg && maybe False (== M0.ONLINE) (G.connectedTo Cluster Has rg)
        then do
          liftProcess $ sendChan ch StateChangeFinished
          return $ Right (ClusterStopOk, [finish])
        else do
          modifyGraph $ G.connect Cluster Has M0.OFFLINE
          let nodes = [ node
                      | host :: Cas.Host <- G.connectedTo Cluster Has rg
                      , node <- G.connectedTo host Runs rg
                      ]
          jobs <- for nodes $ startJob . StopProcessesOnNodeRequest
          modify Local $ rlens fldJobs . rfield .~ jobs
          liftProcess $ sendChan ch StateChangeStarted
          return $ Right (ClusterStopFailed "default", [wait_for_nodes_stop])

  return route
  where
    fldReq = Proxy :: Proxy '("request", Maybe ClusterStopRequest)
    fldRep = Proxy :: Proxy '("reply", Maybe ClusterStopResult)
    fldJobs = Proxy :: Proxy '("jobs", [ListenerId])
    args = fldReq =: Nothing
       <+> fldRep =: Nothing
       <+> fldJobs =: []

-- | Revert "ing" states of SDevs.
-- When the cluster is stopped, no SNS operation is actually happen-ing.
-- No Repair-ing, no Rebalanc-ing, nothing.
revertSdevStates :: PhaseM RC l ()
revertSdevStates = do
    rg <- getGraph
    for_ [ (sdev, state, newState)
         | sd :: Cas.StorageDevice <- G.connectedTo Cluster Has rg
         , disk :: M0.Disk <- connectedFromList M0.At sd rg
         , sdev :: M0.SDev <- connectedFromList M0.IsOnHardware disk rg
         , state :: M0.SDevState <- connectedToList sdev Cas.Is rg
         , let newState = checkpoint state
         , newState /= state
         ] $ \(sdev, state, newState) -> do
        let msg :: String
            msg = printf "Reverting state of SDev %s: %s -> %s"
                    (show $ M0.fid sdev) (show state) (show newState)
        Log.rcLog' Log.DEBUG msg
        modifyGraph $ G.connect sdev Cas.Is newState
  where
    connectedFromList r b g = G.asUnbounded $ G.connectedFrom r b g
    connectedToList a r g = G.asUnbounded $ G.connectedTo a r g

    checkpoint M0.SDSRepairing = M0.SDSFailed
    checkpoint M0.SDSRebalancing = M0.SDSRepaired
    checkpoint (M0.SDSInhibited st) = M0.SDSInhibited $! checkpoint st
    checkpoint (M0.SDSTransient st) = checkpoint st
    checkpoint st = st

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
requestClusterReset :: Definitions RC ()
requestClusterReset = defineSimple "castor::cluster::reset"
  $ \(HAEvent eid (ClusterResetRequest deepReset)) -> do
    Log.rcLog' Log.DEBUG "Cluster reset requested."
    -- Mark all nodes, processes and services as unknown.
    nodes <- getGraph <&> \rg -> [ node
              | host <- G.connectedTo Cluster Has rg :: [Cas.Host]
              , node <- take 1 (G.connectedTo host Runs rg) :: [M0.Node]
              ]
    procs <- getGraph <&> M0.getM0Processes
    srvs <- getGraph <&> \rg -> join
      $ (\p -> G.connectedTo p M0.IsParentOf rg :: [M0.Service])
      <$> procs
    modifyGraph $ foldl' (.) id (flip M0.setState M0.NSUnknown <$> nodes)
    modifyGraph $ foldl' (.) id (flip M0.setState M0.SSUnknown <$> srvs)
    modifyGraph $ foldl' (.) id (flip M0.setState M0.PSUnknown <$> procs)
    if deepReset
    then do
      syncGraphBlocking
      Log.rcLog' Log.DEBUG "Clearing event queue."
      self <- liftProcess $ getSelfPid
      eqPid <- lsEQPid <$> get Global
      liftProcess $ usend eqPid (DoClearEQ self)
      -- Actually properly block the RC here - we do not want to allow
      -- other events to occur in the meantime.
      msg <- liftProcess $ expectTimeout (1*1000000) -- 1s
      case msg of
        Just DoneClearEQ -> Log.rcLog' Log.DEBUG "EQ cleared"
        Nothing -> do
          Log.rcLog' Log.ERROR "Unable to clear the EQ!"
          -- Attempt to ack this message to avoid a reset loop
          messageProcessed eid
      -- Reset the recovery co-ordinator
      error "User requested `cluster reset --hard`"
    else
      messageProcessed eid

-- | Stop m0t1fs service with given fid.
--
-- This may be triggered by the user using halonctl.
--
-- 1. Find if there is m0t1fs service with a given fid
-- 2. Request that the process is stopped.
--
-- Does not wait for any sort of reply.
requestStopMeroClient :: Definitions RC ()
requestStopMeroClient = defineSimpleTask "castor::cluster::client::request::stop" $
  \(StopMeroClientRequest fid reason) -> do
    Log.tagContext Log.SM [("client.fid", show fid)
                          ,("client.stopreason", reason)] Nothing
    Log.rcLog' Log.DEBUG $ "Stop mero client requested."
    lookupConfObjByFid fid >>= \case
      Nothing -> Log.rcLog' Log.WARN "Could not find associated process."
      Just p -> do
        rg <- getGraph
        if G.isConnected p Has CI.PLM0t1fs rg
        then promulgateRC $ StopProcessRequest p
        else Log.rcLog' Log.WARN "Not a client process."

-- | Start already existing (in confd) mero client.
--
-- 1. Checks if client process exists in database
-- 2. Tries to start the client process through 'ruleProcessStart'.
requestStartMeroClient :: Definitions RC ()
requestStartMeroClient = defineSimpleTask "castor::cluster::client::request::start" $
  \(StartMeroClientRequest fid) -> do
    Log.tagContext Log.SM [("client.fid", show fid)] Nothing
    Log.rcLog' Log.DEBUG $ "Start mero client requested."
    lookupConfObjByFid fid >>= \case
      Nothing -> Log.rcLog' Log.WARN "Could not find associated process."
      Just p -> G.isConnected p Has CI.PLM0t1fs <$> getGraph >>= \case
        True -> promulgateRC $ ProcessStartRequest p
        False -> Log.rcLog' Log.WARN "Not a client process."

-- | Caller 'ProcessId' signals that it's interested in cluster
-- stopping ('MonitorClusterStop') and wants to receive information
-- about it. The idea behind this rule is that it passively (i.e.
-- without actually invoking any cluster-changing actions itself)
-- monitors events relevant to cluster stopping that are flying by and
-- reports progress back to the caller. The caller can choose to block
-- until it's satisfied, report to the user with progress and so on.
ruleClusterMonitorStop :: Definitions RC ()
ruleClusterMonitorStop = define "castor::cluster::stop::monitoring" $ do
  start_monitoring <- phaseHandle "start_monitoring"
  caller_died <- phaseHandle "caller_died"
  isc_watcher <- phaseHandle "internal_state_change_watcher"
  cluster_level_watcher <- phaseHandle "cluster_level_watcher"
  cluster_stop_finished <- phaseHandle "cluster_stop_finished"
  finish <- phaseHandle "finish"

  let watchForChanges = switch [ caller_died, isc_watcher
                               , cluster_level_watcher, cluster_stop_finished ]

  setPhase start_monitoring $ \(HAEvent uuid (MonitorClusterStop caller)) -> do
    todo uuid
    st <- calculateStoppingState
    mref <- liftProcess $ monitor caller
    modify Local $ rlens fldCallerPid . rfield .~ Just caller
    modify Local $ rlens fldClusterStopProgress . rfield .~ Just st
    modify Local $ rlens fldUUID . rfield .~ Just uuid
    modify Local $ rlens fldMonitorRef . rfield .~ Just mref
    watchForChanges

  setPhaseIf isc_watcher iscGuard $ \() -> do
    notifyCallerWithDiff finish Nothing
    watchForChanges

  setPhase cluster_level_watcher $ \ClusterStateChange{} -> do
    notifyCallerWithDiff finish Nothing
    watchForChanges

  setPhase cluster_stop_finished $ \csr -> do
    notifyCallerWithDiff finish $ Just csr
    continue finish

  setPhaseIf caller_died monitorGuard $ \() -> do
    caller <- getField . rget fldCallerPid <$> get Local
    Log.actLog "Caller died" [ ("caller.pid", show caller) ]
    continue finish

  directly finish $ do
    getField . rget fldMonitorRef <$> get Local >>= \case
      Nothing -> Log.rcLog' Log.WARN "No monitor ref"
      Just mref -> liftProcess $ unmonitor mref
    getField . rget fldUUID <$> get Local >>= \case
      Nothing -> Log.rcLog' Log.WARN "No UUID"
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
    iscGuard (HAEvent _ msg) _ _ = decodeP msg >>= \(InternalObjectStateChange iosc) ->
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

    notifyCallerWithDiff finish mcsp = do
      newSt <- calculateStoppingState
      moldSt <- getField . rget fldClusterStopProgress <$> get Local
      mcaller <- getField . rget fldCallerPid <$> get Local
      modify Local $ rlens fldClusterStopProgress . rfield .~ Just newSt
      case (moldSt, mcaller) of
        (Nothing, _) -> do
          Log.rcLog' Log.WARN "No previous cluster state known (‘impossible’)"
          continue finish
        (_, Nothing) -> do
          Log.rcLog' Log.WARN "No caller known (‘impossible’)"
          continue finish
        (Just oldSt, Just caller) -> do
          let diff = (calculateStopDiff oldSt newSt) { _csp_cluster_stopped = mcsp }
          -- When we have cluster stop result, just report the diff
          -- containing it. If not, continue as usual.
          case mcsp of
            Nothing -> when (not $ isEmptyDiff diff) $ do
              liftProcess $ usend caller diff
            Just{} -> do
              liftProcess $ usend caller diff
              continue finish

    calculateStoppingState :: PhaseM RC l ClusterStoppingState
    calculateStoppingState = do
      rg <- getGraph
      let ps = [(p, M0.getState p rg) | p <- M0.getM0Processes rg]
          donePs = filter ((== M0.PSOffline) . snd) ps
          svs = [ (s, M0.getState s rg)
                | (p, _) <- ps
                , s :: M0.Service <- G.connectedTo p M0.IsParentOf rg  ]
          doneSvs = filter ((== M0.SSOffline) . snd) svs

          disp :: [M0.Disposition]
          disp = maybeToList $ G.connectedTo Cluster Has rg
          doneDisp = filter (== M0.OFFLINE) disp

          -- This is a bit of a hack: even if all processes and
          -- services are stopped, we do not want to report completion
          -- to the user before ClusterStopResult is received. It
          -- would be strange to report 100% completion and still keep
          -- the user waiting. Put in this dummy ‘part’ which will
          -- server to keep that from happening: when
          -- ClusterStopResult comes, we will announce completion to
          -- the user straight away anyway.
          clusterStopResultPart = [()]

          allParts = toInteger $ length ps + length svs + length disp
                               + length clusterStopResultPart
          doneParts = toInteger $ length donePs + length doneSvs + length doneDisp

          progress :: Rational
          progress = (100 % allParts) * (doneParts % 1)
      return $ ClusterStoppingState ps svs disp progress

    -- It may happen that previously sent state already covered all
    -- interesting changes and the newly calculated diff is just empty
    -- and boring in which case we detect this and don't send anything.
    isEmptyDiff :: ClusterStopDiff -> Bool
    isEmptyDiff ClusterStopDiff{..} =
      null _csp_procs && null _csp_servs && isNothing _csp_disposition
      && fst _csp_progress == snd _csp_progress
      && isNothing _csp_cluster_stopped && null _csp_warnings

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
                         , _csp_cluster_stopped = Nothing
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
  }
