-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
{-# LANGUAGE DeriveGeneric #-}
module HA.RecoveryCoordinator.Rules.Castor.Cluster where

import HA.EventQueue.Types
import qualified HA.Resources as R
import qualified HA.Resources.Mero as M0
import HA.ResourceGraph as G
import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Mero
import HA.RecoveryCoordinator.Events.Castor.Cluster
import Network.CEP

import Control.Distributed.Process
import Data.Maybe (listToMaybe)

clusterRules :: Definitions LoopState ()
clusterRules = sequence_
  [ ruleClusterStatus
  , ruleClusterStart
  , ruleClusterStop
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
                  -- XXX: set boot level dynamically
                  modifyGraph $ G.connectUnique R.Cluster R.Has (M0.MeroClusterStopping (M0.BootLevel 2))
                  syncGraphCallback $ \pid proc -> do
                    sendChan ch (StateChangeStarted pid)
                    proc eid
               M0.MeroClusterStopping{} -> Left $ StateChangeOngoing st
               M0.MeroClusterStarting{} -> Left $ StateChangeError $ "cluster is stopping: " ++ show st
               M0.MeroClusterStopped    -> Left   StateChangeFinished
      case eresult of
        Left m -> liftProcess (sendChan ch m) >> messageProcessed eid
        Right action -> action
