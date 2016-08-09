-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Module rules for debugging.
--
module HA.RecoveryCoordinator.Rules.Debug where

import HA.EventQueue.Types (HAEvent(..))
import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Events.Debug
import HA.RecoveryCoordinator.Mero
import qualified HA.ResourceGraph as G
import qualified HA.Resources as R

import Control.Distributed.Process (usend)

import Network.CEP

rules :: IgnitionArguments -> Definitions LoopState ()
rules argv = sequence_ [
    ruleNodeStatus argv
  , ruleDebugRC argv
  ]

-- | Listen for 'NodeStatusRequest' and send back the
-- 'NodeSTatusResponse' to the interested process.
ruleNodeStatus :: IgnitionArguments -> Definitions LoopState ()
ruleNodeStatus argv = defineSimpleTask "Debug::node-status" $
      \(NodeStatusRequest n@(R.Node nid) lis) -> do
        rg <- getLocalGraph
        let
          isStation = nid `elem` eqNodes argv
          isSatellite = G.isConnected R.Cluster R.Has (R.Node nid) rg
          response = NodeStatusResponse n isStation isSatellite
        liftProcess $ mapM_ (flip usend response) lis

-- | Listen for 'DebugRequest' and send back 'DebugResponse' to the
-- requesting process.
ruleDebugRC :: IgnitionArguments -> Definitions LoopState ()
ruleDebugRC argv = defineSimpleTask "Debug::debug-rc" $
  \(DebugRequest pid) -> do
    phaseLog "info" "Sending debug statistics to client."
    ls <- get Global
    rg <- getLocalGraph
    liftProcess . usend pid $ DebugResponse {
      dr_eq_nodes = eqNodes argv
    , dr_refCounts = lsRefCount ls
    , dr_rg_elts = length $ G.getGraphResources rg
    , dr_rg_since_gc = G.getSinceGC rg
    , dr_rg_gc_threshold = G.getGCThreshold rg
    }
