-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
module HA.RecoveryCoordinator.Rules.Castor.Cluster where

import           HA.EventQueue.Types
import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           HA.Resources.TH

import qualified HA.ResourceGraph as G
import           HA.RecoveryCoordinator.Actions.Core
import           HA.RecoveryCoordinator.Actions.Hardware
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Actions.Service (lookupRunningService)
import           HA.RecoveryCoordinator.Events.Castor.Cluster
import           HA.RecoveryCoordinator.Events.Mero
import           HA.Service (encodeP, ServiceStopRequest(..))
import           HA.Services.Mero
import           HA.Services.Mero.CEP (meroChannel)
import           Mero.ConfC (Fid(..), ServiceType(..))
import           Network.CEP

import           Control.Category
import           Control.Distributed.Process
import           Control.Distributed.Process.Closure (mkClosure)
import           Control.Monad (guard, join, unless, when, void)
import           Control.Monad.Trans.Maybe
import           Data.Binary (Binary)
import           Data.Either (lefts, rights)
import           Data.Hashable (Hashable)
import           Data.Maybe (catMaybes, listToMaybe, mapMaybe, fromMaybe)
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Foldable
import           Data.Proxy (Proxy(..))
import           Data.Typeable (Typeable)
import           GHC.Generics (Generic)
import           System.Posix.SysInfo
import           Text.Printf
import           Prelude hiding ((.), id)

clusterRules :: Definitions LoopState ()
clusterRules = sequence_
  [ ruleClusterStatus
  , ruleClusterStart
  , ruleClusterStop
  , ruleTearDownMeroNode
  , ruleNewMeroServer
  , ruleNewMeroClient
  ]

-- | Query mero cluster status.
ruleClusterStatus :: Definitions LoopState ()
ruleClusterStatus = defineSimple "cluster-status-request"
  $ \(HAEvent eid  (ClusterStatusRequest ch) _) -> do
      rg <- getLocalGraph
      liftProcess $ sendChan ch . listToMaybe $ G.connectedTo R.Cluster R.Has rg
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
                     in flip (foldr (\p -> G.connectUniqueFrom p R.Is M0.M0_NC_ONLINE)) procs
                          >>> flip (foldr (\s -> G.connectUniqueFrom s R.Is M0.M0_NC_ONLINE)) srvs
                              $ g
                  announceMeroNodes
                  syncGraphCallback $ \pid proc -> do
                    sendChan ch (StateChangeStarted pid)
                    proc eid
               M0.MeroClusterStarting{} -> Left $ StateChangeOngoing st
               M0.MeroClusterStopping{} -> Left $ StateChangeError $ "cluster is stopping: " ++ show st
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
               M0.MeroClusterRunning    -> Right $ do
                  modifyGraph $ G.connectUnique R.Cluster R.Has (M0.MeroClusterStopping (M0.BootLevel maxTeardownLevel))
                  let nodes =
                        [ node | host <- G.getResourcesOfType rg :: [R.Host]
                               , node <- take 1 (G.connectedTo host R.Runs rg) :: [R.Node] ]
                  forM_ nodes $ promulgateRC . StopMeroServer
                  syncGraphCallback $ \pid proc -> do
                    sendChan ch (StateChangeStarted pid)
                    proc eid
               M0.MeroClusterStopping{} -> Left $ StateChangeOngoing st
               M0.MeroClusterStarting{} -> Left $ StateChangeError $ "cluster is starting: " ++ show st
               M0.MeroClusterStopped    -> Left   StateChangeFinished
      case eresult of
        Left m -> liftProcess (sendChan ch m) >> messageProcessed eid
        Right action -> action

-- | Timeout to wait for reply from node.
tearDownTimeout :: Int
tearDownTimeout = 5*60

-- | Bootlevel that RC procedure is started at.
maxTeardownLevel :: Int
maxTeardownLevel = 3

-- | List of all nodes that are running teardown, with message id
-- that triggered it.
newtype NodesRunningTeardown = NodesRunningTeardown (Map R.Node UUID)

-- | Notification that barrier was passed by the cluster.
newtype BarrierPass = BarrierPass M0.MeroClusterState deriving (Binary, Show)

-- | Send a notification when the cluster state transitions.
notifyOnClusterTranstion :: (Binary a, Typeable a)
                         => M0.MeroClusterState -- ^ State to notify on
                         -> (M0.MeroClusterState -> a) -- Notification to send
                         -> Maybe UUID -- Message to declare processed
                         -> PhaseM LoopState l ()
