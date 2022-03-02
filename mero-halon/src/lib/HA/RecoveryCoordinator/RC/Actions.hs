{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
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
  -- * Core functions
  , module HA.RecoveryCoordinator.RC.Actions.Core
  ) where

import           Control.Distributed.Process hiding (try)
import           Control.Distributed.Process.Closure (mkClosure)
import           Control.Distributed.Process.Internal.Types (SpawnRef, nullProcessId)
import           Data.Binary (Binary)
import           Data.Foldable (for_, traverse_)
import           Data.Function (fix)
import           Data.Functor (void)
import qualified Data.List as List
import qualified Data.Map as Map
import           Data.Maybe (listToMaybe)
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Typeable (Typeable)
import           Data.Word (Word64)
import           GHC.Generics (Generic)
import           HA.EQTracker (updateEQNodes__static, updateEQNodes__sdict)
import qualified HA.EQTracker as EQT
import           HA.RecoveryCoordinator.RC.Actions.Core
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import           HA.RecoveryCoordinator.RC.Internal
import qualified HA.RecoveryCoordinator.Service.Actions as Service
import qualified HA.ResourceGraph as G
import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import           HA.Resources.HalonVars
import qualified HA.Resources.RC as R
import           HA.Service (ServiceFailed(..))
import           Network.CEP

-- | Current RC.
currentRC :: R.RC
currentRC = R.RC 0 -- XXX: use version from the package/git version info?

-- | 'getCurrentRC', fails if no active RC exists.
getCurrentRC :: PhaseM RC l R.RC
getCurrentRC = tryGetCurrentRC >>= \case
  Nothing -> error "Can't find active rc in the graph"
  Just x  -> return x

-- | Create new recovery coordinator in the graph if needed. If previously
-- graph contained old RC - update handler is called @update oldRC newRC@.
-- Old RC is no longer connected to the root of the graph, so it may be garbage
-- collected after calling upate handler.
makeCurrentRC :: (R.RC -> R.RC -> PhaseM RC l ()) -> PhaseM RC l R.RC
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
    mkRC = modifyGraph $ G.connect currentRC R.Is R.Active
                       . G.connect R.Cluster R.Has currentRC

-- | Find currenlty running RC in resource graph.
tryGetCurrentRC :: PhaseM RC l (Maybe R.RC)
tryGetCurrentRC = do
  rg <- getGraph
  return $ listToMaybe
    [ rc
    | Just rc <- [G.connectedTo R.Cluster R.Has rg :: Maybe R.RC]
    , G.isConnected rc R.Is R.Active rg
    ]

-- | Increment epoch
incrementEpoch :: Word64 -> R.EpochId
incrementEpoch = R.EpochId . succ

-- | Get current epoch
getCurrentEpoch :: PhaseM RC l Word64
getCurrentEpoch = maybe 0 (\(R.EpochId i) -> i) .
                  G.connectedTo R.Cluster R.Has <$> getGraph

-- | Read old epoch value and update it to the next one.
updateEpoch :: PhaseM RC l Word64
updateEpoch = do
  old <- getCurrentEpoch
  modifyGraph $ G.connect R.Cluster R.Has (incrementEpoch old)
  return old

-- | Monitor node and register callback to run when node dies.
registerNodeMonitor :: R.Node -> (forall v . PhaseM RC v ()) -> PhaseM RC l MonitorRef
registerNodeMonitor (R.Node node) callback = do
  mref <- liftProcess $ monitorNode node
  mmon <- getStorageRC
  putStorageRC $ RegisteredMonitors $
    case mmon of
      Nothing -> Map.singleton mref (AnyLocalState callback)
      Just (RegisteredMonitors mm)  -> Map.insert mref (AnyLocalState callback) mm
  return mref

-- | Monitor process and register callback to run when node dies.
registerProcessMonitor :: ProcessId -> (forall v . PhaseM RC v ()) -> PhaseM RC l MonitorRef
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
unregisterMonitor :: MonitorRef -> PhaseM RC l ()
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
                   -> (forall v . PhaseM RC v ())
                   -> PhaseM RC l SpawnRef
registerSpawnAsync (R.Node nid) clo callback = do
  ref <- liftProcess $ spawnAsync nid clo
  Log.actLog "registerSpawnAsync" [("nid", show nid), ("ref", show ref)]
  msp <- getStorageRC
  putStorageRC $ RegisteredSpawns $
    case msp of
      Nothing -> Map.singleton ref (AnyLocalState callback)
      Just (RegisteredSpawns mm) -> Map.insert ref (AnyLocalState callback) mm
  return ref

unregisterSpawnAsync :: SpawnRef -> PhaseM RC l ()
unregisterSpawnAsync ref = do
  Log.actLog "unregisterSpawnAsync" [("ref", show ref)]
  mnmon <- getStorageRC
  for_ mnmon $ \(RegisteredSpawns mons) -> do
    putStorageRC $ RegisteredSpawns $ Map.delete ref mons

