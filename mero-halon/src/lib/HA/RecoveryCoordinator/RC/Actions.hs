{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2016 Xyratex Technology Limited.
-- License   : All rights reserved.
--
module HA.RecoveryCoordinator.RC.Actions
  ( -- * RC
    getCurrentRC
  , makeCurrentRC
  -- * Epoch
  , updateEpoch
  , getCurrentEpoch
  -- * Distributed process features
  -- ** Monitoring
  , registerNodeMonitor
  , registerProcessMonitor
  , unregisterMonitor
  -- * Cluster
  , registerNodeMonitoringAngel
  , addNodeToCluster
  ) where

import           HA.RecoveryCoordinator.RC.Internal
import           HA.Resources.RC

import           HA.RecoveryCoordinator.Actions.Core
import qualified HA.RecoveryCoordinator.Actions.Service as Service

-- import           HA.Service
import           HA.EQTracker (updateEQNodes__static, updateEQNodes__sdict)
import qualified HA.EQTracker as EQT

import qualified HA.ResourceGraph    as G
import qualified HA.Resources        as R
import qualified HA.Resources.Castor as R
import           Network.CEP

import Control.Distributed.Process hiding (try)
import Control.Distributed.Process.Internal.Types (SpawnRef)
import Control.Distributed.Process.Closure (mkClosure)
import Control.Concurrent (yield)
import Control.Category
import Control.Monad (unless)
import Control.Monad.Catch (try)
import Control.Monad.Fix (fix)

import Data.Binary (Binary,encode)
import Data.Foldable (for_, traverse_)
import Data.Functor (void)
import Data.Function ((&))
import qualified Data.List as List
import qualified Data.Map as Map
import Data.Maybe (listToMaybe)
import Data.Typeable (Typeable)
import Data.Word (Word64)

import GHC.Generics (Generic)

import Prelude hiding (id, (.))

-- | Current RC.
currentRC :: RC
currentRC = RC 0 -- XXX: use version from the package/git version info?

-- | 'getCurrentRC', fails if no active RC exists.
getCurrentRC :: PhaseM LoopState l RC
getCurrentRC = tryGetCurrentRC >>= \case
  Nothing -> error "Can't find active rc in the graph"
  Just x  -> return x

-- | Create new recovery coordinator in the graph if needed. If previously
-- graph contained old RC - update handler is called @update oldRC newRC@.
-- Old RC is no longer connected to the root of the graph, so it may be garbage
-- collected after calling upate handler.
makeCurrentRC :: (RC -> RC -> PhaseM LoopState l ()) -> PhaseM LoopState l RC
makeCurrentRC update = do
  mOldRC <- tryGetCurrentRC
  case mOldRC of
    Nothing -> mkRC
    Just old
      | old == currentRC ->
         return ()
      | otherwise -> do
         mkRC
         update old currentRC
  return currentRC
  where
    mkRC = modifyGraph $ \g ->
      let g' = G.newResource currentRC
           >>> G.newResource Active
           >>> G.connectUnique R.Cluster R.Has currentRC
           >>> G.connectUnique currentRC R.Is  Active
             $ g
      in g'


-- | Find currenlty running RC in resource graph.
tryGetCurrentRC :: PhaseM LoopState l (Maybe RC)
tryGetCurrentRC = do
  rg <- getLocalGraph
  return $ listToMaybe [ rc
                       | rc <- G.connectedTo R.Cluster R.Has rg :: [RC]
                       , G.isConnected rc R.Is Active rg
                       ]

-- | Increment epoch
incrementEpoch :: Word64 -> R.EpochId
incrementEpoch = R.EpochId . succ

-- | Get current epoch
getCurrentEpoch :: PhaseM LoopState l Word64
getCurrentEpoch = maybe 0 (\(R.EpochId i) -> i). listToMaybe
                . G.connectedTo R.Cluster R.Has <$> getLocalGraph

-- | Read old epoch value and update it to the next one.
updateEpoch :: PhaseM LoopState l Word64
updateEpoch = do
  old <- getCurrentEpoch
  modifyGraph $ G.connectUnique R.Cluster R.Has (incrementEpoch old)
  return old

-- | Monitor node and register callback to run when node dies.
registerNodeMonitor :: R.Node -> (forall v . PhaseM LoopState v ()) -> PhaseM LoopState l MonitorRef
registerNodeMonitor (R.Node node) callback = do
  mref <- liftProcess $ monitorNode node
  mmon <- getStorageRC
  putStorageRC $ RegisteredMonitors $
    case mmon of
      Nothing -> Map.singleton mref (AnyLocalState callback)
      Just (RegisteredMonitors mm)  -> Map.insert mref (AnyLocalState callback) mm
  return mref

-- | Monitor process and register callback to run when node dies.
registerProcessMonitor :: ProcessId -> (forall v . PhaseM LoopState v ()) -> PhaseM LoopState l MonitorRef
registerProcessMonitor pid callback = do
  mref <- liftProcess $ monitor pid
  mmon <- getStorageRC
  putStorageRC $ RegisteredMonitors $
    case mmon of
      Nothing ->
        Map.singleton mref (AnyLocalState callback)
      Just (RegisteredMonitors mm)  ->
        Map.insert mref (AnyLocalState callback) mm
  return mref

-- | Unregister previouly created callback
unregisterMonitor :: MonitorRef -> PhaseM LoopState l ()
unregisterMonitor mref = do
  liftProcess $ unmonitor mref
  mnmon <- getStorageRC
  for_ mnmon $ \(RegisteredMonitors mons) -> do
    putStorageRC $ RegisteredMonitors $ Map.delete mref mons

-- | Spawn a remote process and register asynchronous callback.
-- Callback should not be blocking as it will be executed in
-- scope on another thread.
registerSpawnAsync :: R.Node
                   -> Closure (Process ())
                   -> (forall v . PhaseM LoopState v ())
                   -> PhaseM LoopState l SpawnRef
registerSpawnAsync (R.Node nid) clo callback = do
  ref <- liftProcess $ spawnAsync nid clo
  msp <- getStorageRC
  let key = encode ref
  putStorageRC $ RegisteredSpawns $
    case msp of
      Nothing -> Map.singleton key (AnyLocalState callback)
      Just (RegisteredSpawns mm) -> Map.insert key (AnyLocalState callback) mm
  return ref

unregisterSpawnAsync :: SpawnRef -> PhaseM LoopState l ()
unregisterSpawnAsync ref = do
  let key = encode ref
  mnmon <- getStorageRC
  for_ mnmon $ \(RegisteredSpawns mons) -> do
    putStorageRC $ RegisteredSpawns $ Map.delete key mons

-- | Add new node to the cluster.
--
-- This call provisions node, restart services there and add required
-- monitoring procedures.
addNodeToCluster :: [NodeId] -> R.Node -> PhaseM LoopState l ()
addNodeToCluster eqs node@(R.Node nid) = do
  isMonitored <- liftProcess $ do
    self <- getSelfPid
    nsend "rc.angel.node-monitor" (IsMonitored nid self)
    expect
  unless isMonitored $ do
    liftProcess $ nsend "rc.angel.node-monitor" (AddNode nid)
    sr <- registerSpawnAsync node
            ( $(mkClosure 'EQT.updateEQNodes) eqs ) $
              Service.findRegisteredOn node >>= traverse_ (node & Service.start)
    void $ registerNodeMonitor node $ do
      phaseLog "warning" "node died"
      phaseLog "node" $ show node
      liftProcess $ nsend "rc.angel.node-monitor" (RemoveNode nid)
      promulgateRC $ R.RecoverNode node
      unregisterSpawnAsync sr
      return ()

-------------------------------------------------------------------------------
-- Node monitor angel
-------------------------------------------------------------------------------

data MonitorAngelCmd = AddNode NodeId
                     | RemoveNode NodeId
                     | IsMonitored NodeId ProcessId
                     deriving (Typeable, Generic)
instance Binary MonitorAngelCmd

data Heartbeat = Heartbeat deriving (Generic, Typeable)
instance Binary Heartbeat

data AngelMonUp = AngelMonUp deriving (Generic, Typeable)
instance Binary AngelMonUp

-- | Delay (seconds) at which the heartbeat process sends a 'Heartbeat' event to
--   main monitor process thread. Delay may be postponed in case if new nodes
--   were added or removed from the monitor list.
heartbeatDelay :: Int
heartbeatDelay = 2 * 1000000 -- XXX: make halon var

registerNodeMonitoringAngel :: PhaseM LoopState l ()
registerNodeMonitoringAngel = do
  pid <- liftProcess $ do
    rc <- getSelfPid
    pid <- spawnLocal $ do
      link rc
      me <- getSelfPid
      register "rc.angel.node-monitor" me
      usend rc AngelMonUp
      fix (\loop nodes -> do
        mcommand <- expectTimeout heartbeatDelay
        case mcommand of
          Just (AddNode node) -> do
            -- say $ "rc.angel.node-monitor: add " ++ show node
            loop (List.insert node nodes)
          Just (RemoveNode node) -> do
            -- say $ "rc.angel.node-monitor: remove " ++ show node
            loop (filter (node /=) nodes)
          Just (IsMonitored node pid) -> do
            -- say $ "rc.angel.node-monitor: Is monitored " ++ show node ++ " => " ++ show (node `elem` nodes)
            usend pid (node `elem` nodes)
            loop nodes
          Nothing -> do
            -- say $ "Sending heartbeat to " ++ show nodes  -- XXX: remove unused
            -- Monitoring is working only if there are some traffic between
            -- nodes otherwise network-transport implementation may not note
            -- connection breakage. So for each node that is connected to
            -- cluster we create some traffic by sending messages using named
            -- send.
            traverse_ (\n -> nsendRemote n "nonexistingprocess" Heartbeat) nodes
            loop nodes) []
    AngelMonUp <- expect
    return pid
  -- rg <- getLocalGraph
  -- let nodes = (\(R.Node n) -> n) <$> G.connectedTo R.Cluster R.Has rg
  -- liftProcess $ for_ nodes $ usend pid . AddNode
  void $ registerProcessMonitor pid $ do
     phaseLog "warning" "Node monitor angel has died, restarting."
     registerNodeMonitoringAngel
