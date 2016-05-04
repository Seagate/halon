-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeOperators         #-}
module HA.RecoveryCoordinator.Rules.Castor.Cluster where

import           HA.EventQueue.Types
import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0

import qualified HA.ResourceGraph as G
import           HA.RecoveryCoordinator.Actions.Core
import           HA.RecoveryCoordinator.Actions.Hardware
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Actions.Service (lookupRunningService)
import           HA.RecoveryCoordinator.Events.Castor.Cluster
import           HA.RecoveryCoordinator.Events.Mero
import           HA.RecoveryCoordinator.Rules.Mero.Conf
  ( applyStateChanges
  , stateSet
  )
import           HA.Service (encodeP, ServiceStopRequest(..))
import           HA.Services.Mero
import           HA.Services.Mero.CEP (meroChannel)
import           Mero.ConfC (Fid(..), ServiceType(..))
import           Network.CEP

import           Control.Applicative
import           Control.Category
import           Control.Distributed.Process
import           Control.Distributed.Process.Closure (mkClosure)
import           Control.Lens
import           Control.Monad (guard, join, unless, when, void)
import           Control.Monad.Trans.Maybe

import           Data.Binary (Binary)
import           Data.Either (partitionEithers, rights)
import           Data.Maybe (catMaybes, listToMaybe, mapMaybe, fromMaybe)
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Foldable
import           Data.Proxy (Proxy(..))
import           Data.Traversable (forM)
import           Data.Typeable (Typeable)
import           Data.Vinyl

import           System.Posix.SysInfo

import           Text.Printf
import           Prelude hiding ((.), id)

--------------------------------------------------------------------------------
-- Extensible record fields
--------------------------------------------------------------------------------

type FldHostHardwareInfo = '("mhostHardwareInfo", Maybe HostHardwareInfo)
fldHostHardwareInfo :: Proxy FldHostHardwareInfo
fldHostHardwareInfo = Proxy

type FldUUID = '("uuid", Maybe UUID)
fldUUID :: Proxy FldUUID
fldUUID = Proxy

type FldHost = '("host", Maybe R.Host)
fldHost :: Proxy FldHost
fldHost = Proxy

type FldNode = '("node", Maybe R.Node)
fldNode :: Proxy FldNode
fldNode = Proxy

clusterRules :: Definitions LoopState ()
clusterRules = sequence_
  [ ruleClusterStatus
  , ruleClusterStart
  , ruleClusterStop
  , ruleTearDownMeroNode
  , ruleNewMeroServer
  , ruleDynamicClient
  ]

-- | Query mero cluster status.
ruleClusterStatus :: Definitions LoopState ()
ruleClusterStatus = defineSimple "cluster-status-request"
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
                       return (process, ReportClusterProcess st services)
            let go (msdev::Maybe M0.SDev) = msdev >>= \sdev ->
                 let st = M0.getState sdev rg
                 in if st == M0.M0_NC_ONLINE
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
ruleClusterStart :: Definitions LoopState ()
ruleClusterStart = defineSimple "cluster-start-request"
  $ \(HAEvent eid (ClusterStartRequest ch) _) -> do
      rg <- getLocalGraph
      fs <- getFilesystem
      let eresult = case (fs, listToMaybe $ G.connectedTo R.Cluster R.Has rg) of
            (Nothing, _) -> Left $ StateChangeError "Initial data not loaded."
            (_, Nothing) -> Left $ StateChangeError "Unknown current state."
            (_, Just st) -> case st of
               M0.MeroClusterStopped    -> Right $ do
                  modifyGraph $ G.connectUnique R.Cluster R.Has (M0.MeroClusterStarting (M0.BootLevel 0))
                  -- Due to the mero requirements we should mark all services as running.
                  -- We do not update sdev/disk state for now.
                  modifyGraph $ \g ->
                     let procs = G.getResourcesOfType g :: [M0.Process]
                         srvs  = procs >>= \p -> G.connectedTo p M0.IsParentOf g :: [M0.Service]
                     in flip (foldr (\s -> G.connectUniqueFrom s R.Is M0.M0_NC_ONLINE)) srvs
                              $ g
                  announceMeroNodes
                  syncGraphCallback $ \pid proc -> do
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
ruleClusterStop :: Definitions LoopState ()
ruleClusterStop = defineSimple "cluster-stop-request"
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
      modifyGraph $ G.connectUnique R.Cluster R.Has (M0.MeroClusterStopping (M0.BootLevel teardownStartLevel))
      let nodes =
            [ node | host <- G.getResourcesOfType rg :: [R.Host]
                   , node <- take 1 (G.connectedTo host R.Runs rg) :: [R.Node] ]
      forM_ nodes $ promulgateRC . StopMeroServer
      syncGraphCallback $ \pid proc -> do
        sendChan ch (StateChangeStarted pid)
        proc eid