-- | Add new node to the cluster.
--
-- This call provisions node, restart services there and add required
-- monitoring procedures.
addNodeToCluster :: [NodeId] -> R.Node -> PhaseM RC l ()
addNodeToCluster eqs node@(R.Node nid) = do
  Log.actLog "addNodeToCluster" [("nid", show nid), ("eqs", show eqs)]
  is_monitored <- isMonitored node
  if not is_monitored
  then do
    startMonitoring node
    sr <- registerSpawnAsync node
            ( $(mkClosure 'EQT.updateEQNodes) eqs ) $ do
              Log.rcLog' Log.DEBUG "starting services on the node."
              Service.findRegisteredOn node >>= traverse_ (Service.start node)
    void $ registerNodeMonitor node $ do
      Log.rcLog' Log.WARN "monitored node died - sending restart request"
      stopMonitoring node
      Service.findRegisteredOn node >>=
        traverse_ (\svc -> promulgateRC $ ServiceFailed node svc (nullProcessId nid))
      promulgateRC $ R.RecoverNode node
      publish $ R.RecoverNode node
      unregisterSpawnAsync sr
      return ()
  else Log.rcLog' Log.DEBUG "Node is already monitored."

-------------------------------------------------------------------------------
-- Node monitor angel
-------------------------------------------------------------------------------

labelMonitorAngel :: String
labelMonitorAngel = "rc.angel.node-monitor"

newtype MonitortedNodes = MonitoredNodes { getMonitoredNodes :: Set R.Node}

-- [Note: monitor angel request serialisation]
-- All requests to the node monitor should be serialised, this is needed
-- because otherwise we may have a race condition when angel didn't process
-- some message yet. In order to serialize such requests - we start keeping
-- wanted information in global RC state.

-- | Check if given monitor node is monitored by angel.
-- See [Note:monitor angel request serialisation]
isMonitored :: R.Node -> PhaseM RC l Bool
isMonitored node = do
  mmns <- getStorageRC
  return $ maybe False (Set.member node . getMonitoredNodes) mmns

-- | Start node monitoring using angel
-- See [Note:monitor angel request serialisation]
startMonitoring :: R.Node -> PhaseM RC l ()
startMonitoring node@(R.Node nid) = do
  Log.actLog "startMonitoring" [("nid", show nid)]
  Log.rcLog' Log.DEBUG "Adding new node to the cluster."
  mmns <- getStorageRC
  putStorageRC $ maybe (MonitoredNodes (Set.singleton node))
                       (MonitoredNodes . Set.insert node . getMonitoredNodes)
                       mmns
  liftProcess $ nsend labelMonitorAngel (AddNode nid)

-- | Stop node monitoring using Angel.
-- See [Note:monitor angel request serialisation]
stopMonitoring :: R.Node -> PhaseM RC l ()
stopMonitoring node@(R.Node nid) = do
  Log.actLog "stopMonitoring" [("nid", show nid)]
  mmns <- getStorageRC
  for_ mmns $ \mns -> putStorageRC $
    MonitoredNodes . Set.delete node . getMonitoredNodes $ mns
  liftProcess $ nsend labelMonitorAngel (RemoveNode nid)

data MonitorAngelCmd = AddNode NodeId
                     | RemoveNode NodeId
                     | IsMonitored NodeId ProcessId
                     deriving (Typeable, Generic)
instance Binary MonitorAngelCmd

data Heartbeat = Heartbeat deriving (Generic, Typeable)
instance Binary Heartbeat

data AngelMonUp = AngelMonUp deriving (Generic, Typeable)
instance Binary AngelMonUp

-- | Spawn a process acting on 'MonitorAngelCmd's. If no commands come
-- within '_hv_monitor_angel_delay' second period, 'Heartbeat' is sent
-- to all monitored nodes which allows network-transport to notice
-- connection breakage if there is any but otherwise no traffic is
-- happening.
registerNodeMonitoringAngel :: PhaseM RC l ()
registerNodeMonitoringAngel = do
  t <- getHalonVar _hv_monitoring_angel_delay
  pid <- liftProcess $ do
    rc <- getSelfPid
    pid <- spawnLocal $ do
      link rc
      me <- getSelfPid
      register labelMonitorAngel me
      usend rc AngelMonUp
      fix (\loop nodes -> do
        mcommand <- expectTimeout (t * 1000000)
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
            -- Monitoring is working only if there are some traffic between
            -- nodes otherwise network-transport implementation may not note
            -- connection breakage. So for each node that is connected to
            -- cluster we create some traffic by sending messages using named
            -- send.
            traverse_ (\n -> nsendRemote n "nonexistingprocess" Heartbeat) nodes
            loop nodes) []
    AngelMonUp <- expect
    return pid
  -- rg <- getGraph
  -- let nodes = (\(R.Node n) -> n) <$> G.connectedTo R.Cluster R.Has rg
  -- liftProcess $ for_ nodes $ usend pid . AddNode
  void $ registerProcessMonitor pid $ do
     Log.rcLog' Log.WARN "Node monitor angel has died, restarting."
     registerNodeMonitoringAngel
