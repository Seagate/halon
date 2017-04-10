-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Module rules for debugging and information retrieval.
module HA.RecoveryCoordinator.RC.Rules.Info where


import           Control.Distributed.Process
import           Control.Monad (void)
import           Data.ByteString.Builder (toLazyByteString, lazyByteString)
import qualified Data.ByteString.Lazy as BL
import           HA.EventQueue (HAEvent(..))
import           HA.Multimap (getKeyValuePairs)
import           HA.RecoveryCoordinator.Mero
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import           HA.RecoveryCoordinator.RC.Actions.Info
import           HA.RecoveryCoordinator.RC.Events.Info
import qualified HA.ResourceGraph as G
import qualified HA.Resources as R
import           Network.CEP

-- | RC debug rules.
rules :: IgnitionArguments -> Definitions RC ()
rules argv = sequence_ [
    ruleNodeStatus argv
  , ruleDebugRC argv
  , ruleGetGraph
  ]

-- | Listen for 'NodeStatusRequest' and send back the
-- 'NodeStatusResponse' to the interested process.
ruleNodeStatus :: IgnitionArguments -> Definitions RC ()
ruleNodeStatus argv = defineSimpleTask "Debug::node-status" $
      \(NodeStatusRequest n@(R.Node nid) sp) -> do
        rg <- getLocalGraph
        let
          isStation = nid `elem` eqNodes argv
          isSatellite = G.isConnected R.Cluster R.Has (R.Node nid) rg
          response = NodeStatusResponse n isStation isSatellite
        liftProcess $ sendChan sp response

-- | Listen for 'DebugRequest' and send back 'DebugResponse' to the
-- requesting process.
ruleDebugRC :: IgnitionArguments -> Definitions RC ()
ruleDebugRC argv = defineSimpleTask "Debug::debug-rc" $
  \(DebugRequest sp) -> do
    Log.rcLog' Log.DEBUG "Sending debug statistics to client."
    ls <- get Global
    rg <- getLocalGraph
    liftProcess . sendChan sp $ DebugResponse {
      dr_eq_nodes = eqNodes argv
    , dr_refCounts = lsRefCount ls
    , dr_rg_elts = length $ G.getGraphResources rg
    , dr_rg_since_gc = G.getSinceGC rg
    , dr_rg_gc_threshold = G.getGCThreshold rg
    }

-- | Dump @k:v/rg/json@ value out to the service.
--
-- This call marked as proccessed immediately and is not reprocessed if case
-- of RC failure.
ruleGetGraph :: Definitions RC ()
ruleGetGraph = defineSimple "graph-dump-values" $ \(HAEvent uuid msg) -> case msg of
  -- Reads all key values in storage and sends that to
  -- the caller. Reply it send as a stream of a 'Data.ByteString.ByteString's
  -- followed by '()' when everything is sent.
  MultimapGetKeyValuePairs sp -> do
    messageProcessed uuid
    chan <- lsMMChan <$> get Global
    void . liftProcess $ spawnLocal $ do
      reply <- mmKeyValues . Just <$> getKeyValuePairs chan
      mapM_ (sendChan sp . GraphDataChunk)
        $ BL.toChunks
        $ toLazyByteString . lazyByteString $ reply
      sendChan sp GraphDataDone
  -- Reads graph and sends serializes that into graphviz
  -- format. Reply is send as a stream of a 'Data.ByteString.ByteString's
  -- followed by '()' when everything is sent.
  ReadResourceGraph sp -> do
    messageProcessed uuid
    rg <- G.garbageCollectRoot <$> getLocalGraph
    void . liftProcess $ spawnLocal $ do
      let reply = dumpGraph $ G.getGraphResources rg
      mapM_ (sendChan sp . GraphDataChunk)
        $ BL.toChunks
        $ toLazyByteString . lazyByteString $ reply
      sendChan sp GraphDataDone
  JsonGraph sp -> do
    messageProcessed uuid
    rg <- G.garbageCollectRoot <$> getLocalGraph
    void . liftProcess $ spawnLocal $ do
      let reply = dumpToJSON $ G.getGraphResources rg
      mapM_ (sendChan sp . GraphDataChunk)
        $ BL.toChunks
        $ toLazyByteString . lazyByteString
        $ reply
      sendChan sp GraphDataDone
