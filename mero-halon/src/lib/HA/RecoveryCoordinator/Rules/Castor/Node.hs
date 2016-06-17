{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
-- |
-- Collection of the rules for maintaining castor node.
--
-- Castor node is a hardware node with running mero-kernel, such node
-- allow to start m0t1fs clients and m0d servers on it.
--
-- Related part of the resource graph:
--
-- @@@
--   R.Host --+- HostAttirbutes
--     |      |
--     |      +-- M0.Client
--     |      |
--     |      +-- M0.Server
--     |
--     |              +-- ServiceProcess
--     |              |
--     |      +--- Service m0d
--     |      |
--     |      |
--     +--- R.Node           M0.Filesystem
--            |                 |
--            |                 |
--            +------+    +-----+
--                   |    |
--                   M0.Node
--                      |
--                      |
--                    M0.Process
-- @@@
--
-- Lifetime
-- =========
--
-- Lifetime of the node decoupled from the lifetime of the services
-- running on it, and is connected to lifetime of the mero-kernel.
--
--
-- @@@
--                               |
--                               | NewMeroNode
--                               |
--               NodeStopped     |
--                  ^            V
--    Teardown      |        +-----------+            NodeStartRequest
--        +---------+------->|  Stopped  | ---------------+
--        |                  +-----------+                |
--        |                       ^                       |
--        |                       |                       v
--   +-----------+          +------------+        +-----------------+
--   | Stopping  |--------->| Failed     |------->| Starting        |
--   +-----------+          +------------+        +-----------------+
--        ^                      ^                        |
--        |                      |                        |
--        |                 +------------+                |
--        |                 | Inhibited  |                |
--        |                 +------------+                |
--        |                   ^        |                  |
--        |                   |        v                  |
--        |                 +-----------+                 |
--        +-----------------| Online    |<---+------------+
--  RequestStopHalonM0d     +-----------+    |
--                           ^       ^       v
--                           |       |      NodeStarted
--                           |       |
--                           |       v
--                           |  <StartProcessesOnNode>
--                           |
--                           v
--                    <StartClientsOnNode>
-- @@@
--
module HA.RecoveryCoordinator.Rules.Castor.Node
  ( -- * All rules
    rules
   -- ** Events
  , eventNewHalonNode
  , eventKernelStarted
  , eventKernelFailed
    -- ** Requests
    -- $requests
  , requestStartHalonM0d
  , requestStopHalonM0d
    -- ** Processes
    -- *** Create new node
  , processNodeNew
  , StartProcessNodeNew
  , ruleNodeNew
    -- *** Start processes on node
  , processStartProcessesOnNode
  , ruleStartProcessesOnNode
  , StartProcessesOnNodeRequest(..)
  , StartNodeResult(..)
    --- *** Stop clients on node
  , processStopClientsOnNode
  , StartClientsOnNodeRequest(..)
  , StartClientsOnNodeResult(..)
    -- *** Stop processes on node
  , processStopProcessesOnNode
  , StopProcessesOnNodeRequest(..)
  , StopProcessesOnNodeResult(..)
  , ruleStopProcessesOnNode
    -- * Helpers
  , maxTeardownLevel
  ) where

import           HA.Service
import           HA.EventQueue.Types
import           HA.RecoveryCoordinator.Actions.Core
import           HA.RecoveryCoordinator.Actions.Hardware
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Actions.Job
import           HA.RecoveryCoordinator.Actions.Service (lookupRunningService)
import           HA.RecoveryCoordinator.Events.Castor.Cluster
import           HA.RecoveryCoordinator.Events.Mero
import           HA.RecoveryCoordinator.Rules.Mero.Conf
import           HA.Services.Mero
import           HA.Services.Mero.CEP (meroChannel)
import qualified HA.RecoveryCoordinator.Events.Cluster as Event
import           HA.RecoveryCoordinator.Actions.Castor.Cluster

import           Control.Distributed.Process(Process, spawnLocal, spawnAsync)
import           Control.Distributed.Process.Closure
import           Control.Monad.Trans.Maybe
import           HA.Service (ServiceStopRequest(..))

import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import qualified HA.ResourceGraph as G
import           Data.Proxy (Proxy(..))
import           Data.Foldable (for_)
import           Data.Maybe (listToMaybe, fromMaybe, isNothing, isJust)
import           Control.Applicative
import           Control.Lens
import           Control.Monad (void, when, guard, join)

import           System.Posix.SysInfo

import Network.CEP
import Data.Binary (Binary)
import           Data.Vinyl
import           Text.Printf
import GHC.Generics

-- | All rules related to node.
-- Expected to be used in RecoveryCoordinator code.
rules :: Definitions LoopState ()
rules = sequence_
  [ ruleNodeNew
  , ruleStartProcessesOnNode
  , ruleStartClientsOnNode
  , ruleStopProcessesOnNode
  , requestStartHalonM0d
  , requestStopHalonM0d
  , eventNewHalonNode
  , eventKernelStarted
  , eventKernelFailed
  ]

-- | Timeout to wait for reply from node.
tearDownTimeout :: Int
tearDownTimeout = 5*60 -- 5m

-- | Bootlevel that RC procedure is started at.
maxTeardownLevel :: Int
maxTeardownLevel = 3 -- XXX: move to cluster constants.

--------------------------------------------------------------------------------
-- Extensible record fields
--------------------------------------------------------------------------------

type FldHostHardwareInfo = '("mhostHardwareInfo", Maybe HostHardwareInfo)
fldHostHardwareInfo :: Proxy FldHostHardwareInfo
fldHostHardwareInfo = Proxy


type FldHost = '("host", Maybe R.Host)
fldHost :: Proxy FldHost
fldHost = Proxy

type FldNode = '("node", Maybe R.Node)
fldNode :: Proxy FldNode
fldNode = Proxy

type FldBootLevel = '("bootlevel", Maybe M0.BootLevel)
fldBootLevel :: Proxy FldBootLevel
fldBootLevel = Proxy

-------------------------------------------------------------------------------
-- Events handling
-------------------------------------------------------------------------------

-- | When new satellite is connected to halon cluster, start procedure of adding
-- this node to castor cluster.
--
-- Listens: 'Event.NewNodeConnected'
-- Emits:   'StartProcessNodeNew'
eventNewHalonNode :: Definitions LoopState ()
eventNewHalonNode = defineSimpleTask "castor::node::event::new-node" $ \(Event.NewNodeConnected node) ->
  promulgateRC $! StartProcessNodeNew node

-- | Handle a case when mero-kernel was started on node. Trigger bootstrap
-- process.
--
-- Listens:         'MeroChannelDeclared'
-- Emits:           'NodeStarted'
-- State-Changes:   'M0.Node' online
eventKernelStarted :: Definitions LoopState ()
eventKernelStarted = defineSimpleTask "castor::node::event::kernel-started" $ \(MeroChannelDeclared sp _ _) -> do
  g <- getLocalGraph
  let nodes = [m0node | node :: R.Node <- G.connectedFrom R.Runs sp g
                      , m0node <- nodeToM0Node node g
                      ]
  applyStateChanges $ (`stateSet` M0.M0_NC_ONLINE) <$> nodes
  for_ nodes $ notify . NodeStarted

-- | Handle a case when mero-kernel failed to start on the node. Mark node as failed.
--
-- Listens:      'MeroKernelFailed'
-- Emits:        'NodeKernelFailed'
-- State-Changes: 'M0.Node' Failed
eventKernelFailed :: Definitions LoopState ()
eventKernelFailed = defineSimpleTask "castor::node::event::kernel-failed" $ \(MeroKernelFailed pid _) -> do
  g <- getLocalGraph
  let sp = ServiceProcess pid :: ServiceProcess MeroConf
  let nodes = [m0node | node :: R.Node <- G.connectedFrom R.Runs sp g
                      , m0node <- nodeToM0Node node g
                      ]
  applyStateChanges $ (`stateSet` M0.M0_NC_ONLINE) <$> nodes
  for_ nodes $ notify . NodeKernelFailed

{-
eventStopHalonM0dFinished :: Definitions LoopState ()
eventStopHalonM0dFinished = defineSimpleTask "castor::node::event::halon-m0d-stopped" $
  \(..) -> do g <- getLocalGraph
              undefined -- XXX: mark node as stopped
-}

-------------------------------------------------------------------------------
-- Requests handling
-------------------------------------------------------------------------------
-- $requests
--
-- Some requests are handled by long running processes, see
-- 'processNodeNew', 'processNodeStart' for details.


-- | Once mero node is in resource graph and cluster is started
-- rule starts generates node kernel config and starts mero-kernel
-- service and halon:m0d process there.
--
-- Listens:   'StartHalonM0dRequest'
requestStartHalonM0d :: Definitions LoopState ()
requestStartHalonM0d = defineSimpleTask "castor::node::request::start-halon-m0d" $
  \(StartHalonM0dRequest m0node) -> do
    rg <- getLocalGraph
    case listToMaybe $ G.connectedTo R.Cluster R.Has rg of
      Just M0.MeroClusterStopped -> phaseLog "info" "Cluster is stopped."
      Just M0.MeroClusterStopping{} -> phaseLog "info" "Cluster is stopping."
      Just M0.MeroClusterFailed -> phaseLog "info" "Cluster is in failed state, doing nothing."
      _ -> case listToMaybe $ m0nodeToNode m0node rg of
             Just node@(R.Node nid) ->
               findNodeHost node >>= \case
                 Just host -> do
                   phaseLog "info" $ "Starting new mero server " ++ show nid
                   let mlnid = (listToMaybe [ ip | M0.LNid ip <- G.connectedTo host R.Has rg ])
                           <|> (listToMaybe $ [ ip | CI.Interface { CI.if_network = CI.Data, CI.if_ipAddrs = ip:_ }
                                                   <- G.connectedTo host R.Has rg ])
                   case mlnid of
                     Nothing ->
                       phaseLog "error" $ "Unable to find Data IP addr for host " ++ show host
                     Just lnid -> do
                       createMeroKernelConfig host $ lnid ++ "@tcp"
                       startMeroService host node
                 Nothing -> phaseLog "error" $ "Can't find R.Host for node " ++ show node
             Nothing -> phaseLog "error" $ "Can't find R.Host for node " ++ show m0node

-- | Request to stop halon node.
--
-- XXX: actually mero-kernel can't be stopped at the moment as halon can't
-- unload mero modules.
requestStopHalonM0d :: Definitions LoopState ()
requestStopHalonM0d = defineSimpleTask "castor::node::request::stop-halon-m0d" $
  \(StopHalonM0dRequest m0node) -> do
     rg <- getLocalGraph
     case listToMaybe $ m0nodeToNode m0node rg of
       Nothing -> phaseLog "error" $ "Can't find R.Host for node " ++ show m0node
       Just node -> do applyStateChanges [stateSet m0node M0.M0_NC_FAILED]
                       promulgateRC $ encodeP $ ServiceStopRequest node m0d


-------------------------------------------------------------------------------
-- Processes
-------------------------------------------------------------------------------

-- | Process that creates new castor node. Performs a load of all
-- required host information in case if it was not provided by initial data,
-- and register node withing a castor cluster in that case.
processNodeNew :: Job StartProcessNodeNew NewMeroServer
processNodeNew = Job "castor::node::process::new"

-- | Request start of the 'ruleNewNode'.
newtype StartProcessNodeNew  = StartProcessNodeNew R.Node
  deriving (Eq, Show, Generic, Binary, Ord)

ruleNodeNew :: Definitions LoopState ()
ruleNodeNew = mkJobRule processNodeNew args $ \finish -> do
  confd_running   <- phaseHandle "confd-running"
  config_created  <- phaseHandle "client-config-created"
  wait_data_load  <- phaseHandle "wait-bootstrap"
  announce        <- phaseHandle "announce"
  query_host_info <- mkQueryHostInfo config_created finish

  let route node = getFilesystem >>= \case
        Nothing -> return [wait_data_load]
        Just _ -> do
          mnode <- findNodeHost node
          if isJust mnode
          then do phaseLog "info" $ show node ++ " is already in configuration."
                  return [announce]
          else return [query_host_info]

  let check (StartProcessNodeNew node) = do
        mhost <- findNodeHost node
        if isNothing mhost
        then do
          phaseLog "error" $ "NewMeroClient sent for node with no host: " ++ show node
          return Nothing
        else Just <$> route node

  directly config_created $ do
    Just fs <- getFilesystem
    Just host <- getField . rget fldHost <$> get Local
    Just hhi <- getField . rget fldHostHardwareInfo <$> get Local
    createMeroClientConfig fs host hhi
    continue confd_running

  setPhase wait_data_load $ \(HAEvent _ Event.InitialDataLoaded _) -> do
    Just (StartProcessNodeNew node) <- getField . rget fldReq <$> get Local
    route node >>= switch

  setPhaseIf confd_running (barrierPass (>= (M0.MeroClusterStarting (M0.BootLevel 1)))) $ \() -> do
    syncStat <- syncToConfd
    case syncStat of
      Left err -> do phaseLog "error" $ "Unable to sync new client to confd: " ++ show err
                     continue finish
      Right () -> continue announce

  directly announce $ do
    mreq <- getField . rget fldReq <$> get Local
    for_ mreq $ \(StartProcessNodeNew node) ->
      modify Local $ rlens fldRep .~ (Field . Just $ NewMeroServer node)
    continue finish

  return check
  where
    fldReq :: Proxy '("request", Maybe StartProcessNodeNew)
    fldReq = Proxy
    fldRep :: Proxy '("reply", Maybe NewMeroServer)
    fldRep = Proxy
    args = fldHost =: Nothing
       <+> fldNode =: Nothing
       <+> fldHostHardwareInfo =: Nothing
       <+> fldUUID =: Nothing
       <+> fldReq  =: Nothing
       <+> fldRep  =: Nothing
       <+> RNil

-- | Rule fragment: query node hardware information.
mkQueryHostInfo :: forall l. (FldHostHardwareInfo ∈ l, FldHost ∈ l, FldNode ∈ l)
              => Jump PhaseHandle -- ^ Phase handle to jump to on completion
              -> Jump PhaseHandle -- ^ Phase handle to jump to on failure.
              -> RuleM LoopState (FieldRec l) (Jump PhaseHandle) -- ^ Handle to start on
mkQueryHostInfo andThen orFail = do
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



-- | Process that will bootstrap mero node.
-- @@@
-- ----- NewNodeConnected -------------+
--                                     |
--                                     v
--                    +--------------------------------+
--                    |  check if node is registered   |---- yes --> finish
--                    +--------------------------------+
--                                    |
--                                    | no
--                                    v
--                    +--------------------------------+
--                    | load host info                 |
--                    +--------------------------------+
--  cluster rules                     |
--  BarrierPass 0 ------------------->|
--                                    |
--                    +--------------------------------+
--                    | update confd                   |
--                    +--------------------------------+
--                                    |
--                                    |------ Request New Node start ---------->
--                                    |
--                                  finish
--  @@@
processStartProcessesOnNode :: Job StartProcessesOnNodeRequest StartNodeResult
processStartProcessesOnNode = Job "castor::node::process::start"

-- | Handle of the 'ruleNewNode' process.
data StartNodeResult
      = NodeStarted M0.Node
      | NodeStartTimeout M0.Node
      | NodeStartKernelFailure M0.Node
  deriving (Eq, Show, Generic)

instance Binary StartNodeResult

-- | Upon receiving 'StartProcessOnNodeRequest' message, bootstraps the given
-- node, when it's possible.
--
-- * Start halon's mero service on the node if needed. This starts the
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
--
ruleStartProcessesOnNode :: Definitions LoopState ()
ruleStartProcessesOnNode = mkJobRule processStartProcessesOnNode args $ \finish -> do
    kernel_up         <- phaseHandle "kernel_up"
    kernel_failed     <- phaseHandle "kernel_failed"
    boot_level_0      <- phaseHandle "boot_level_0"
    boot_level_1      <- phaseHandle "boot_level_1"
    bootstrap_timeout <- phaseHandle "bootstrap_timeout"
    start_clients     <- phaseHandle "start_clients"

    let route (StartProcessesOnNodeRequest m0node) = runMaybeT $ do
          node <- MaybeT $ listToMaybe . m0nodeToNode m0node <$> getLocalGraph -- XXX: list
          MaybeT $ do
            rg <- getLocalGraph
            srv <- lookupRunningService node m0d -- XXX: head
            let chan = srv >>= meroChannel rg :: Maybe (TypedChannel ProcessControlMsg)
            host <- findNodeHost node  -- XXX: head
            modify Local $ rlens fldHost .~ (Field $ host)
            modify Local $ rlens fldNode .~ (Field $ Just node)
            if isJust chan
            then return $ Just [boot_level_0]
            else do phaseLog "info" $ "starting mero processes on node " ++ show m0node
                    promulgateRC $ StartHalonM0dRequest m0node
                    return $ Just [kernel_up, kernel_failed, timeout 180 bootstrap_timeout]

    setPhaseIf kernel_up (\(NodeStarted node) _ l ->  -- XXX: HA event?
       case getField $ rget fldReq l of
         Just (StartProcessesOnNodeRequest m0node)
            | node == m0node -> return $ Just ()
         _ -> return Nothing
      ) $ \() -> continue boot_level_0

    setPhaseIf kernel_failed (\(HAEvent eid (NodeKernelFailed node) _) _ l ->
       case getField $ rget fldReq l of
         Just (StartProcessesOnNodeRequest m0node)
            | node == m0node -> return $ Just (eid, m0node)
         _  -> return Nothing
       ) $ \(eid, m0node) -> do
      todo eid
      modify Local $ rlens fldRep .~ (Field . Just $ NodeStartKernelFailure m0node)
      done eid
      continue finish

    directly boot_level_0 $ do
      Just (StartProcessesOnNodeRequest m0node) <- getField . rget fldReq <$> get Local
      Just node <- getField . rget fldNode <$> get Local
      Just host <- getField . rget fldHost <$> get Local
      g <- getLocalGraph
      m0svc <- lookupRunningService node m0d
      case m0svc >>= meroChannel g of
        Just chan -> do
          _ <- startNodeProcesses host chan (M0.PLBootLevel (M0.BootLevel 0)) True
          switch [boot_level_1, timeout 180 bootstrap_timeout]
        Nothing -> do
          phaseLog "error" $ "Can't find service for node " ++ show node
          modify Local $ rlens fldRep .~ (Field . Just $ NodeStartKernelFailure m0node)
          continue finish

    setPhaseIf boot_level_1 (barrierPass (>= (M0.MeroClusterStarting (M0.BootLevel 1)))) $ \() -> do
      Just node <- getField . rget fldNode <$> get Local
      Just host <- getField . rget fldHost <$> get Local
      g <- getLocalGraph
      m0svc <- lookupRunningService node m0d
      case m0svc >>= meroChannel g of
        Just chan -> do
          procs <- startNodeProcesses host chan (M0.PLBootLevel (M0.BootLevel 1)) True
          continue finish
        Nothing -> do
          phaseLog "error" $ "Can't find service for node " ++ show node
          continue finish

    return route
  where
    fldReq :: Proxy '("request", Maybe StartProcessesOnNodeRequest)
    fldReq = Proxy
    fldRep :: Proxy '("reply", Maybe StartNodeResult)
    fldRep = Proxy
    args = fldUUID =: Nothing
       <+> fldReq  =: Nothing
       <+> fldNode =: Nothing
       <+> fldRep  =: Nothing
       <+> fldHost =: Nothing
       <+> RNil


processStopClientsOnNode :: Job StartClientsOnNodeRequest StartClientsOnNodeResult
processStopClientsOnNode = Job "castor::node::client::start"

data StartClientsOnNodeResult
       = StartClientsOnNodeResultOk
       | InvariantViolation
       deriving (Eq, Show, Generic)

instance Binary StartClientsOnNodeResult

-- | Start all clients on the given node.
ruleStartClientsOnNode :: Definitions LoopState ()
ruleStartClientsOnNode = mkJobRule processStopClientsOnNode args $ \finish -> do
   start_clients <- phaseHandle "start-clients"
   await_barrier <- phaseHandle "await_barrier"

   let route (StartClientsOnNodeRequest m0node) = do
         phaseLog "debug" $ "request start client for " ++ show m0node
         rg <- getLocalGraph
         let mnode = listToMaybe $ m0nodeToNode m0node rg
         mhost <- join <$> traverse findNodeHost mnode
         case liftA2 (,) mnode mhost of
           Nothing -> return Nothing
           Just (node,host) -> do
             modify Local $ rlens fldNode .~ (Field $ Just node)
             modify Local $ rlens fldHost .~ (Field $ Just host)
             case listToMaybe $ G.connectedTo R.Cluster R.Has rg of
                Just M0.MeroClusterRunning -> return $ Just [start_clients]
                _ -> return $ Just [await_barrier]

   setPhaseIf await_barrier (barrierPass (>= M0.MeroClusterRunning)) $ \() -> do
      phaseLog "debug" $ "waiting for barrier"
      continue start_clients

   directly start_clients $ do
      rg <- getLocalGraph
      Just node <- getField . rget fldNode <$> get Local
      Just host <- getField . rget fldHost <$> get Local
      m0svc <- lookupRunningService node m0d
      case m0svc >>= meroChannel rg of
        Just chan -> do
          phaseLog "info" $ "Starting mero client on " ++ show host
          procs <- startNodeProcesses host chan M0.PLM0t1fs False
          continue finish
        Nothing -> do
          phaseLog "error" $ "can't find mero channel on " ++ show node
          continue finish

   return route
  where
    fldReq :: Proxy '("request", Maybe StartClientsOnNodeRequest)
    fldReq = Proxy
    fldRep :: Proxy '("reply", Maybe StartClientsOnNodeResult)
    fldRep = Proxy
    args  = fldUUID =: Nothing
        <+> fldReq     =: Nothing
        <+> fldRep     =: Nothing
        <+> fldNode    =: Nothing
        <+> fldHost    =: Nothing
        <+> RNil


processStopProcessesOnNode :: Job StopProcessesOnNodeRequest  StopProcessesOnNodeResult
processStopProcessesOnNode = Job "castor::node::stop-processes"

data StopProcessesOnNodeResult
       = StopProcessesOnNodeOk
       | StopProcessesOnNodeTimeout
       | StopProcessesOnNodeStateChanged M0.MeroClusterState
       deriving (Eq, Show, Generic)

instance Binary StopProcessesOnNodeResult

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
ruleStopProcessesOnNode :: Definitions LoopState ()
ruleStopProcessesOnNode = mkJobRule processStopProcessesOnNode args $ \finish -> do
   teardown   <- phaseHandle "teardown"
   teardown_exec <- phaseHandle "teardown-exec"
   teardown_timeout  <- phaseHandle "teardown-timeout"
   await_barrier <- phaseHandle "await-barrier"
   stop_service <- phaseHandle "stop-service"

   -- Continue process on the next boot level. This method include only
   -- numerical bootlevels.
   let nextBootLevel = do
         Just (M0.BootLevel i) <- getField . rget fldBootLevel <$> get Local
         modify Local $ rlens fldBootLevel .~ (Field $ Just $ M0.BootLevel (i-1)) -- XXX: improve lens
         continue teardown
   -- Check if there are any processes left to be stopped on current bootlevel.
   -- If there are any process - then just process current message (meid),
   -- If there are no process left then move cluster to next bootlevel and prepare
   -- all technical information in RG, then emit BarrierPassed function.
   let notifyBarrier meid = do
         Just b <- getField . rget fldBootLevel <$> get Local
         notifyOnClusterTransition (>= (M0.MeroClusterStopping b)) BarrierPass meid

   let route (StopProcessesOnNodeRequest m0node) = do
         rg <- getLocalGraph
         let mnode = listToMaybe $ m0nodeToNode m0node rg
         case mnode of
           Nothing -> do phaseLog "error" $ "No castor node for " ++ show m0node
                         return Nothing
           Just node -> do modify Local $ rlens fldNode .~ (Field . Just $ node)
                           modify Local $ rlens fldBootLevel .~ (Field . Just $ M0.BootLevel maxTeardownLevel)
                           return $ Just [teardown]

   directly teardown $ do
     Just node <- getField . rget fldNode <$> get Local
     Just lvl@(M0.BootLevel i) <- getField . rget fldBootLevel <$> get Local
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
       M0.MeroClusterFailed{}
           | i < 0 -> continue stop_service
           | otherwise -> continue teardown_exec
       st  -> do modify Local $ rlens fldRep .~ (Field . Just $ StopProcessesOnNodeStateChanged st)
                 continue finish

   directly teardown_exec $ do
     Just node <- getField . rget fldNode <$> get Local
     Just lvl  <- getField . rget fldBootLevel <$> get Local
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
                for_ maction id
                phaseLog "debug" $ printf "Can't find data for %s - continue to timeout" (show node)
                continue teardown_timeout

   directly teardown_timeout $ do
     Just node <- getField . rget fldNode <$> get Local
     Just (StopProcessesOnNodeRequest m0node) <- getField . rget fldReq <$> get Local
     Just lvl <- getField . rget fldBootLevel <$> get Local
     phaseLog "warning" $ printf "%s failed to stop services (timeout)" (show node)
     rg <- getLocalGraph
     let failedProcs = getLabeledNodeProcesses node (mkLabel lvl) rg
     -- XXX: quite possibly we want to say they are inhibited, as we are not
     -- sure.
     applyStateChanges $ (\p -> stateSet p $ M0.PSFailed "Timeout on stop.")
                          <$> failedProcs
     applyStateChanges [stateSet m0node M0.M0_NC_FAILED]
     modify Local $ rlens fldRep .~ (Field . Just $ StopProcessesOnNodeTimeout)
     continue finish

   setPhaseIf await_barrier (\(BarrierPass i) _ minfo ->
     runMaybeT $ do
       lvl <- MaybeT $ return $ getField . rget fldBootLevel $ minfo
       guard (i <= M0.MeroClusterStopping lvl)
       return ()
     ) $ \() -> continue teardown

   directly stop_service $ do
     Just node <- getField . rget fldNode <$> get Local
     phaseLog "info" $ printf "%s stopped all mero services - stopping halon mero service."
                              (show node)
     continue finish
   return route
  where
    fldReq :: Proxy '("request", Maybe StopProcessesOnNodeRequest)
    fldReq = Proxy
    fldRep :: Proxy '("reply", Maybe StopProcessesOnNodeResult)
    fldRep = Proxy
    args = fldUUID =: Nothing
       <+> fldReq  =: Nothing
       <+> fldNode =: Nothing
       <+> fldRep  =: Nothing
       <+> fldHost =: Nothing
       <+> fldBootLevel =: Nothing
       <+> RNil

-- | Given 'M0.BootLevel', generate a corresponding 'M0.ProcessLabel'.
mkLabel :: M0.BootLevel -> M0.ProcessLabel
mkLabel bl@(M0.BootLevel l)
  | l == maxTeardownLevel = M0.PLM0t1fs
  | otherwise = M0.PLBootLevel bl