notifyOnClusterTranstion desiredState msg meid = do
  newState <- calculateMeroClusterStatus
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

-- | Message guard: Check if the barrier being passed is for the correct level
barrierPass :: M0.MeroClusterState
            -> BarrierPass
            -> g
            -> l
            -> Process (Maybe ())
barrierPass state (BarrierPass state') _ _ =
  if state == state' then return (Just ()) else return Nothing

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


-- | Procedure for tearing down mero services.
--
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
       markProcessFailed lvl fids = modifyGraph $ \rg ->
         foldr (\p -> G.disconnect (M0.MeroClusterStopping lvl) M0.Pending p
                        >>> G.connectUniqueFrom p R.Is M0.M0_NC_FAILED)
               rg
               (getProcessesByFid rg fids :: [M0.Process])

   -- Check if there are any processes left to be stopped on current bootlevel.
   -- If there are any process - then just process current message (meid),
   -- If there are no process left then move cluster to next bootlevel and prepare
   -- all technical information in RG, then emit BarrierPassed function.
   let notifyBarrier meid = do
         Just (_,_,b) <- get Local
         level@(M0.MeroClusterStopping (M0.BootLevel i)) <-
            fromMaybe M0.MeroClusterStopped . listToMaybe . G.connectedTo R.Cluster R.Has <$> getLocalGraph
         rg <- getLocalGraph
         if null [ (srv :: M0.Process) |  srv   <- G.connectedTo level M0.Pending rg ] && b == (M0.BootLevel i)
         then do lvl <- case i of
                   0 -> do modifyGraph $ G.connectUnique R.Cluster R.Has M0.MeroClusterStopped
                           return M0.MeroClusterStopped
                   _ -> do let bl = M0.BootLevel (i-1)
                               lvl = M0.MeroClusterStopping bl
                           modifyGraph $
                              G.connectUnique R.Cluster R.Has lvl
                              . (\r -> foldr (\p x -> G.connect lvl M0.Pending (p::M0.Process) x) r
                                             (G.connectedFrom R.Has (M0.PLBootLevel bl) r)) -- TODO exclude nodes that failed to teardown?
                           return lvl
                 syncGraphCallback $ \self proc -> do
                   usend self (BarrierPass lvl)
                   forM_ meid proc
         else do phaseLog "debug" $ "There are processes left:" ++ show
                                    [ (srv :: M0.Process) |  srv   <- G.connectedTo level M0.Pending rg ]
                 forM_ meid syncGraphProcessMsg


   setPhase initialize $ \(HAEvent eid (StopMeroServer node) _) -> getStorageRC  >>= \nodes ->
     case Map.lookup node =<< nodes of
       Nothing -> do
         putStorageRC $ NodesRunningTeardown $ Map.insert node eid (fromMaybe Map.empty nodes)
         fork CopyNewerBuffer $ do
           put Local (Just (eid, node, M0.BootLevel maxTeardownLevel))
           continue teardown
       Just eid' -> do
         phaseLog "debug" $ show node ++ " already beign processed - ignoring."
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
       forM_ results $ \case
         Left _ -> return ()
         Right (x,s) -> phaseLog "error" $ printf "failed to stop service %s : %s" (show x) s
       markProcessFailed lvl $ map (\case Left x -> x ; Right (x,_) -> x) results
       notifyBarrier (Just eid)
       nextBootLevel

   directly teardown_timeout $ do
     Just (_, node, lvl) <- get Local
     phaseLog "warning" $ printf "%s failed to stop services (timeout)" (show node)
     rg <- getLocalGraph
     markProcessFailed lvl $ map M0.fid $ getLabeledNodeProcesses node (mkLabel lvl) rg
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
     stop

   startFork initialize Nothing
   where
     getProcessesByFid rg = mapMaybe (`rgLookupConfObjByFid` rg)
     mkLabel bl@(M0.BootLevel l)
       | l == maxTeardownLevel = M0.PLM0t1fs
       | otherwise = M0.PLBootLevel bl

     -- XXX: currently we don't mark node during this process, it seems that in
     --      we should receive notification about node death by other means,
     --      and treat that appropriatelly.
     markNodeFailedTeardown = const $ return ()

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
    finish <- phaseHandle "finish"
    end <- phaseHandle "end"

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
        _ -> return ()

      fork CopyNewerBuffer $ do
        findNodeHost node >>= \case
          Just host -> do
            put Local $ Just (node, host, eid)
            phaseLog "info" "Starting core bootstrap"
            let mlnid = listToMaybe $ [ ip | CI.Interface { CI.if_network = CI.Data, CI.if_ipAddrs = ip:_ }
                                              <- G.connectedTo host R.Has rg ]
            case mlnid of
              Nothing -> do
                phaseLog "warn" $ "Unable to find Data IP addr for host "
                                ++ show host
                continue finish
              Just lnid -> do
                createMeroKernelConfig host $ lnid ++ "@tcp"
                startMeroService host node
                switch [svc_up_now, timeout 1000000 svc_up_already]
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
      (procs :: [M0.Process]) <- catMaybes <$> mapM lookupConfObjByFid (lefts e)
      -- Mark successful processes as online, and others as failed.
      forM_ procs $ \p -> modifyGraph $ G.connectUniqueFrom p R.Is M0.ProcessBootstrapped
                                    >>> G.connectUniqueFrom p R.Is M0.PSOnline
      forM_ (rights e) $ \(f,r) -> lookupConfObjByFid f >>= \mp -> do
        phaseLog "warning" $ "Process " ++ show f
                          ++ " failed to start: " ++ r
        traverse_ (\(p :: M0.Process) ->
          modifyGraph $ G.connect p R.Is (M0.PSFailed r)) mp
      rms <- listToMaybe
                . filter (\s -> M0.s_type s == CST_RMS)
                . join
                . filter (\s -> CST_MGS `elem` fmap M0.s_type s)
              <$> mapM getChildren procs
      traverse_ setPrincipalRMIfUnset rms
      let state = M0.MeroClusterStarting (M0.BootLevel 1)
      notifyOnClusterTranstion state BarrierPass (Just eid)
      switch [boot_level_1, timeout 5000000 finish]

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
      (procs :: [M0.Process]) <- catMaybes <$> mapM lookupConfObjByFid (lefts e)
      -- Mark successful processes as online, and others as failed.
      forM_ procs $ \p -> modifyGraph $ G.connectUniqueFrom p R.Is M0.ProcessBootstrapped
                                    >>> G.connectUniqueFrom p R.Is M0.PSOnline
      forM_ (rights e) $ \(f,r) -> lookupConfObjByFid f >>= \mp -> do
        phaseLog "warning" $ "Process " ++ show f
                          ++ " failed to start: " ++ r
        traverse_ (\(p :: M0.Process) ->
          modifyGraph $ G.connect p R.Is (M0.PSFailed r)) mp
      let state = M0.MeroClusterRunning
      notifyOnClusterTranstion state BarrierPass (Just eid)
      switch [start_clients, timeout 5000000 finish]

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
      (procs :: [M0.Process]) <- catMaybes <$> mapM lookupConfObjByFid (lefts e)
      -- Mark successful processes as online, and others as failed.
      forM_ procs $ \p -> modifyGraph $ G.connectUniqueFrom p R.Is M0.ProcessBootstrapped
                                    >>> G.connectUniqueFrom p R.Is M0.PSOnline
      forM_ (rights e) $ \(f,r) -> lookupConfObjByFid f >>= \mp -> do
        phaseLog "warning" $ "Process " ++ show f
                          ++ " failed to start: " ++ r
        traverse_ (\(p :: M0.Process) ->
          modifyGraph $ G.connect p R.Is (M0.PSFailed r)) mp
      messageProcessed eid
      continue finish

    directly finish $ do
      Just (n, _, eid) <- get Local
      phaseLog "server-bootstrap" $ "Finished bootstrapping mero server at "
                                 ++ show n
      messageProcessed eid
      continue end

    directly end stop

    startFork new_server Nothing
  where

-- | New mero client rule is capable provisioning new mero client.
-- In order to do that following steps are applies:
--   1. for each new connected node 'NewMeroClient' message is emitted by 'ruleNodeUp'.
--   2. for each new client that is known to be mero-client, but have no confd information,
--      that information is generated and synchronized with confd servers
--   3. once confd have all required information available start mero service on the node,
--      that will lead provision process.
--
-- Once R.Host is provisioned 'NewMeroClient' event is published
ruleNewMeroClient :: Definitions LoopState ()
ruleNewMeroClient = define "new-mero-client" $ do
    mainloop <- phaseHandle "mainloop"
    msgNewMeroClient <- phaseHandle "new-mero-client"
    msgClientInfo    <- phaseHandle "client-info-update"
    msgClientStoreInfo <- phaseHandle "client-store-update"
    svc_up_now <- phaseHandle "svc_up_now"
    svc_up_already <- phaseHandle "svc_up_already"
    start_clients <- phaseHandle "start_clients"
    start_clients_complete <- phaseHandle "start_clients_complete"

    directly mainloop $
      switch [ msgNewMeroClient
             , msgClientInfo
             , msgClientStoreInfo
             ]

    setPhase msgNewMeroClient $ \(HAEvent eid (NewMeroClient node@(R.Node nid)) _) -> do
       mhost <- findNodeHost node
       case mhost of
         Just host -> do
           isServer <- hasHostAttr R.HA_M0SERVER host
           isClient <- hasHostAttr R.HA_M0CLIENT host
           mlnid    <- listToMaybe . G.connectedTo host R.Has <$> getLocalGraph
           case mlnid of
             -- Host is a server, bootstrap is done in a separate procedure.
             _ | isServer -> do
                   phaseLog "info" $ show host ++ " is mero server, skipping provision"
                   messageProcessed eid
             -- Host is client with all required info beign loaded .
             Just M0.LNid{}
               | isClient -> do
                   phaseLog "info" $ show host ++ " is mero client. Configuration was generated - starting mero service"
                   startMeroService host node
                   messageProcessed eid
             -- Host is client but not all information was loaded.
             _  -> do
                   phaseLog "info" $ show host ++ " is mero client. No configuration - generating"
                   startMeroClientProvisioning host eid
                   getProvisionHardwareInfo host >>= \case
                     Nothing -> do
                       liftProcess $ void $ spawnLocal $
                         void $ spawnAsync nid $ $(mkClosure 'getUserSystemInfo) node
                     Just info -> selfMessage (NewClientStoreInfo host info)
         Nothing -> do
           phaseLog "error" $ "Can't find host for node " ++ show node
           messageProcessed eid

    setPhase msgClientInfo $ \(HAEvent eid (SystemInfo nid info) _) -> do
      phaseLog "info" $ "Recived information about " ++ show nid
      mhost <- findNodeHost nid
      case mhost of
        Just host -> do
          putProvisionHardwareInfo host info
          syncGraphProcessMsg eid
          selfMessage $ NewClientStoreInfo host info
        Nothing -> do
          phaseLog "error" $ "Received information from node on unknown host " ++ show nid
          messageProcessed eid

    setPhase msgClientStoreInfo $ \(NewClientStoreInfo host info) -> do
       getFilesystem >>= \case
          Nothing -> do
            phaseLog "warning" "Configuration data was not loaded yet, skipping"
          Just fs -> do
            (node:_) <- nodesOnHost host
            createMeroClientConfig fs host info
            startMeroService host node
            put Local $ Just (node, host, ())
            switch [svc_up_now, timeout 5000000 svc_up_already]

    -- Service comes up as a result of this invocation
    setPhaseIf svc_up_now declareMeroChannelOnNode $ \chan -> do
      Just (_, host, _) <- get Local
      -- Legitimate to ignore the event id as it should be handled by the default
      -- 'declare-mero-channel' rule.
      procs <- startNodeProcesses host chan M0.PLM0t1fs False
      case procs of
        [] -> let state = M0.MeroClusterRunning in do
          notifyOnClusterTranstion state BarrierPass Nothing
        _ -> continue start_clients_complete

    -- Service is already up
    directly svc_up_already $ do
      Just (node, host, _) <- get Local
      rg <- getLocalGraph
      m0svc <- lookupRunningService node m0d
      case m0svc >>= meroChannel rg of
        Just chan -> do
          procs <- startNodeProcesses host chan M0.PLM0t1fs False
          case procs of
            [] -> let state = M0.MeroClusterRunning in do
              notifyOnClusterTranstion state BarrierPass Nothing
            _ -> continue start_clients_complete
        Nothing -> switch [svc_up_now, timeout 5000000 svc_up_already]

    setPhaseIf start_clients (barrierPass M0.MeroClusterRunning) $ \() -> do
      Just (node, host, _) <- get Local
      rg <- getLocalGraph
      m0svc <- lookupRunningService node m0d
      case m0svc >>= meroChannel rg of
        Just chan -> do
          procs <- startNodeProcesses host chan M0.PLM0t1fs False
          if null procs
            then return ()
            else continue start_clients_complete
        Nothing -> return ()

    -- Mark clients as coming up successfully.
    setPhaseIf start_clients_complete processControlOnNode $ \(eid, e) -> do
      Just (R.Node node, _, _) <- get Local
      (procs :: [M0.Process]) <- catMaybes <$> mapM lookupConfObjByFid (lefts e)
      -- Mark successful processes as online, and others as failed.
      forM_ procs $ \p -> modifyGraph $ G.connectUniqueFrom p R.Is M0.ProcessBootstrapped
                                    >>> G.connectUniqueFrom p R.Is M0.PSOnline
      forM_ (rights e) $ \(f,r) -> lookupConfObjByFid f >>= \mp -> do
        phaseLog "warning" $ "Process " ++ show f
                          ++ " failed to start: " ++ r
        traverse_ (\(p :: M0.Process) ->
          modifyGraph $ G.connect p R.Is (M0.PSFailed r)) mp
        finishMeroClientProvisioning node
        messageProcessed eid

    start mainloop Nothing
  where
    startMeroClientProvisioning host uuid =
      modifyLocalGraph $ \rg -> do
        let pp  = ProvisionProcess host
            rg' = G.newResource pp
              >>> G.connect pp OnHost host
              >>> G.connect pp TriggeredBy uuid
                $ rg
        return rg'

    finishMeroClientProvisioning nid = do
      rg <- getLocalGraph
      let mpp = listToMaybe
                  [ pp | host <- G.connectedFrom R.Runs (R.Node nid) rg :: [R.Host]
                       , pp <- G.connectedFrom OnHost host rg :: [ProvisionProcess]
                       ]
      forM_ mpp $ \pp -> do
        let uuids = G.connectedTo pp TriggeredBy rg :: [UUID]
        forM_ uuids messageProcessed
        modifyGraph $ G.disconnectAllFrom pp OnHost (Proxy :: Proxy R.Host)
                  >>> G.disconnectAllFrom pp TriggeredBy (Proxy :: Proxy UUID)

    getProvisionHardwareInfo host = do
       let pp = ProvisionProcess host
       rg <- getLocalGraph
       return . listToMaybe $ (G.connectedTo pp R.Has rg :: [M0.HostHardwareInfo])
    putProvisionHardwareInfo host info = do
       let pp = ProvisionProcess host
       modifyGraph $ G.connectUnique pp R.Has (info :: M0.HostHardwareInfo)
       publish $ NewMeroClientProcessed host

data CommitNewMeroClient = CommitNewMeroClient R.Host UUID
  deriving (Eq, Show, Typeable, Generic)
instance Binary CommitNewMeroClient

data NewClientStoreInfo = NewClientStoreInfo R.Host M0.HostHardwareInfo
  deriving (Eq, Show, Typeable, Generic)
instance Binary NewClientStoreInfo

data OnHost = OnHost
  deriving (Eq, Show, Typeable,Generic)
instance Binary OnHost
instance Hashable OnHost

data TriggeredBy = TriggeredBy
  deriving (Eq, Show, Typeable, Generic)
instance Binary TriggeredBy
instance Hashable TriggeredBy

data ProvisionProcess = ProvisionProcess R.Host
  deriving (Eq, Show, Typeable, Generic)
instance Binary ProvisionProcess
instance Hashable ProvisionProcess

$(mkDicts
  [ ''OnHost, ''ProvisionProcess ]
  [ (''ProvisionProcess, ''OnHost, ''R.Host)
  , (''ProvisionProcess, ''TriggeredBy, ''UUID)
  , (''ProvisionProcess, ''R.Has, ''M0.HostHardwareInfo)
  ]
  )

$(mkResRel
  [ ''OnHost, ''ProvisionProcess ]
  [ (''ProvisionProcess, ''OnHost, ''R.Host)
  , (''ProvisionProcess, ''TriggeredBy, ''UUID)
  , (''ProvisionProcess, ''R.Has, ''M0.HostHardwareInfo)
  ] [])
