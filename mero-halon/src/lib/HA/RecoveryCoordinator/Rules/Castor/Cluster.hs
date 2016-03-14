-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
module HA.RecoveryCoordinator.Rules.Castor.Cluster where

import           HA.EventQueue.Types
import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Mero as M0

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
import           Network.CEP

import           Control.Distributed.Process
import           Control.Monad (guard, when, unless)
import           Control.Monad.Trans.Maybe
import           Data.Binary (Binary)
import           Data.Maybe (listToMaybe, mapMaybe, fromMaybe)
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Foldable
import           Text.Printf

clusterRules :: Definitions LoopState ()
clusterRules = sequence_
  [ ruleClusterStatus
  , ruleClusterStart
  , ruleClusterStop
  , ruleTearDownMeroNode
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
      let eresult = case listToMaybe $ G.connectedTo R.Cluster R.Has rg of
            Nothing -> Left $ StateChangeError "Unknown current state."
            Just st -> case st of
               M0.MeroClusterStopped    -> Right $ do
                  modifyGraph $ G.connectUnique R.Cluster R.Has (M0.MeroClusterStarting (M0.BootLevel 0))
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
               M0.MeroClusterStarting{} -> Left $ StateChangeError $ "cluster is stopping: " ++ show st
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
       [] -> do phaseLog "debug" $ printf "%s has no services on level %s - skipping to the next level"
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
       -- XXX: mark failed services (?)
       let fids = map (\case Left x -> x ; Right (x,_) -> x) results
       modifyGraph $ \rg ->
         foldr (G.disconnect (M0.MeroClusterStopping lvl) M0.Pending) 
               rg
               (getProcessesByFid rg fids :: [M0.Process])
       notifyBarrier (Just eid)
       nextBootLevel

   directly teardown_timeout $ do
     Just (_, node, lvl) <- get Local
     phaseLog "warning" $ printf "%s failed to stop services (timeout)" (show node)
     modifyGraph $ \rg -> foldr (G.disconnect (M0.MeroClusterStopping lvl) M0.Pending)
                                rg
                                (getLabeledNodeProcesses node (mkLabel lvl) rg)
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

   (`start` Nothing) =<< initWrapper initialize
   where
     initWrapper rule = do
       wrapper_init  <- phaseHandle "wrapper_init"
       wrapper_clear <- phaseHandle "wrapper_clear"
       wrapper_end   <- phaseHandle "wrapper_end"
       directly wrapper_init $ switch [rule, wrapper_clear]
       directly wrapper_clear $ do
         fork NoBuffer $ continue rule
         continue wrapper_end
       directly wrapper_end stop
       return wrapper_init
     getProcessesByFid rg = mapMaybe (`rgLookupConfObjByFid` rg)
     mkLabel bl@(M0.BootLevel l)
       | l == maxTeardownLevel = M0.PLM0t1fs
       | otherwise = M0.PLBootLevel bl
       
     -- XXX: currently we don't mark node during this process, it seems that in
     --      we should receive notification about node death by other means, 
     --      and treat that appropriatelly.
     markNodeFailedTeardown = const $ return ()
