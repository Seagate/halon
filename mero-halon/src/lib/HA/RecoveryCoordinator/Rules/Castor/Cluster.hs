-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE GADTs                 #-}
module HA.RecoveryCoordinator.Rules.Castor.Cluster where

import           HA.EventQueue.Types
import           HA.Encode
import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           Mero.Notification (Set(..))
import           Mero.Notification.HAState (Note(..))

import qualified HA.ResourceGraph as G
import           HA.RecoveryCoordinator.Actions.Core
import           HA.RecoveryCoordinator.Actions.Hardware
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Actions.Service (lookupRunningService)
import           HA.RecoveryCoordinator.Events.Castor.Cluster
import           HA.RecoveryCoordinator.Events.Mero
import           HA.RecoveryCoordinator.Rules.Mero.Conf
import           HA.RecoveryCoordinator.Rules.Castor.Process
import           HA.RecoveryCoordinator.Rules.Castor.Node
import           HA.Service (ServiceStopRequest(..))
import           HA.Services.Mero
import           HA.Services.Mero.CEP (meroChannel)
import           Mero.ConfC (ServiceType(..))
import           Network.CEP

import           Control.Applicative
import           Control.Category
import           Control.Distributed.Process hiding (catch, try)
import           Control.Distributed.Process.Closure (mkClosure)
import           Control.Lens
import           Control.Monad (guard, join, unless, when, void)
import           Control.Monad.Trans.Maybe

import           Data.Binary (Binary)
import           Data.List ((\\))
import           Data.Maybe (catMaybes, listToMaybe, mapMaybe, fromMaybe, isJust)
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Foldable
import           Data.Traversable (forM)
import           Data.Typeable
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
  , ruleServiceNotificationHandler
  , ruleStopMeroProcess
  , ruleProcessControlStop
  , ruleProcessControlStart
  , adjustClusterState
  , updatePrincipalRM
  , stopMeroClient
  , startMeroClient
  , nodeRules
  ]

-- | Local state used in 'ruleServiceNotificationHandler'.
type ClusterTransitionLocal =
  Maybe ( UUID
        , Maybe (M0.Service, M0.ServiceState)
        , Maybe (M0.Process, M0.ProcessState)
        , [(M0.Service, M0.ServiceState)]
        )

