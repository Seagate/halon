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

-- | Default rules used for debugging the RC. These rules should be
-- given the same 'IgnitionArguments' that were used to start the
-- current RC.
rules :: IgnitionArguments -> Definitions LoopState ()
rules argv = sequence_ [
    ruleNodeStatus argv
  , ruleDebugRC argv
  ]

-- | Processes a 'NodeStatusRequest' and sends back
-- 'NodeStatusResponse' to the requesting process.
--
-- TODO: Can we add EQs that haven't been mentioned in the ignition
-- arguments? If yes, then this code is not good enough.
ruleNodeStatus :: IgnitionArguments -> Definitions LoopState ()
ruleNodeStatus argv = defineSimple "Debug::node-status" $
      \(HAEvent uuid (NodeStatusRequest n@(R.Node nid) lis) _) -> do
        rg <- getLocalGraph
        let
          isSatellite = G.connectedTo R.Cluster R.Has n rg
          -- We can't be a station if we aren't a satellite. We don't
          -- want to report a node that is no longer part of the
          -- cluster is an EQ node.
          isStation = nid `elem` eqNodes argv && isSatellite
          response = NodeStatusResponse n isStation isSatellite
        liftProcess $ mapM_ (flip usend response) lis
        messageProcessed uuid

-- | Replies to a 'DebugRequest' with 'DebugResponse' which contains
-- various useful debug information about the RC.
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