-- | Timeout to wait for reply from node.
tearDownTimeout :: Int
tearDownTimeout = 5*60

-- | Bootlevel that RC procedure is started at.
maxTeardownLevel :: Int
maxTeardownLevel = 3

-- | The level to start teardown from. We start on a level higher than
-- 'maxTeardownLevel' because:
--
-- * Node teardowns are synchronised through a barrier
--
-- * Barrier decides if work on current level is finished by looking
-- for 'M0.Pending'-attached boot level label to processes.
--
-- * Barrier attaches the level pending through 'M0.Pending' relation
-- before letting the nodes to pass the barrier onto the next level.
--
-- * Barrier code is only entered at the end of a level teardown.
--
-- Therefore we need to enter barrier code to apply a 'M0.Pending'
-- label onto the processes. We need to start on a level with no
-- processes so no processes are missed and the lower level processes
-- have a chance to be marked. 'maxTeardownLevel' has processes on it
-- (@m0t1fs@) so we start on higher, process-less level.
teardownStartLevel :: Int
teardownStartLevel = maxTeardownLevel + 1

-- | List of all nodes that are running teardown, with message id
-- that triggered it.
newtype NodesRunningTeardown = NodesRunningTeardown (Map R.Node UUID)


-- | Send a notification when the cluster state transitions.
--
-- The user specifies the desired state for the cluster and a builder
-- for for a notification that is sent when the cluster enters that
-- state. This means we can block across nodes by waiting for such a
-- message.
--
-- Whether the cluster is in the new state is determined by
-- 'calculateMeroClusterStatus' which traverses the RG and checks the
-- current cluster status and status of the processes on the current
-- cluster boot level.
notifyOnClusterTranstion :: (Binary a, Typeable a)
                         => M0.MeroClusterState -- ^ State to notify on
                         -> (M0.MeroClusterState -> a) -- Notification to send
                         -> Maybe UUID -- Message to declare processed
                         -> PhaseM LoopState l ()
notifyOnClusterTranstion desiredState msg meid = do
  newState <- calculateMeroClusterStatus
  phaseLog "notifyOnClusterTransition:desiredState" $ show desiredState
  phaseLog "notifyOnClusterTransition:state" $ show newState
  if newState == desiredState then do
    modifyGraph $ G.connectUnique R.Cluster R.Has newState
    syncGraphCallback $ \self proc -> do
      -- HALON-197 workaround - systemctl comes back before services are
      -- started, so it's possible to try to connect to RM/confd before they're
      -- available. This should be removed when Mero correctly reports on
      -- process/service starting to halon.
      Nothing <- receiveTimeout 500000 [] :: Process (Maybe ())
      usend self (msg newState)
      forM_ meid proc
  else
    forM_ meid syncGraphProcessMsg

-- | Message guard: Check if the barrier being passed is for the
-- correct level. This is used during 'ruleNewMeroServer' with the
-- actual 'BarrierPass' message being emitted from
-- 'notifyOnClusterTransition'.
barrierPass :: M0.MeroClusterState
            -> BarrierPass
            -> g
            -> l
            -> Process (Maybe ())