-- | Handle notification for service states. This rule is responsible
-- for logic that sets service states, decides what to do with the
-- parent process based on the service states and on unblocking the
-- cluster bootstrap barrier if bootstrap is happening.
ruleServiceNotificationHandler :: Definitions LoopState ()
ruleServiceNotificationHandler = define "service-notification-handler" $ do
   start_rule <- phaseHandle "start"
   services_notified <- phaseHandle "services-notified"
   process_notified <- phaseHandle "process-notified"
   timed_out <- phaseHandle "timed-out"
   timed_out_prefork <- phaseHandle "timed-out-prefork"
   finish <- phaseHandle "finish"
   end <- phaseHandle "end"

   let startState :: ClusterTransitionLocal
       startState = Nothing

       viewProc :: ClusterTransitionLocal -> Maybe (M0.Process, M0.ProcessState)
       viewProc = maybe Nothing (\(_, _, proci, _) -> proci)

       viewMsgs :: ClusterTransitionLocal -> Maybe [AnyStateSet]
       viewMsgs = maybe Nothing (\(_, _, _, msgs) -> Just $ uncurry stateSet <$> msgs)

       getInterestingSrvs :: HAEvent Set -> PhaseM LoopState l (Maybe (UUID, [(M0.Service, M0.ServiceState)]))
       getInterestingSrvs (HAEvent eid (Set ns) _) = do
         rg <- getLocalGraph
         let convert = \case
               M0.M0_NC_ONLINE -> Just M0.SSOnline
               M0.M0_NC_FAILED -> Just M0.SSOffline
               _ -> Nothing
             srvs = mapMaybe (\(Note fid' typ) -> (,) <$> M0.lookupConfObjByFid fid' rg <*> convert typ) ns
         case srvs of
           [] -> return Nothing
           xs -> return $ Just (eid, xs)

       ackMsg = get Local >>= \case
         Just (eid, _, _, _) -> done eid
         lst -> phaseLog "warn" $ "In finish with strange local state: " ++ show lst

   setPhase start_rule $ \msg@(HAEvent eid (Set _) _) -> do
     todo eid
     getInterestingSrvs msg >>= \case
       Nothing -> done eid
       Just (_, services) -> do
         phaseLog "info" $ "Cluster transition for " ++ show services
         let msgs = uncurry stateSet <$> services
         put Local $ Just (eid, Nothing, Nothing, services)
         applyStateChanges msgs
         switch [services_notified, timeout 15 timed_out_prefork]

   setPhaseAllNotified services_notified viewMsgs $ do
     rg <- getLocalGraph
     Just (eid, _, _, services) <- get Local
     case services of
       [] -> done eid
       _ -> do
         for_ services $ \(srv, st) -> fork NoBuffer $ do
           -- find the process, the service belongs to, check if all
           -- services are online, if yes then update process state and
           -- notify barrier
           phaseLog "info" $ "Transition for " ++ show (srv, M0.fid . fst <$> services, eid)
           case (st, listToMaybe $ G.connectedFrom M0.IsParentOf srv rg) of
             (M0.SSOnline, Just (p :: M0.Process)) -> do
               let allSrvs :: [M0.Service]
                   allSrvs = G.connectedTo p M0.IsParentOf rg
                   onlineSrvs = [ s | s <- allSrvs
                                    , M0.SSOnline <- G.connectedTo s R.Is rg ]
                   newProcessState = M0.PSOnline

               put Local $ Just (eid, Just (srv, st), Just (p, newProcessState), services)
               if length allSrvs == length onlineSrvs
               then do phaseLog "info" $
                         unwords [ "All services for", show p
                                 , "online, marking process as online" ]
                       modifyGraph $ G.connectUniqueFrom p R.Is M0.ProcessBootstrapped


                       -- TODO: maybe we should not notify here but instead
                       -- notify after mero itself sends the process
                       -- notification
                       applyStateChanges [stateSet p newProcessState]
                       switch [process_notified, timeout 15 timed_out]

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
             err -> do phaseLog "warn" $ "Couldn't handle bad state for " ++ show srv
                                      ++ ": " ++ show err
                       continue finish
         done eid

   setPhaseNotified process_notified viewProc $ \(p, pst) -> do
     phaseLog "info" $ "Process " ++ show (M0.fid p) ++ " => " ++ show pst
     Just (_, srvi, _, _) <- get Local

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

   directly timed_out_prefork $ do
     phaseLog "warn" $ "Waited too long for a notification ack"
     ackMsg

   directly timed_out $ do
     phaseLog "warn" $ "Waited too long for a notification ack"
     -- TODO: can we do anything worthwhile here?
     continue finish

   directly finish $ do
     ackMsg
     continue end

   directly end stop

   start start_rule startState

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
                       let services' = map (\srv -> (srv, M0.getState srv rg)) services
                       return (process, ReportClusterProcess st services')
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
      modifyGraph $ G.connectUnique R.Cluster R.Has (M0.MeroClusterStopping (M0.BootLevel maxTeardownLevel))
      let nodes =
            [ node | host <- G.connectedTo R.Cluster R.Has rg :: [R.Host]
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
notifyOnClusterTransition :: (Binary a, Typeable a)
                          => (M0.MeroClusterState -> Bool) -- ^ States to notify on
                          -> (M0.MeroClusterState -> a) -- Notification to send
                          -> Maybe UUID -- Message to declare processed
                          -> PhaseM LoopState l ()
notifyOnClusterTransition desiredState msg meid = do
  newState <- calculateMeroClusterStatus
  phaseLog "notifyOnClusterTransition:state" $ show newState
  if desiredState newState then do
    phaseLog "notifyOnClusterTransition:state:" "OK"
    modifyGraph $ G.connectUnique R.Cluster R.Has newState
    syncGraphCallback $ \self proc -> do
      usend self (msg newState)
      forM_ meid proc
  else
    forM_ meid syncGraphProcessMsg

-- | Message guard: Check if the barrier being passed is for the
-- correct level. This is used during 'ruleNewMeroServer' with the
-- actual 'BarrierPass' message being emitted from
-- 'notifyOnClusterTransition'.
barrierPass :: (M0.MeroClusterState -> Bool)
            -> BarrierPass
            -> g
            -> l
            -> Process (Maybe ())
barrierPass rightState (BarrierPass state') _ _ =
  if rightState state' then return (Just ()) else return Nothing

-- | Message guard: Check if the service process is running on this node.
declareMeroChannelOnNode :: HAEvent MeroChannelDeclared
                         -> LoopState
                         -> Maybe (R.Node, R.Host, y)
                         -> Process (Maybe (TypedChannel ProcessControlMsg))
declareMeroChannelOnNode _ _ Nothing = return Nothing
declareMeroChannelOnNode (HAEvent _ (MeroChannelDeclared sp _ cc) _) ls (Just (node, _, _)) =
  case G.isConnected node R.Runs sp $ lsGraph ls of
    True -> return $ Just cc
    False -> return Nothing

-- | Given 'M0.BootLevel', generate a corresponding 'M0.ProcessLabel'.
mkLabel :: M0.BootLevel -> M0.ProcessLabel
mkLabel bl@(M0.BootLevel l)
  | l == maxTeardownLevel = M0.PLM0t1fs
  | otherwise = M0.PLBootLevel bl

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
-- * If there are still processes waiting to stop, do nothing: we
-- still have nodes that need to report back their results or
-- otherwise fail.
--
-- * If there are no more processes on this boot level and cluster is
-- on boot level 0 (last), simply mark the cluster as stopped.

-- * If there are no more processes on this level and it's not the last level:
--
--     1. Set global cluster state to the next level
--     2. Send out a 'BarrierPass' message: this serves as a barrier
--        release, blocked nodes wait for this message and when they
--        see it, they know cluster progressed onto the given level
--        and they can start teardown of that level.
--
ruleTearDownMeroNode :: Definitions LoopState ()
ruleTearDownMeroNode = define "teardown-mero-server" $ do
   initialize <- phaseHandle "initialization"
   teardown   <- phaseHandle "teardown"
   teardown_exec <- phaseHandle "teardown-exec"
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
   -- Check if there are any processes left to be stopped on current bootlevel.
   -- If there are any process - then just process current message (meid),
   -- If there are no process left then move cluster to next bootlevel and prepare
   -- all technical information in RG, then emit BarrierPassed function.
   let notifyBarrier meid = do
         Just (_,_,b) <- get Local
         notifyOnClusterTransition (>= (M0.MeroClusterStopping b)) BarrierPass meid

   setPhase initialize $ \(HAEvent eid (StopMeroServer node) _) -> getStorageRC  >>= \nodes ->
     case Map.lookup node =<< nodes of
       Nothing -> do
         putStorageRC $ NodesRunningTeardown $ Map.insert node eid (fromMaybe Map.empty nodes)
         fork CopyNewerBuffer $ do
           put Local (Just (eid, node, M0.BootLevel maxTeardownLevel))
           continue teardown
       Just eid' -> do
         phaseLog "debug" $ show node ++ " already being processed - ignoring."
         unless (eid == eid') $ messageProcessed eid

   directly teardown $ do
     Just (_, node, lvl@(M0.BootLevel i)) <- get Local
     phaseLog "info" $ "Tearing down " ++ show lvl
     cluster_lvl <- fromMaybe M0.MeroClusterStopped
                     . listToMaybe . G.connectedTo R.Cluster R.Has <$> getLocalGraph
     case cluster_lvl of
       M0.MeroClusterStopping s
          | i < 0 && s < lvl -> continue stop_service
          | s < lvl -> do
              phaseLog "debug" $ printf "%s is on %s while cluster is on %s - skipping"
                                        (show node) (show lvl) (show s)
              nextBootLevel
          | s == lvl  -> continue teardown_exec
          | otherwise -> do
              phaseLog "debug" $ printf "%s is on %s while cluster is on %s - waiting for barriers."
                                        (show node) (show lvl) (show s)
              notifyBarrier Nothing
              switch [ await_barrier
                     , timeout tearDownTimeout teardown_timeout ]
       _  -> continue finish

   directly teardown_exec $ do
     Just (_, node, lvl) <- get Local
     rg <- getLocalGraph

     let lbl = case lvl of
           x | x == m0t1fsBootLevel -> M0.PLM0t1fs
           x -> M0.PLBootLevel x

     -- Unstopped processes on this node
     let stillUnstopped = getLabeledProcesses lbl
                          ( \proc g -> not . null $
                          [ () | state <- G.connectedTo proc R.Is g
                               , state `elem` [M0.PSOnline, M0.PSStopping, M0.PSStarting]
                               , m0node <- G.connectedFrom M0.IsParentOf proc g
                               , Just n <- [M0.m0nodeToNode m0node g]
                               , n == node
                          ] ) rg

     case stillUnstopped of
       [] -> do phaseLog "info" $ printf "%s R.Has no services on level %s - skipping to the next level"
                                          (show node) (show lvl)
                nextBootLevel
       ps -> do maction <- runMaybeT $ do
                  m0svc <- MaybeT $ lookupRunningService node m0d
                  ch    <- MaybeT . return $ meroChannel rg m0svc
                  return $ do
                    stopNodeProcesses ch ps
                    nextBootLevel
                forM_ maction id
                phaseLog "debug" $ printf "Can't find data for %s - continue to timeout" (show node)
                continue teardown_timeout

   directly teardown_timeout $ do
     Just (_, node, lvl) <- get Local
     phaseLog "warning" $ printf "%s failed to stop services (timeout)" (show node)
     rg <- getLocalGraph
     let failedProcs = getLabeledNodeProcesses node (mkLabel lvl) rg
     applyStateChanges $ (\p -> stateSet p $ M0.PSFailed "Timeout on stop.")
                          <$> failedProcs
     markNodeFailedTeardown node
     continue finish

   setPhaseIf await_barrier (\(BarrierPass i) _ minfo ->
     runMaybeT $ do
       (_, _, lvl) <- MaybeT $ return minfo
       guard (i <= M0.MeroClusterStopping lvl)
       return ()
     ) $ \() -> continue teardown

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
    svc_up_now <- phaseHandle "svc_up_now"
    boot_level_1 <- phaseHandle "boot_level_1"
    start_clients <- phaseHandle "start_clients"
    start_clients_complete <- phaseHandle "start_clients_complete"
    cluster_failed <- phaseHandle "cluster_failed"
    finish <- phaseHandle "finish"
    end <- phaseHandle "end"

    setPhase svc_up_now $ \(HAEvent eid (MeroChannelDeclared sp _ chan) _) -> do
     rg <- getLocalGraph
     case listToMaybe $ G.connectedTo R.Cluster R.Has rg of
        Just M0.MeroClusterStopped -> phaseLog "info" "Cluster is stopped."
        Just M0.MeroClusterStopping{} -> phaseLog "info" "Cluster is stopping."
        _ -> let mnode = listToMaybe $ G.connectedFrom R.Runs sp rg
             in case mnode of
                  Nothing -> phaseLog "error" "can't find mero node for service"
                  Just node -> findNodeHost node >>= \case
                    Nothing -> phaseLog "error" $ "can't find host for node " ++ show node
                    Just host -> do
                      phaseLog "info" $ "halon-m0d service started on " ++ show host
                      todo eid
                      fork CopyBuffer $ do
                        put Local $ Just (node, host, eid)
                        _ <- startNodeProcesses host chan (M0.PLBootLevel (M0.BootLevel 0)) True
                        switch [boot_level_1, timeout 180 cluster_failed]

    setPhaseIf boot_level_1 (barrierPass (>= (M0.MeroClusterStarting (M0.BootLevel 1)))) $ \() -> do
      Just (node, host, _) <- get Local
      g <- getLocalGraph
      m0svc <- lookupRunningService node m0d
      case m0svc >>= meroChannel g of
        Just chan -> do
          procs <- startNodeProcesses host chan (M0.PLBootLevel (M0.BootLevel 1)) True
          when (null procs) $ do
            phaseLog "warn" "Empty list of processes being started"
          switch [start_clients, timeout 180 cluster_failed]
        Nothing -> do
          phaseLog "error" $ "Can't find service for node " ++ show node
          continue finish

    setPhaseIf start_clients (barrierPass (>= M0.MeroClusterRunning)) $ \() -> do
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

    directly cluster_failed $ do
      Just (n, _, eid) <- get Local
      phaseLog "server-bootstrap" $ "Finished bootstrapping with failure "
                                 ++ show n
      modifyGraph $ G.connectUnique R.Cluster R.Has M0.MeroClusterFailed
      done eid
      continue end

    directly finish $ do
      Just (n, _, eid) <- get Local
      phaseLog "server-bootstrap" $ "Finished bootstrapping mero server at "
                                 ++ show n
      done eid
      continue end

    directly end stop

    startFork svc_up_now Nothing

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
    continue confd_running

  setPhaseIf confd_running (barrierPass (>= (M0.MeroClusterStarting (M0.BootLevel 1)))) $ \() -> do
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

-- | This is a rule which interprets state change events and is responsible for
-- changing the state of the cluster accordingly'
adjustClusterState :: Definitions LoopState ()
adjustClusterState = defineSimpleTask "update-cluster-state" $ \msg -> do
    let findChanges = do
          InternalObjectStateChange chs <- liftProcess $ decodeP msg
          return $  mapMaybe (\(AnyStateChange (_ :: a) _old new _) ->
                       case eqT :: Maybe (a Data.Typeable.:~: M0.Process) of
                         Just Refl -> Just new
                         Nothing   -> Nothing) chs
    recordedState <- fromMaybe M0.MeroClusterStopped . listToMaybe
        . G.connectedTo R.Cluster R.Has <$> getLocalGraph
    case recordedState of
      M0.MeroClusterStarting{} -> do
        phaseLog "debug" "starting"
        anyDown <- any checkDown <$> findChanges
        if anyDown
        then do phaseLog "debug" "process failed - put cluster to failed."
                modifyGraph $ G.connectUnique R.Cluster R.Has M0.MeroClusterFailed
        else do phaseLog "debug" "no failed processes"
                anyUp <- any checkUp <$> findChanges
                when anyUp $ do
                  phaseLog "debug" $ "at least one process up - trying: " ++ show recordedState
                  notifyOnClusterTransition (> recordedState) BarrierPass Nothing
      M0.MeroClusterStopping{} -> do
        anyDown <- any checkDown <$> findChanges
        when anyDown $ do
          phaseLog "debug" $ "at least one process up - trying: " ++ show recordedState
          notifyOnClusterTransition (> recordedState) BarrierPass Nothing
      _ -> return ()
  where
    checkUp M0.PSOnline = True
    checkUp _        = False
    checkDown M0.PSFailed{} = True
    checkDown M0.PSOffline  = True
    checkDown M0.PSInhibited{} = True
    checkDown _             = False

-- | This is a rule catches death of the Principal RM and elects new one.
updatePrincipalRM :: Definitions LoopState ()
updatePrincipalRM = defineSimpleTask "update-principal-rm" $ \msg -> do
    let findChanges = do
          InternalObjectStateChange chs <- liftProcess $ decodeP msg
          return $ mapMaybe (\(AnyStateChange (a :: a) _old new _) ->
                       case eqT :: Maybe (a Data.Typeable.:~: M0.Process) of
                         Just Refl -> Just (new, a)
                         Nothing   -> Nothing) chs
    mrm <- getPrincipalRM
    unless (isJust mrm) $ do
      procs <- map snd . filter ((==M0.PSOnline) . fst) <$> findChanges
      rms <- listToMaybe
               . filter (\s -> M0.s_type s == CST_RMS)
               . join
               . filter (\s -> CST_MGS `elem` fmap M0.s_type s)
               <$> mapM (getChildren :: M0.Process -> PhaseM LoopState l [M0.Service]) procs
      traverse_ setPrincipalRMIfUnset rms

-- | Stop m0t1fs service with given fid.
-- 1. we check if there is halon:m0d service on the node
-- 2. find if there is m0t1fs service with a given fid
stopMeroClient :: Definitions LoopState ()
stopMeroClient = defineSimpleTask "stop-client-request" $ \(StopMeroClientRequest fid) -> do
  phaseLog "info" $ "Stop mero client " ++ show fid ++ " requested."
  mproc <- lookupConfObjByFid fid
  forM_ mproc $ \proc -> do
    rg <- getLocalGraph
    if G.isConnected proc R.Has M0.PLM0t1fs rg
    then applyStateChanges [stateSet (proc::M0.Process) M0.PSStopping]
    else phaseLog "warning" $ show fid ++ " is not a client process."

startMeroClient :: Definitions LoopState ()
startMeroClient = defineSimpleTask "start-client-request" $ \(StartMeroClientRequest fid) -> do
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
           startMeroProcesses chan [proc] M0.PLM0t1fs False
        Nothing -> phaseLog "warning" $ "can't find mero channel."
    else phaseLog "warning" $ show fid ++ " is not a client process."