barrierPass state (BarrierPass state') _ _ =
  if state <= state' then return (Just ()) else return Nothing

-- | Message guard: Check if the service process is running on this node.
declareMeroChannelOnNode :: HAEvent DeclareMeroChannel
                         -> LoopState
                         -> Maybe (R.Node, R.Host, y)
                         -> Process (Maybe (TypedChannel ProcessControlMsg))
declareMeroChannelOnNode _ _ Nothing = return Nothing
declareMeroChannelOnNode (HAEvent _ (DeclareMeroChannel sp _ cc) _) ls (Just (node, _, _)) =
  case G.isConnected node R.Runs sp $ lsGraph ls of
    True -> return $ Just cc
    False -> return Nothing

-- | Message guard: Check if the process control message is from the right node.
processControlOnNode :: HAEvent ProcessControlResultMsg
                     -> LoopState
                     -> Maybe (R.Node, R.Host, y)
                     -> Process (Maybe (UUID, [Either Fid (Fid, String)]))
processControlOnNode _ _ Nothing = return Nothing
processControlOnNode (HAEvent eid (ProcessControlResultMsg nid r) _) _ (Just ((R.Node nid'), _, _)) =
  if nid == nid' then return $ Just (eid, r) else return Nothing


-- | Given 'M0.BootLevel', generate a corresponding 'M0.ProcessLabel'.
mkLabel :: M0.BootLevel -> M0.ProcessLabel
mkLabel bl@(M0.BootLevel l)
  | l == maxTeardownLevel = M0.PLM0t1fs
  | otherwise = M0.PLBootLevel bl

-- | Find 'M0.Process'es that we're still waiting for to stop on the
-- given boot level. Processes that are in a failed state are excluded
-- from the results, i.e. are assumed to be stopped.
pendingToStop :: M0.MeroClusterState -> PhaseM LoopState l [M0.Process]
pendingToStop lvl = do
  let isPSFailed (M0.PSFailed _) = True
      isPSFailed (M0.PSInhibited st') = isPSFailed st'
      isPSFailed _ = False

  rg <- getLocalGraph
  return [ (srv :: M0.Process) | srv <- G.connectedTo lvl M0.Pending rg
                               , st <- G.connectedTo srv R.Is rg
                               , not $ isPSFailed st ]

-- | Prepare the cluster to advance onto the next teardown level.
--
-- * If we're on last boot level (level 0), mark cluster ase
-- 'M0.MeroClusterStopped', we're done.
--
-- * Otherwise, mark all the processes on the next boot level with a
-- 'M0.ProcessLabel' through 'M0.Pending' relation, later used in
-- 'pendingToStop' to identify processes we're waiting for to stop.
-- Change global 'M0.MeroClusterState' to the next level.
advanceClusterTeardown :: M0.BootLevel -> PhaseM LoopState l M0.MeroClusterState
advanceClusterTeardown (M0.BootLevel 0) = do
  modifyGraph $ G.connectUnique R.Cluster R.Has M0.MeroClusterStopped
  return M0.MeroClusterStopped
advanceClusterTeardown (M0.BootLevel i) = do
  let nextLevel = M0.BootLevel $ i - 1
      clusterLevel = M0.MeroClusterStopping nextLevel
      attachClusterLevel :: M0.Process -> G.Graph -> G.Graph
      attachClusterLevel = G.connect clusterLevel M0.Pending
  modifyGraph $
    G.connectUnique R.Cluster R.Has clusterLevel
    . (\r -> foldr attachClusterLevel r
             -- TODO exclude nodes that failed to teardown?
             (G.connectedFrom R.Has (mkLabel nextLevel) r))
  return clusterLevel

-- | Procedure for tearing down mero services. Starts by each node
-- received 'StopMeroNode' message.
--
-- === Node teardown
--
-- * Add the node to the set of nodes being torn down.
--
-- * Start teardown procedure, starting from 'maxTeardownLevel'. The
-- teardown moves through the levels in decreasing order, i.e.
-- backwards of bootstrap.
--
-- * If cluster is already a lower teardown level then skip teardown
-- on this node for this level, lower the level and try again. If node
-- is on lower level than the cluster state, wait until the cluster
-- transitions into the level it's on then try again: notably, it's
-- waiting for a message from the barrier telling it to go ahead; for
-- barrier description see below.. If the cluster is on the same level
-- as node, we can simply continue teardown on the node.
--
-- * If there are no processes on this node for the current boot
-- level, just advance the node to the next level (in decreasing
-- order) and start teardown from there. If there are processes, ask
-- for them to stop and wait for message indicating whether the
-- processes managed to stop. If the message doesn't arrive within
-- 'teardown_timeout', mark the node as failed to tear down. Notify
-- barrier to allow other nodes to proceed with teardown. Mark the
-- processes on the node as failed.
--
-- * Assuming message comes back on time, mark all the proceses on
-- node as failed, notify the barrier that teardown on this node for
-- this level has completed and advance the node to next level.
--
-- === Barrier
--
-- As per above, we're using a barrier to ensure cluster-wide
-- synchronisation w.r.t. the teardown level. During the course of
-- teardown, nodes want to notify the barrier that they are done with
-- their chunk of work as well as needing to wait until all others
-- nodes finished the work on the same level. Here's a brief
-- description of how this barrier functions. 'notifyBarrier' is
-- called by the node when it's done with its chunk.
--
-- * 'notifyBarrier' grabs the current global cluster state.
--
-- * It finds every process still running that has been marked as
-- 'M0.Pending' to stop. See 'M0.Pending' section for some discussion.
--
-- * If there are still processes waiting to stop, do nothing: we
-- still have nodes that need to report back their results or
-- otherwise fail.
--
-- * If there are no more processes on this boot level and cluster is
-- on boot level 0 (last), simply mark the cluster as stopped.

-- * If there are no more processes on this level and it's not the last level:
--
--     1. Set global cluster state to the next level
--     2. Connect 'M0.Pending' to every 'M0.Process' on the next level.
--     3. Send out a 'BarrierPass' message: this serves as a barrier
--        release, blocked nodes wait for this message and when they
--        see it, they know cluster progressed onto the given level
--        and they can start teardown of that level.
--
-- ==== 'M0.Pending':
--
-- There is glaring issue with usage of 'M0.Pending': it only gets
-- added inside the barrier code but barrier code doesn't get entered
-- until we have progressed through teardown of the start level (in
-- this cas 'maxTeardownLevel') on some node. This means that any
-- processes on 'maxTeardownLevel' can't be picked up by looking for
-- 'M0.Pending' labels. This caused a problem reported as part of
-- @HALON-214@. We get around this issue by starting on
-- 'teardownStartLevel' which starts on a level above
-- 'maxTeardownLevel'. See comment on 'teardownStartLevel' for info.
ruleTearDownMeroNode :: Definitions LoopState ()
ruleTearDownMeroNode = define "teardown-mero-server" $ do
   initialize <- phaseHandle "initialization"
   teardown   <- phaseHandle "teardown"
   teardown_exec <- phaseHandle "teardown-exec"
   teardown_complete <- phaseHandle "teardown-complete"
   teardown_timeout  <- phaseHandle "teardown-timeout"
   await_barrier <- phaseHandle "await-barrier"
   stop_service <- phaseHandle "stop-service"
   finish <- phaseHandle "finish"

   -- Continue process on the next boot level. This method include only
   -- numerical bootlevels.
   let nextBootLevel = do
         Just (a,b, M0.BootLevel i) <- get Local
         put Local $ Just (a,b,M0.BootLevel (i-1))
         continue teardown
       markProcessComplete lvl fids = modifyGraph $ \rg ->
         foldr (\p -> G.disconnect (M0.MeroClusterStopping lvl) M0.Pending p)
               rg
               (getProcessesByFid rg fids :: [M0.Process])

   -- Check if there are any processes left to be stopped on current bootlevel.
   -- If there are any process - then just process current message (meid),
   -- If there are no process left then move cluster to next bootlevel and prepare
   -- all technical information in RG, then emit BarrierPassed function.
   let notifyBarrier meid = do
         Just (_,_,b) <- get Local

         -- TODO: We should figure out what to do here. Currently RC will
         -- just die if we find the wrong state which was also previous
         -- behaviour. Maybe we need ‘TeardownFailed’ status?
         lvl@(M0.MeroClusterStopping bl@(M0.BootLevel _)) <-
           listToMaybe . G.connectedTo R.Cluster R.Has <$> getLocalGraph >>= \case
             Just lvl@(M0.MeroClusterStopping (M0.BootLevel _)) -> return lvl
             st -> error $ "pendingToStop: unexpected level, RC dying: "
                        ++ show st

         allProcs <- pendingToStop lvl
         if null allProcs && b == bl
         then do lvl' <- advanceClusterTeardown bl
                 syncGraphCallback $ \self proc -> do
                   usend self (BarrierPass lvl')
                   forM_ meid proc
         else do phaseLog "debug" $ "There are processes left: " ++ show allProcs
                 forM_ meid syncGraphProcessMsg


   setPhase initialize $ \(HAEvent eid (StopMeroServer node) _) -> getStorageRC  >>= \nodes ->
     case Map.lookup node =<< nodes of
       Nothing -> do
         putStorageRC $ NodesRunningTeardown $ Map.insert node eid (fromMaybe Map.empty nodes)
         fork CopyNewerBuffer $ do
           put Local (Just (eid, node, M0.BootLevel teardownStartLevel))
           continue teardown
       Just eid' -> do
         phaseLog "debug" $ show node ++ " already being processed - ignoring."
         unless (eid == eid') $ messageProcessed eid

   directly teardown $ do
     Just (_, node, lvl@(M0.BootLevel i)) <- get Local
     when (i < 0)  $ continue stop_service
     cluster_lvl <- fromMaybe M0.MeroClusterStopped
                     . listToMaybe . G.connectedTo R.Cluster R.Has <$> getLocalGraph
     case cluster_lvl of
       M0.MeroClusterStopping s
          | s < lvl -> do
              phaseLog "debug" $ printf "%s is on %s while cluster is on %s - skipping"
                                        (show node) (show lvl) (show s)
              nextBootLevel
          | s == lvl  -> continue teardown_exec
          | otherwise -> do
              phaseLog "debug" $ printf "%s is on %s while cluster is on %s - waiting for barries."
                                        (show node) (show lvl) (show s)
              continue await_barrier
       _  -> continue finish

   directly teardown_exec $ do
     Just (_, node, lvl) <- get Local
     rg <- getLocalGraph
     case getLabeledNodeProcesses node (mkLabel lvl) rg of
       [] -> do phaseLog "debug" $ printf "%s R.Has no services on level %s - skipping to the next level"
                                          (show node) (show lvl)
                notifyBarrier Nothing
                nextBootLevel
       ps -> do maction <- runMaybeT $ do
                  m0svc <- MaybeT $ lookupRunningService node m0d
                  host  <- MaybeT $ findNodeHost node
                  ch    <- MaybeT . return $ meroChannel rg m0svc
                  return $ do
                    stopNodeProcesses host ch ps
                    switch [ teardown_complete
                           , timeout tearDownTimeout teardown_timeout ]
                forM_ maction id
                phaseLog "debug" $ printf "Can't find data for %s - continue to timeout" (show node)
                continue teardown_timeout

   setPhaseIf teardown_complete (\(HAEvent eid (ProcessControlResultStopMsg node results) _) _ minfo ->
     runMaybeT $ do
         (_, lnode@(R.Node nid), lvl) <- MaybeT $ return minfo
         -- XXX: do we want to check that this is wanted runlevel?
         guard (nid == node)
         return (eid, lnode, lvl, results))
     $ \(eid, node, lvl, results) -> do
       phaseLog "info" $ printf "%s completed tearing down of level %s." (show node) (show lvl)
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
         Right (x,s) -> stateSet x (M0.PSFailed $ "Failed to stop: " ++ show x))
         <$> resultProcs
       forM_ (rights results) $ \(x,s) ->
         phaseLog "error" $ printf "failed to stop service %s : %s" (show x) s
       markProcessComplete lvl $ map (\case Left x -> x ; Right (x,_) -> x) results
       notifyBarrier (Just eid)
       nextBootLevel

   directly teardown_timeout $ do
     Just (_, node, lvl) <- get Local
     phaseLog "warning" $ printf "%s failed to stop services (timeout)" (show node)
     rg <- getLocalGraph
     let failedProcs = getLabeledNodeProcesses node (mkLabel lvl) rg
     applyStateChanges $ (\p -> stateSet p $ M0.PSFailed "Timeout on stop.")
                          <$> failedProcs
     markProcessComplete lvl $ map M0.fid failedProcs
     markNodeFailedTeardown node
     notifyBarrier Nothing
     continue finish

   setPhaseIf await_barrier (\(BarrierPass i) _ minfo ->
     runMaybeT $ do
       (_, _, lvl) <- MaybeT $ return minfo
       guard (i == M0.MeroClusterStopping lvl)
       return ()
     ) $ \() -> nextBootLevel

   directly stop_service $ do
     Just (_, node, _) <- get Local
     phaseLog "info" $ printf "%s stopped all mero services - stopping halon mero service."
                              (show node)
     promulgateRC $ encodeP $ ServiceStopRequest node m0d
     continue finish

   directly finish $ do
     get Local >>= mapM_ (\(eid, node, _) -> do
        mh  <- getStorageRC
        forM_ mh $ \(NodesRunningTeardown nodes) ->
          putStorageRC $ NodesRunningTeardown $ Map.delete  node nodes
        messageProcessed eid)
     phaseLog "debug" $ "teardown finish"
     stop

   startFork initialize Nothing
   where
     getProcessesByFid rg = mapMaybe (`M0.lookupConfObjByFid` rg)

     -- XXX: currently we don't mark node during this process, it seems that in
     --      we should receive notification about node death by other means,
     --      and treat that appropriatelly.
     markNodeFailedTeardown = const $ return ()

-- | Upon receiving 'NewMeroServer' message, bootstraps the given
-- node.
--
-- * Start halon's mero service on the node. This starts the
-- mero-kernel system service. The halon service sends back a message
-- to the RC with indicating whether the kernel module managed to
-- start or not. If the module failed, cluster is put in a
-- 'M0.MeroClusterFailed' state. Upon successful start, a
-- communication channel with mero is established.
--
-- * Node starts to bootstrap its processes: we start from processes
-- marked with boot level 0 and proceed in increasing order.
--
-- * Between levels, 'notifyOnClusterTransition' is called which
-- serves as a barrier used for synchronisation of boot steps across
-- nodes. See the comment of 'notifyOnClusterTransition' for details.
--
-- * After all boot level 0 processes are started, we set the
-- principal RM for the cluster if present on the note and not yet set
-- for the cluster. If any processes come back as failed in any boot
-- level, we put the cluster in a failed state.
--
-- * Boot level 1 starts after passing a barrier.
--
-- * Clients start after boot level 1 is finished and cluster enters
-- the 'M0.MeroClusterRunning' state. Currently this means
-- 'M0.PLM0t1fs' processes.
ruleNewMeroServer :: Definitions LoopState ()
ruleNewMeroServer = define "new-mero-server" $ do
    new_server <- phaseHandle "initial"
    svc_up_now <- phaseHandle "svc_up_now"
    svc_up_already <- phaseHandle "svc_up_already"
    boot_level_0_complete <- phaseHandle "boot_level_0_complete"
    boot_level_1 <- phaseHandle "boot_level_1"
    boot_level_1_complete <- phaseHandle "boot_level_1_complete"
    start_clients <- phaseHandle "start_clients"
    start_clients_complete <- phaseHandle "start_clients_complete"
    bootstrap_failed <- phaseHandle "bootstrap_failed"
    cluster_failed <- phaseHandle "cluster_failed"
    finish <- phaseHandle "finish"
    end <- phaseHandle "end"

    let processStartedProcs :: [Either Fid (Fid, String)]
                            -> PhaseM LoopState l ([M0.Process], [(M0.Process, String)])
        processStartedProcs e = case partitionEithers e of
          (okProcs', failedProcs') -> do
            (okProcs :: [M0.Process]) <- catMaybes <$> mapM lookupConfObjByFid okProcs'
            -- Mark successful processes as online, and others as failed.
            forM_ okProcs $ \p -> modifyGraph $ G.connectUniqueFrom p R.Is M0.ProcessBootstrapped
                                          >>> G.connectUniqueFrom p R.Is M0.PSOnline
            mfailedProcs <- forM failedProcs' $ \(f,r) -> lookupConfObjByFid f >>= \mp -> do
              phaseLog "warning" $ "Process " ++ show f
                                ++ " failed to start: " ++ r
              traverse_ (\(p :: M0.Process) ->
                modifyGraph $ G.connectUniqueFrom p R.Is (M0.PSFailed r)) mp
              return (mp, r)
            let failedProcs = [ (p, r) | (Just p, r) <- mfailedProcs ]
            return (okProcs, failedProcs)

    setPhase new_server $ \(HAEvent eid (NewMeroServer node@(R.Node nid)) _) -> do
      phaseLog "info" $ "NewMeroServer received for node " ++ show nid

      rg <- getLocalGraph
      case listToMaybe $ G.connectedTo R.Cluster R.Has rg of
        Just M0.MeroClusterStopped -> do
          phaseLog "info" "Cluster is stopped."
          continue finish
        Just M0.MeroClusterStopping{} -> do
          phaseLog "info" "Cluster is stopping."
          continue finish
        Just M0.MeroClusterFailed -> do
          phaseLog "info" "Cluster is in failed state, doing nothing."
          continue finish
        _ -> return ()

      fork CopyNewerBuffer $ do
        findNodeHost node >>= \case
          Just host -> do
            put Local $ Just (node, host, eid)
            phaseLog "info" "Starting core bootstrap"
            let mlnid =
                      (listToMaybe [ ip | M0.LNid ip <- G.connectedTo host R.Has rg ])
                  <|> (listToMaybe $ [ ip | CI.Interface { CI.if_network = CI.Data, CI.if_ipAddrs = ip:_ }
                                          <- G.connectedTo host R.Has rg ])
            case mlnid of
              Nothing -> do
                phaseLog "warn" $ "Unable to find Data IP addr for host "
                                ++ show host
                continue finish
              Just lnid -> do
                createMeroKernelConfig host $ lnid ++ "@tcp"
                startMeroService host node
                switch [svc_up_now, bootstrap_failed, timeout 1000000 svc_up_already]
          Nothing -> do
            phaseLog "error" $ "Can't find R.Host for node " ++ show node
            continue finish

    -- Service comes up as a result of this invocation
    setPhaseIf svc_up_now declareMeroChannelOnNode $ \chan -> do
      Just (_, host, _) <- get Local
      -- Legitimate to ignore the event id as it should be handled by the default
      -- 'declare-mero-channel' rule.
      procs <- startNodeProcesses host chan (M0.PLBootLevel (M0.BootLevel 0)) True
      case procs of
        [] -> let state = M0.MeroClusterStarting (M0.BootLevel 1) in do
          notifyOnClusterTranstion state BarrierPass Nothing
          switch [boot_level_1, timeout 5000000 finish]
        _ -> continue boot_level_0_complete

    -- Service is already up
    directly svc_up_already $ do
      Just (node, host, _) <- get Local
      rg <- getLocalGraph
      m0svc <- lookupRunningService node m0d
      case m0svc >>= meroChannel rg of
        Just chan -> do
          procs <- startNodeProcesses host chan (M0.PLBootLevel (M0.BootLevel 0)) True
          case procs of
            [] -> let state = M0.MeroClusterStarting (M0.BootLevel 1) in do
              notifyOnClusterTranstion state BarrierPass Nothing
              switch [boot_level_1, timeout 5000000 finish]
            _ -> continue boot_level_0_complete
        Nothing -> switch [svc_up_now, timeout 5000000 finish]

    -- Wait until every process comes back as finished bootstrapping
    setPhaseIf boot_level_0_complete processControlOnNode $ \(eid, e) -> do
      (okProcs, failedProcs) <- processStartedProcs e
      rms <- listToMaybe
                . filter (\s -> M0.s_type s == CST_RMS)
                . join
                . filter (\s -> CST_MGS `elem` fmap M0.s_type s)
              <$> mapM getChildren okProcs
      traverse_ setPrincipalRMIfUnset rms
      case failedProcs of
        [] -> do
          let state = M0.MeroClusterStarting (M0.BootLevel 1)
          notifyOnClusterTranstion state BarrierPass (Just eid)
          switch [boot_level_1, timeout 5000000 finish]
        _ -> continue cluster_failed

    setPhaseIf boot_level_1 (barrierPass (M0.MeroClusterStarting (M0.BootLevel 1))) $ \() -> do
      Just (node, host, _) <- get Local
      g <- getLocalGraph
      m0svc <- lookupRunningService node m0d
      case m0svc >>= meroChannel g of
        Just chan -> do
          procs <- startNodeProcesses host chan (M0.PLBootLevel (M0.BootLevel 1)) True
          case procs of
            [] -> let state = M0.MeroClusterRunning in do
              notifyOnClusterTranstion state BarrierPass Nothing
              switch [start_clients, timeout 5000000 finish]
            _ -> continue boot_level_1_complete
        Nothing -> do
          phaseLog "error" $ "Can't find service for node " ++ show node
          continue finish

    -- Wait until every process comes back as finished bootstrapping
    setPhaseIf boot_level_1_complete processControlOnNode $ \(eid, e) -> do
      (_, failedProcs) <- processStartedProcs e
      case failedProcs of
        [] -> do
          let state = M0.MeroClusterRunning
          notifyOnClusterTranstion state BarrierPass (Just eid)
          switch [start_clients, timeout 5000000 finish]
        _ -> continue cluster_failed


    setPhaseIf start_clients (barrierPass M0.MeroClusterRunning) $ \() -> do
      Just (node, host, _) <- get Local
      rg <- getLocalGraph
      m0svc <- lookupRunningService node m0d
      case m0svc >>= meroChannel rg of
        Just chan -> do
          procs <- startNodeProcesses host chan M0.PLM0t1fs False
          if null procs
            then continue finish
            else continue start_clients_complete
        Nothing -> continue finish

    -- Mark clients as coming up successfully.
    setPhaseIf start_clients_complete processControlOnNode $ \(eid, e) -> do
      _ <- processStartedProcs e
      messageProcessed eid
      continue finish

    -- because mero-kernel start is part of the service start unlike
    -- the m0d units, we need to notify explicitly about its failure
    -- rather than using the mechanism we have for m0d
    setPhase bootstrap_failed $ \(HAEvent eid (M0.BootstrapFailedNotification msg) _) -> do
      phaseLog "server-bootstrap" $ "Cluster bootstrap has failed: " ++ show msg
      modifyGraph $ G.connectUnique R.Cluster R.Has M0.MeroClusterFailed
      messageProcessed eid
      continue cluster_failed

    directly cluster_failed $ do
      Just (n, _, eid) <- get Local
      phaseLog "server-bootstrap" $ "Finished bootstrapping with failure "
                                 ++ show n
      modifyGraph $ G.connectUnique R.Cluster R.Has M0.MeroClusterFailed
      messageProcessed eid
      continue end

    directly finish $ do
      Just (n, _, eid) <- get Local
      phaseLog "server-bootstrap" $ "Finished bootstrapping mero server at "
                                 ++ show n
      messageProcessed eid
      continue end

    directly end stop

    startFork new_server Nothing

-- | Rule handling dynamic client addition.
ruleDynamicClient :: Definitions LoopState ()
ruleDynamicClient =  define "dynamic-client-discovery" $ do

  new_mero_client <- phaseHandle "new-mero-client"
  end <- phaseHandle "end"
  confd_running <- phaseHandle "confd-running"
  config_created <- phaseHandle "client-config-created"
  finish <- phaseProcessMessage end
  query_host_info <- queryHostInfo config_created finish

  -- When we see a new client message, we check to see whether the filesystem
  -- is loaded. If not, we mark it as an HA_M0CLIENT and wait for this function
  -- to be called again. When the filesystem is loaded, we check whether this
  -- has been marked as a client and, if so, continue with provisioning.
  setPhase new_mero_client $ \(HAEvent eid (NewMeroClient node) _) -> do
    modify Local $ over (rlens fldUUID) (const . Field $ Just eid)
    modify Local $ over (rlens fldNode) (const . Field $ Just node)
    getFilesystem >>= \case
      Nothing -> findNodeHost node >>= \case
        Just host -> do
          phaseLog "info" $ "Configuration data not loaded. Marking "
                          ++ show node
                          ++ " as prospective HA_M0CLIENT."
          modifyGraph $ G.connect host R.Has R.HA_M0CLIENT
          continue finish
        Nothing -> do
          phaseLog "error" $ "NewMeroClient sent for node with no host: "
                          ++ show node
          continue finish
      Just _ -> do
        continue query_host_info

  directly config_created $ do
    Just fs <- getFilesystem
    Just host <- getField . rget fldHost
                <$> get Local
    Just hhi <- getField . rget fldHostHardwareInfo
                <$> get Local
    createMeroClientConfig fs host hhi
    -- TODO better notify function which takes a comparator
    notifyOnClusterTranstion (M0.MeroClusterStarting (M0.BootLevel 1)) BarrierPass Nothing
    notifyOnClusterTranstion M0.MeroClusterRunning BarrierPass Nothing
    continue confd_running

  setPhaseIf confd_running (barrierPass (M0.MeroClusterStarting (M0.BootLevel 1))) $ \() -> do
    syncStat <- syncToConfd
    case syncStat of
      Left err -> do
        phaseLog "error" $ "Unable to sync new client to confd: " ++ show err
      Right () -> do
        Just node <- getField . rget fldNode
                    <$> get Local
        promulgateRC $ NewMeroServer node
    continue finish

  directly end stop

  startFork new_mero_client $ (fldNode =: Nothing)
                          <+> (fldUUID =: Nothing)
                          <+> (fldHost =: Nothing)
                          <+> (fldHostHardwareInfo =: Nothing)
                          <+> RNil

-- | Rule fragment: phase which ensures messages are processed.
phaseProcessMessage :: (FldUUID ∈ l)
                    => Jump PhaseHandle -- ^ On completion
                    -> RuleM LoopState (FieldRec l) (Jump PhaseHandle)
phaseProcessMessage andThen = do
  ppm <- phaseHandle "phaseProcessMessage::ppm"

  directly ppm $ do
    meid <- getField . rget fldUUID <$> get Local
    traverse_ messageProcessed meid
    continue andThen

  return ppm

-- | Rule fragment: query node hardware information.
queryHostInfo :: forall l. (FldHostHardwareInfo ∈ l, FldHost ∈ l, FldNode ∈ l)
              => Jump PhaseHandle -- ^ Phase handle to jump to on completion
              -> Jump PhaseHandle -- ^ Phase handle to jump to on failure.
              -> RuleM LoopState (FieldRec l) (Jump PhaseHandle) -- ^ Handle to start on
queryHostInfo andThen orFail = do
    query_info <- phaseHandle "queryHostInfo::query_info"
    info_returned <- phaseHandle "queryHostInfo::info_returned"

    directly query_info $ do
      Just node@(R.Node nid) <- getField . rget fldNode <$> get Local
      phaseLog "info" $ "Querying system information from " ++ show node
      liftProcess . void . spawnLocal . void
        $ spawnAsync nid $ $(mkClosure 'getUserSystemInfo) node
      continue info_returned

    setPhaseIf info_returned systemInfoOnNode $ \(eid,info) -> do
      Just node <- getField . rget fldNode <$> get Local
      phaseLog "info" $ "Received system information about " ++ show node
      mhost <- findNodeHost node
      case mhost of
        Just host -> do
          modify Local $ over (rlens fldHostHardwareInfo) (const . Field $ Just info)
          modify Local $ over (rlens fldHost) (const . Field $ Just host)
          syncGraphProcessMsg eid
          continue andThen
        Nothing -> do
          phaseLog "error" $ "Unknown host"
          messageProcessed eid
          continue orFail

    return query_info
  where
    systemInfoOnNode :: HAEvent SystemInfo
                     -> g
                     -> FieldRec l
                     -> Process (Maybe (UUID, HostHardwareInfo))
    systemInfoOnNode (HAEvent eid (SystemInfo node' info) _) _ l = let
        Just node = getField . rget fldNode $ l
      in
        return $ if node == node' then Just (eid, info) else Nothing
