{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Collection of the rules for maintaining castor node.
--
-- Castor node is a hardware node with running mero-kernel, such node
-- allow to start m0t1fs clients and m0d servers on it.
--
-- Related part of the resource graph:
--
-- @
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
-- @
--
-- Lifetime
-- =========
--
-- Lifetime of the node decoupled from the lifetime of the services
-- running on it, and is connected to lifetime of the mero-kernel.
--
--
-- @
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
-- @
module HA.RecoveryCoordinator.Castor.Node.Rules
  ( -- * All rules
    rules
   -- ** Events
  , eventNewHalonNode
  , eventCleanupFailed
  , eventKernelFailed
  , eventBEError
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
  , StartProcessesOnNodeResult(..)
    --- *** Stop clients on node
  , StartClientsOnNodeRequest(..)
  , StartClientsOnNodeResult(..)
    -- *** Stop processes on node
  , StopProcessesOnNodeRequest(..)
  , StopProcessesOnNodeResult(..)
  , ruleStopProcessesOnNode
    -- * Helpers
  , maxTeardownLevel
  ) where

import           Control.Applicative
import           Control.Distributed.Process(Process, spawnLocal, spawnAsync, sendChan)
import           Control.Distributed.Process.Closure
import           Control.Lens
import           Control.Monad (void, guard, join, when)
import           Control.Monad.Trans.Maybe
import           Data.Foldable (for_)
import           Data.Maybe (listToMaybe, isNothing, isJust, maybeToList)
import           Data.Monoid ((<>))
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TL
import           Data.Typeable
import           Data.UUID (UUID)
import           Data.Vinyl
import qualified HA.Aeson as Aeson
import           HA.Encode
import           HA.EventQueue
import           HA.RecoveryCoordinator.Actions.Hardware
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Castor.Cluster.Actions
import           HA.RecoveryCoordinator.Castor.Cluster.Events
import           HA.RecoveryCoordinator.Castor.Node.Actions as Node
import           HA.RecoveryCoordinator.Castor.Node.Events
import qualified HA.RecoveryCoordinator.Castor.Node.Events as Event
import qualified HA.RecoveryCoordinator.Castor.Process.Actions as Process
import           HA.RecoveryCoordinator.Castor.Process.Events
import           HA.RecoveryCoordinator.Job.Actions
import           HA.RecoveryCoordinator.Job.Events
import           HA.RecoveryCoordinator.Mero.Events
import           HA.RecoveryCoordinator.Mero.Notifications
import           HA.RecoveryCoordinator.Mero.State
import           HA.RecoveryCoordinator.Mero.Transitions
import qualified HA.RecoveryCoordinator.Mero.Transitions.Internal as TrI
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Events.Cluster as Event
import           HA.RecoveryCoordinator.Service.Actions (lookupInfoMsg)
import           HA.RecoveryCoordinator.Service.Events as Service
import qualified HA.ResourceGraph as G
import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Castor.Initial as CI
import           HA.Resources.HalonVars
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           HA.Service
import           HA.Service.Interface
import           HA.Services.Mero
import           HA.Services.SSPL.CEP ( sendInterestingEvent )
import           HA.Services.SSPL.IEM ( logMeroBEError )
import           HA.Services.SSPL.LL.Resources ( InterestingEventMessage(..) )
import           Mero.ConfC (ServiceType(..))
import           Mero.Notification.HAState (BEIoErr, HAMsg(..), HAMsgMeta(..))
import           Network.CEP
import           System.Posix.SysInfo
import           Text.Printf

-- | All rules related to node.
-- Expected to be used in RecoveryCoordinator code.
rules :: Definitions RC ()
rules = sequence_
  [ ruleNodeNew
  , ruleStartProcessesOnNode
  , ruleStartClientsOnNode
  , ruleStopProcessesOnNode
  , ruleFailNodeIfProcessCantRestart
  , ruleMaintenanceStopNode
  , requestUserStopsNode
  , requestStartHalonM0d
  , requestStopHalonM0d
  , eventNewHalonNode
  , eventCleanupFailed
  , eventKernelFailed
  , eventBEError
  ]

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

type FldBootLevel = '("bootlevel", M0.BootLevel)
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
eventNewHalonNode :: Definitions RC ()
eventNewHalonNode = defineSimple "castor::node::event::new-node" $ \(Event.NewNodeConnected node) -> do
  promulgateRC $! StartProcessNodeNew node

-- | Handle a case when mero-kernel failed to start on the node. Mark node as failed.
-- Stop halon:m0d service on the node.
--
-- Listens:      'MeroKernelFailed'
-- State-Changes: 'M0.Node' Failed
eventKernelFailed :: Definitions RC ()
eventKernelFailed = define "castor::node::event::kernel-failed" $ do
  mero_kernel_failed <- phaseHandle "mero_kernel_failed"

  setPhaseIf mero_kernel_failed g $ \(uid, nid, msg) -> do
    todo uid
    rg <- getLocalGraph
    let node = R.Node nid
        mm0node = M0.nodeToM0Node node rg
        mhaprocess = mm0node >>= \m0n -> Process.getHA m0n rg
    let failMsg = "mero-kernel failed to start: " ++ msg
    for_ mhaprocess $ \hp -> do
      applyStateChanges [stateSet hp $! processFailed failMsg]
    promulgateRC $ encodeP $ ServiceStopRequest node (lookupM0d rg)
    for_ mm0node $ notify . KernelStartFailure
    done uid

  start mero_kernel_failed ()
  where
    g (HAEvent uid (MeroKernelFailed nid msg)) _ _ = return $! Just (uid, nid, msg)
    g _ _ _ = return Nothing

-- | Handle a case when mero-cleanup failed to start on the node. Currently we
--   treat this as a kernel failure, as it effectively is.
--
-- Listens:      'MeroCleanupFailed'
-- State-Changes: 'M0.Node' Failed
eventCleanupFailed :: Definitions RC ()
eventCleanupFailed = define "castor::node::event::cleanup-failed" $ do
  cleanup_failed <- phaseHandle "cleanup-failed"

  setPhaseIf cleanup_failed g $ \(uid, nid, msg) -> do
    todo uid
    rg <- getLocalGraph
    let node = R.Node nid
        mm0node = M0.nodeToM0Node node rg
        mhaprocess = mm0node >>= \m0n -> Process.getHA m0n rg
    let failMsg = "mero-cleanup failed to start: " ++ msg
    for_ mhaprocess $ \hp -> do
      applyStateChanges [stateSet hp $! processFailed failMsg]
    promulgateRC $ encodeP $ ServiceStopRequest node (lookupM0d rg)
    for_ mm0node $ notify . KernelStartFailure
    done uid

  start cleanup_failed ()
  where
    g (HAEvent uid (MeroCleanupFailed nid msg)) _ _ = return $! Just (uid, nid, msg)
    g _ _ _ = return Nothing

-- | Handle error being thrown from Mero BE. This typically indicates something
--   like a RAID failure, but there's nothing we can do about it. It indicates
--   an unrecoverable failure; we need to mark the node as failed and send an
--   appropriate IEM.
eventBEError :: Definitions RC ()
eventBEError = defineSimpleTask "castor::node::event::be-error"
  $ \(HAMsg (beioerr :: BEIoErr) meta) -> do
    lookupConfObjByFid (_hm_source_process meta) >>= \case
      Nothing -> do
        phaseLog "warning" $ "Unknown source process."
        phaseLog "metadata" $ show meta
      Just (sendingProcess :: M0.Process) -> do
        mnode <- G.connectedFrom M0.IsParentOf sendingProcess
                <$> getLocalGraph
        case mnode of
          Just (node :: M0.Node) -> do
              -- Log an IEM about this error
              sendInterestingEvent . InterestingEventMessage $ logMeroBEError
                 ( "{ 'metadata':" <> code meta
                <> ", 'beError':" <> code beioerr
                <> "}" )
              applyStateChanges [stateSet node nodeFailed]
            where
              code :: Aeson.ToJSON a => a -> T.Text
              code = TL.toStrict . TL.decodeUtf8 . Aeson.encode
          Nothing -> do
            phaseLog "error" $ "No node found for source process."
            phaseLog "metadata" $ show meta

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
requestStartHalonM0d :: Definitions RC ()
requestStartHalonM0d = defineSimpleTask "castor::node::request::start-halon-m0d" $
  \(StartHalonM0dRequest m0node) -> do
    rg <- getLocalGraph
    case getClusterStatus rg of
      Just (M0.MeroClusterState M0.OFFLINE _ _) -> do
         phaseLog "info" "Cluster disposition is OFFLINE."
      _ -> case M0.m0nodeToNode m0node rg of
             Just node@(R.Node nid) ->
               findNodeHost node >>= \case
                 Just host -> do
                   phaseLog "info" $ "Starting new mero server."
                   phaseLog "info" $ "node.host = " ++ show nid
                   let mlnid = (listToMaybe [ ip | M0.LNid ip <- G.connectedTo host R.Has rg ])
                           <|> (listToMaybe $ [ ip | CI.Interface { CI.if_network = CI.Data, CI.if_ipAddrs = ip:_ }
                                                   <- G.connectedTo host R.Has rg ])
                   case mlnid of
                     Nothing ->
                       phaseLog "error" $ "Unable to find Data IP addr for host " ++ show host
                     Just lnid -> do
                       phaseLog "info" $ "node.lnid = " ++ show lnid
                       createMeroKernelConfig host $ lnid ++ "@tcp"
                       startMeroService host node
                 Nothing -> phaseLog "error" $ "Can't find R.Host for node " ++ show node
             Nothing -> phaseLog "error" $ "Can't find R.Host for node " ++ show m0node

halonM0dStopJob :: Job StopHalonM0dRequest StopHalonM0dResult
halonM0dStopJob = Job "castor::node::request::stop-halon-m0d"

-- | Request to stop halon node.
requestStopHalonM0d :: Definitions RC ()
requestStopHalonM0d = mkJobRule halonM0dStopJob args $ \(JobHandle _ finish) -> do
  service_stop_result <- phaseHandle "service_stop_result"

  let route (StopHalonM0dRequest node) = do
        rg <- getLocalGraph
        let mhp = M0.nodeToM0Node node rg >>= \m0n -> Process.getHA m0n rg
        case mhp of
          Nothing -> do
            return $ Right (HalonM0dNotFound, [finish])
          Just hp -> do
            -- Only apply state change when we're online.
            when (M0.getState hp rg == M0.PSOnline) $ do
              applyStateChanges [stateSet hp processHAStopping]
            j <- startJob . encodeP $ ServiceStopRequest node (lookupM0d rg)
            modify Local $ rlens fldJob . rfield .~ Just j
            return $ Right ( HalonM0dStopResult ServiceStopTimedOut
                           , [service_stop_result])

  setPhaseIf service_stop_result ourJob $ \r -> do
    modify Local $ rlens fldRep . rfield .~ Just (HalonM0dStopResult r)
    continue finish

  return route
  where
    ourJob (JobFinished lis v) _ ls = case getField $ rget fldJob ls of
      Just l | l `elem` lis -> return $ Just v
      _ -> return Nothing

    fldReq = Proxy :: Proxy '("request", Maybe StopHalonM0dRequest)
    fldRep = Proxy :: Proxy '("reply", Maybe StopHalonM0dResult)
    fldJob = Proxy :: Proxy '("job", Maybe ListenerId)
    args = fldReq =: Nothing
       <+> fldRep =: Nothing
       <+> fldJob =: Nothing

-------------------------------------------------------------------------------
-- Processes
-------------------------------------------------------------------------------

-- | Process that creates new castor node. Performs a load of all
-- required host information in case if it was not provided by initial data,
-- and register node withing a castor cluster in that case.
processNodeNew :: Job StartProcessNodeNew NewMeroServer
processNodeNew = Job "castor::node::process::new"

-- | Ensures that relevant data for the node is in RG; if not, the
-- info is queried. Waits if initial data is not loaded. In case it's
-- a new node (i.e. not one in RG), waits for confd to be available
-- and syncs. Starts processes on the node through
-- 'retriggerMeroNodeBootstrap'.
ruleNodeNew :: Definitions RC ()
ruleNodeNew = mkJobRule processNodeNew args $ \(JobHandle getRequest finish) -> do
  confd_running   <- phaseHandle "confd-running"
  config_created  <- phaseHandle "client-config-created"
  wait_data_load  <- phaseHandle "wait-bootstrap"
  reconnect_m0d   <- phaseHandle "reconnect_m0d"
  announce        <- phaseHandle "announce"
  query_host_info <- mkQueryHostInfo config_created finish
  (synchronized, synchronize) <- mkSyncToConfd (rlens fldConfSyncState . rfield) announce
  dispatch <- mkDispatcher
  notifier <- mkNotifierSimple dispatch

  let route node = getFilesystem >>= \case
        Nothing -> return [wait_data_load]
        Just _ -> do
          mnode <- findNodeHost node
          if isJust mnode
          then do phaseLog "info" $ show node ++ " is already in configuration."
                  return [reconnect_m0d]
          else return [query_host_info]

  let check (StartProcessNodeNew node) = do
        mhost <- findNodeHost node
        if isNothing mhost
        then do
          phaseLog "error" $ "StartProcessNodeNew sent for node with no host: " ++ show node
          return $ Right (NewMeroServerFailure node, [finish])
        else Right . (NewMeroServerFailure node,) <$> route node

  directly config_created $ do
    Just fs <- getFilesystem
    Just host <- getField . rget fldHost <$> get Local
    Just hhi <- getField . rget fldHostHardwareInfo <$> get Local
    createMeroClientConfig fs host hhi
    continue confd_running

  setPhaseIf wait_data_load initialDataLoaded $ \() -> do
    StartProcessNodeNew node <- getRequest
    route node >>= switch

  setPhaseIf confd_running (barrierPass $ \mcs -> M0._mcs_runlevel mcs >= M0.BootLevel 1) $ \() -> do
    syncStat <- synchronize False
    case syncStat of
      Left err -> do phaseLog "error" $ "Unable to sync new client to confd: " ++ show err
                     continue finish
      Right () -> continue synchronized

  -- If mero service is already running we may have just recovered
  -- from a disconnect. Request new channels instead of trying to use
  -- old ones.
  directly reconnect_m0d $ do
    StartProcessNodeNew node <- getRequest
    rg <- getLocalGraph
    let R.Node nid = node
    case lookupServiceInfo node (lookupM0d rg) rg of
      [] -> do
        phaseLog "info" "No halon:m0d already running."
        continue announce
      -- TODO: make the process transient? We're dropping old link.
      --
      -- TODO: Think about whether we still need it.
      _ -> do
        -- There's a service in RG but it may not be marked by halon
        -- is PSOnline: if we're recovering from a disconnect but
        -- halond didn't die then the service thinks its fine. Use the
        -- interface directly, skipping the PSOnline check; this way
        -- we can tell the already-running service to reconnect.
        case M0.nodeToM0Node node rg >>= \m0n -> Process.getHA m0n rg of
          Nothing -> do
            phaseLog "error" $ "Can't find halon:m0d for " ++ show node
            continue finish
          Just ha -> do
            sendSvc (getInterface $ lookupM0d rg) nid ServiceReconnectRequest
            t <- _hv_mero_kernel_start_timeout <$> getHalonVars
            waitClear
            setExpectedNotifications [stateSet ha processHAOnline]
            waitFor notifier
            onSuccess announce
            onTimeout t finish
            continue dispatch

  directly announce $ do
    StartProcessNodeNew node <- getRequest
    -- TOOD: shuffle retrigger around a bit
    rg <- getLocalGraph
    case M0.nodeToM0Node node rg of
      Nothing -> phaseLog "info" $ "No m0node associated, not retriggering mero"
      Just m0node -> retriggerMeroNodeBootstrap m0node

    modify Local $ rlens fldRep .~ (Field . Just $ NewMeroServer node)
    continue finish

  return check
  where
    initialDataLoaded :: Event.InitialDataLoaded -> g -> l -> Process (Maybe ())
    initialDataLoaded Event.InitialDataLoaded _ _ = return $ Just ()
    initialDataLoaded Event.InitialDataLoadFailed{} _ _ = return Nothing

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
       <+> fldConfSyncState =: defaultConfSyncState
       <+> fldNotifications =: []
       <+> fldDispatch =: Dispatch [] (error "ruleNodeNew dispatch") Nothing

-- | Rule fragment: query node hardware information.
mkQueryHostInfo :: forall l. (FldHostHardwareInfo ∈ l, FldHost ∈ l, FldNode ∈ l)
              => Jump PhaseHandle -- ^ Phase handle to jump to on completion
              -> Jump PhaseHandle -- ^ Phase handle to jump to on failure.
              -> RuleM RC (FieldRec l) (Jump PhaseHandle) -- ^ Handle to start on
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
          registerSyncGraphProcessMsg eid
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
    systemInfoOnNode (HAEvent eid (SystemInfo node' info)) _ l = let
        Just node = getField . rget fldNode $ l
      in
        return $ if node == node' then Just (eid, info) else Nothing



-- | Process that will bootstrap mero node.
-- @
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
--  @
processStartProcessesOnNode :: Job StartProcessesOnNodeRequest StartProcessesOnNodeResult
processStartProcessesOnNode = Job "castor::node::process::start"

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
-- This job always returns: it's not necessary for the caller to have
-- a timeout.
ruleStartProcessesOnNode :: Definitions RC ()
ruleStartProcessesOnNode = mkJobRule processStartProcessesOnNode args $ \(JobHandle getRequest finish) -> do
    kernel_failed     <- phaseHandle "kernel_failed"
    boot_level_0      <- phaseHandle "boot_level_0"
    boot_level_1      <- phaseHandle "boot_level_1"
    kernel_timeout    <- phaseHandle "kernel_timeout"
    dispatch          <- mkDispatcher
    notifier          <- mkNotifierSimpleAct dispatch waitClear

    let route (StartProcessesOnNodeRequest m0node) = do
          let def = NodeProcessesStartTimeout m0node []
          r <- runMaybeT $ do
            node <- MaybeT $ M0.m0nodeToNode m0node <$> getLocalGraph
            MaybeT $ do
              rg <- getLocalGraph
              host <- findNodeHost node  -- XXX: head
              modify Local $ rlens fldHost . rfield .~ host
              modify Local $ rlens fldNode . rfield .~ Just node
              if isJust $ getRunningMeroInterface m0node rg
              then return $ Just [boot_level_0]
              else do
                lookupInfoMsg node (lookupM0d rg) >>= \case
                  Nothing -> do
                    phaseLog "info" $ "Requesting halon:m0d start on " ++ show m0node
                    promulgateRC $ StartHalonM0dRequest m0node
                  Just _ -> return ()
                case Process.getHA m0node rg of
                  Nothing -> do
                    phaseLog "error" $ "No HA process on " ++ show m0node
                    return Nothing
                  Just ha -> do
                    phaseLog "info" $ "Waiting for halon:m0d to come up on " ++ show m0node
                    t <- _hv_mero_kernel_start_timeout <$> getHalonVars
                    waitClear
                    setExpectedNotifications [stateSet ha processHAOnline]
                    waitFor notifier
                    waitFor kernel_failed
                    onSuccess boot_level_0
                    onTimeout t kernel_timeout
                    return $ Just [dispatch]
          case r of
            -- Always explicitly fail this job so callers don't have to
            -- set and wait for a timeout on their end.
            Nothing -> do
              phaseLog "warn" $ "Node not ready for start."
              st <- nodeFailedWith NodeProcessesStartFailure m0node
              return $ Right (st, [finish])
            Just phs -> return $ Right (def, phs)

    -- Wait for notifications for processes on the current boot level.
    -- 'ruleProcessStart' always returns which allows us to fail as
    -- fast or succeed as soon as all the processes report back: we do
    -- not have to wait for timeout to tick off if some process
    -- happens to fail to start.
    let mkProcessesAwait name next = mkLoop name (return [])
          (\result l ->
            case result of
              ProcessStarted p -> return . Right
                $ (rlens fldWaitingProcs %~ fieldMap (filter (/= p))) l
              ProcessConfiguredOnly p -> return . Right
                $ (rlens fldWaitingProcs %~ fieldMap (filter (/= p))) l
              ProcessStartFailed p _ -> do
                --  Alternatively, instead of checking for the
                --  process, we could check if it's our job that
                --  we're receiving information about.
                if p `elem` getField (rget fldWaitingProcs l)
                then do
                  StartProcessesOnNodeRequest m0node <- getRequest
                  _ <- nodeFailedWith NodeProcessesStartFailure m0node
                  return $ Left finish
                else return $ Right l
              ProcessStartInvalid p _ -> do
                if p `elem` getField (rget fldWaitingProcs l)
                then do
                  StartProcessesOnNodeRequest m0node <- getRequest
                  _ <- nodeFailedWith NodeProcessesStartFailure m0node
                  return $ Left finish
                else return $ Right l
          )
          (getField . rget fldWaitingProcs <$> get Local >>= return . \case
             [] -> Just [next]
             _  -> Nothing)

    directly kernel_timeout $ do
      StartProcessesOnNodeRequest m0node <- getRequest
      waitClear
      void $ nodeFailedWith NodeProcessesStartTimeout m0node
      continue finish

    setPhaseIf kernel_failed (\ksf _ l ->
       case (ksf, getField $ rget fldReq l) of
         (  (KernelStartFailure node)
            , Just (StartProcessesOnNodeRequest m0node))
            | node == m0node -> return $ Just m0node
         _  -> return Nothing
       ) $ \ m0node -> do
      waitClear
      void $ nodeFailedWith NodeProcessesStartFailure m0node
      continue finish

    boot_level_0_result <- mkProcessesAwait "boot_level_0_result" boot_level_1

    directly boot_level_0 $ do
      Just host <- getField . rget fldHost <$> get Local
      startProcesses host (== M0.PLM0d (M0.BootLevel 0)) >>= \case
        [] -> do
          notifyOnClusterTransition
          continue boot_level_1
        ps -> do
          modify Local $ rlens fldWaitingProcs . rfield .~ ps
          continue boot_level_0_result

    boot_level_1_result <- mkProcessesAwait "boot_level_1_result" finish

    setPhaseIf boot_level_1 (barrierPass $ \mcs -> M0._mcs_runlevel mcs >= M0.BootLevel 1) $ \() -> do
      Just host <- getField . rget fldHost <$> get Local
      StartProcessesOnNodeRequest m0node <- getRequest
      modify Local $ rlens fldRep .~ Field (Just $ NodeProcessesStarted m0node)
      startProcesses host (== M0.PLM0d (M0.BootLevel 1)) >>= \case
        [] -> do
          notifyOnClusterTransition
          continue finish
        ps -> do
          modify Local $ rlens fldWaitingProcs . rfield .~ ps
          continue boot_level_1_result

    return route
  where
    fldReq = Proxy :: Proxy '("request", Maybe StartProcessesOnNodeRequest)
    fldRep = Proxy :: Proxy '("reply", Maybe StartProcessesOnNodeResult)
    fldWaitingProcs = Proxy :: Proxy '("waiting-procs", [M0.Process])
    args = fldUUID =: Nothing
       <+> fldReq  =: Nothing
       <+> fldNode =: Nothing
       <+> fldRep  =: Nothing
       <+> fldHost =: Nothing
       <+> fldNotifications =: []
       <+> fldWaitingProcs =: []
       <+> fldDispatch =: Dispatch [] (error "ruleStartProcessOnNode dispatcher") Nothing

    nodeFailedWith state m0node = do
      rg <- getLocalGraph
      let ps = getUnstartedProcesses m0node rg
      modify Local $ rlens fldRep .~ (Field . Just $ state m0node ps)
      return $ state m0node ps

processStartClientsOnNode :: Job StartClientsOnNodeRequest StartClientsOnNodeResult
processStartClientsOnNode = Job "castor::node::client::start"

-- | Start all clients on the given node.
ruleStartClientsOnNode :: Definitions RC ()
ruleStartClientsOnNode = mkJobRule processStartClientsOnNode args $ \(JobHandle _ finish) -> do
    kernel_failed <- phaseHandle "kernel_failed"
    m0d_up_timeout <- phaseHandle "m0d_up_timeout"
    start_clients <- phaseHandle "start_clients"
    dispatch <- mkDispatcher
    notifier <- mkNotifierSimpleAct dispatch waitClear

    let mkProcessesAwait name next = mkLoop name (return [])
          (\result l ->
             case result of
               ProcessStarted p -> return . Right
                $ (rlens fldWaitingProcs %~ fieldMap (filter (/= p))) l
               ProcessConfiguredOnly p -> return . Right
                $ (rlens fldWaitingProcs %~ fieldMap (filter (/= p))) l
               ProcessStartFailed p r -> do
                 Just (StartClientsOnNodeRequest m0node) <- getField . rget fldReq <$> get Local
                 modify Local $ rlens fldRep . rfield .~
                   Just (ClientsStartFailure m0node $ printf "%s failed to start: %s" (M0.showFid p) r)
                 return $ Left finish
               ProcessStartInvalid p r -> do
                 Just (StartClientsOnNodeRequest m0node) <- getField . rget fldReq <$> get Local
                 modify Local $ rlens fldRep . rfield .~
                   Just (ClientsStartFailure m0node $ printf "%s failed to start: %s" (M0.showFid p) r)
                 return $ Left finish
          )
          (getField . rget fldWaitingProcs <$> get Local >>= \case
             [] -> do
               Just (StartClientsOnNodeRequest m0node) <- getField . rget fldReq <$> get Local
               modify Local $ rlens fldRep . rfield .~ Just (ClientsStartOk m0node)
               return $ Just [next]
             _  -> return Nothing)

    let route (StartClientsOnNodeRequest m0node) = do
          phaseLog "debug" $ "request start client for " ++ show m0node
          rg <- getLocalGraph
          let mnode = M0.m0nodeToNode m0node rg
          mhost <- join <$> traverse findNodeHost mnode
          case liftA2 (,) mnode mhost of
            Nothing -> do return . Left $ "Could not find host or node associated with " ++ show m0node
            Just (node,host) -> do
              modify Local $ rlens fldM0Node .~ Field (Just m0node)
              modify Local $ rlens fldNode .~ Field (Just node)
              modify Local $ rlens fldHost .~ Field (Just host)
              case getClusterStatus rg of
                Nothing -> do
                  return $ Left "Cluster disposition not set, can't start clients."
                Just (M0.MeroClusterState M0.OFFLINE _ _ ) -> do
                  return $ Left $ "Request to start clients but "
                             ++ "cluster disposition is OFFLINE."
                Just (M0.MeroClusterState M0.ONLINE _ _)
                  | isJust $ getRunningMeroInterface m0node rg -> do
                      phaseLog "info" "halon:m0d running, starting clients"
                      return $ Right (ClientsStartFailure m0node "default failure"
                                     , [start_clients])
                  | otherwise -> do
                      phaseLog "info" $ "Waiting for halon:m0d to come up on " ++ show m0node
                      t <- _hv_mero_kernel_start_timeout <$> getHalonVars
                      waitClear
                      waitFor notifier
                      waitFor kernel_failed
                      onTimeout t m0d_up_timeout
                      onSuccess start_clients
                      return $ Right (ClientsStartFailure m0node "default failure"
                                     , [dispatch])

        -- Filter for client processes
        clientProcess M0.PLM0t1fs = True
        clientProcess (M0.PLClovis _ _) = True
        clientProcess _ = False

    setPhaseIf kernel_failed (\(KernelStartFailure node) _ l ->  -- XXX: HA event?
       return $! case getField $ rget fldReq l of
         Just (StartClientsOnNodeRequest m0node)
           | node == m0node -> Just ()
         _ -> Nothing
      ) $ \() -> do
            Just m0node <- getField . rget fldM0Node <$> get Local
            waitClear
            modify Local $ rlens fldRep . rfield .~
              (Just $ ClientsStartFailure m0node "Kernel failed to start")
            continue finish

    directly m0d_up_timeout $ do
      Just m0node <- getField . rget fldM0Node <$> get Local
      modify Local $ rlens fldRep . rfield .~
        (Just $ ClientsStartFailure m0node "Waited too long for kernel")
      continue finish

    start_clients_results <- mkProcessesAwait "start_clients_results" finish

    directly start_clients $ do
      Just m0node <- getField . rget fldM0Node <$> get Local
      Just host <- getField . rget fldHost <$> get Local
      phaseLog "info" $ "Starting mero client on " ++ show host
      startProcesses host clientProcess >>= \case
        [] -> do
          phaseLog "warn" "No client processes found on the host"
          modify Local $ rlens fldRep . rfield .~
            (Just $ ClientsStartOk m0node)
          continue finish
        ps -> do
          modify Local $ rlens fldWaitingProcs . rfield .~ ps
          continue start_clients_results

    return route
  where
    fldReq = Proxy :: Proxy '("request", Maybe StartClientsOnNodeRequest)
    fldRep = Proxy :: Proxy '("reply", Maybe StartClientsOnNodeResult)
    fldM0Node = Proxy :: Proxy '("reply", Maybe M0.Node)
    fldWaitingProcs = Proxy :: Proxy '("waiting-procs", [M0.Process])
    args  = fldUUID =: Nothing
        <+> fldReq     =: Nothing
        <+> fldRep     =: Nothing
        <+> fldNode    =: Nothing
        <+> fldM0Node  =: Nothing
        <+> fldHost    =: Nothing
        <+> fldNotifications =: []
        <+> fldWaitingProcs =: []
        <+> fldDispatch =: Dispatch [] (error "ruleStartClientsOnNode dispatcher") Nothing

processStopProcessesOnNode :: Job StopProcessesOnNodeRequest StopProcessesOnNodeResult
processStopProcessesOnNode = Job "castor::node::stop-processes"

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
-- processes managed to stop. If the processes fail to stop (due to
-- timeout or otherwise), mark the node as failed to teardown.
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
-- description of how this barrier functions. 'notifyOnClusterTransition' is
-- called by the node when it's done with its chunk.
--
-- * 'notifyOnClusterTransition' grabs the current global cluster state.
--
-- * If there are still processes waiting to stop, do nothing: we
-- still have nodes that need to report back their results or
-- otherwise fail.
--
-- * If there are no more processes on this boot level and cluster is
-- on boot level 0 (last), simply mark the cluster as stopped.
--
-- * If there are no more processes on this level and it's not the last level:
--
--     1. Set global cluster state to the next level
--     2. Send out a 'BarrierPass' message: this serves as a barrier
--        release, blocked nodes wait for this message and when they
--        see it, they know cluster progressed onto the given level
--        and they can start teardown of that level.
ruleStopProcessesOnNode :: Definitions RC ()
ruleStopProcessesOnNode = mkJobRule processStopProcessesOnNode args $ \(JobHandle getRequest finish) -> do
   teardown   <- phaseHandle "teardown"
   teardown_exec <- phaseHandle "teardown-exec"
   await_barrier <- phaseHandle "await-barrier"
   barrier_timeout <- phaseHandle "barrier-timeout"
   stop_service <- phaseHandle "stop-service"
   halon_m0d_stop_result <- phaseHandle "halon_m0d_stop_result"
   lower_boot_level <- phaseHandle "next-boot-level"

   -- Continue process on the next boot level. This method include only
   -- numerical bootlevels.
   directly lower_boot_level $ do
     modify Local $ rlens fldBootLevel %~ fieldMap (\(M0.BootLevel i) -> M0.BootLevel (i - 1))
     continue teardown

   let mkProcessesAwait name next = mkLoop name (return [])
         (\result l -> case result of
             StopProcessResult (p, _) -> return .  Right $
               (rlens fldWaitingProcs %~ fieldMap (filter (/= p))) l
             StopProcessTimeout p -> do
               if p `elem` getField (rget fldWaitingProcs l)
               then do
                 StopProcessesOnNodeRequest node <- getRequest
                 modify Local $ rlens fldRep . rfield .~ Just (StopProcessesOnNodeTimeout node)
                 return $ Left finish
               else return $ Right l)
         (getField . rget fldWaitingProcs <$> get Local >>= return . \case
             [] -> Just [next]
             _ -> Nothing)

   directly teardown $ do
     StopProcessesOnNodeRequest node <- getRequest
     lvl@(M0.BootLevel i) <- getField . rget fldBootLevel <$> get Local
     phaseLog "info" $ "Tearing down " ++ show lvl ++ " on " ++ show node
     cluster_lvl <- getClusterStatus <$> getLocalGraph
     barrierTimeout <- _hv_node_stop_barrier_timeout <$> getHalonVars
     case cluster_lvl of
       Just (M0.MeroClusterState M0.OFFLINE _ s)
          | i < 0 && s <= M0.BootLevel (-1) -> continue stop_service
          | i < 0 -> switch [await_barrier, timeout barrierTimeout barrier_timeout]
          | s < lvl -> do
              phaseLog "debug" $ printf "%s is on %s while cluster is on %s - skipping"
                                        (show node) (show lvl) (show s)
              continue lower_boot_level
          | s == lvl  -> continue teardown_exec
          | otherwise -> do
              phaseLog "debug" $ printf "%s is on %s while cluster is on %s - waiting for barriers."
                                        (show node) (show lvl) (show s)
              notifyOnClusterTransition
              switch [ await_barrier, timeout barrierTimeout barrier_timeout ]
       Just st -> do
         modify Local $ rlens fldRep . rfield .~ Just (StopProcessesOnNodeStateChanged node st)
         continue finish
       Nothing -> continue finish -- should not happen?

   await_stopping_processes <- mkProcessesAwait "await_stopping_processes" lower_boot_level

   directly teardown_exec $ do
     Just (StopProcessesOnNodeRequest node) <- getField . rget fldReq <$> get Local
     lvl  <- getField . rget fldBootLevel <$> get Local
     rg <- getLocalGraph

     let pLabel = if lvl == m0t1fsBootLevel
                  then (\case M0.PLM0t1fs -> True
                              M0.PLClovis _ False -> True
                              _ -> False )
                  else (== (M0.PLM0d lvl))

         stillUnstopped = Node.getLabeledProcessesP node pLabel rg & filter
          (\p ->
            M0.getState p rg `elem` [ M0.PSOnline, M0.PSQuiescing
                                    , M0.PSStopping, M0.PSStarting ]
          )
     case stillUnstopped of
       [] -> do phaseLog "info" $ printf "%s R.Has no services on level %s - skipping to the next level"
                                          (show node) (show lvl)
                continue lower_boot_level
       ps -> do
          phaseLog "info" $ "Stopping " ++ show (M0.fid <$> ps) ++ " on " ++ show node
          for_ ps $ promulgateRC . StopProcessRequest
          modify Local $ rlens fldWaitingProcs . rfield .~ ps
          continue await_stopping_processes

   setPhaseIf await_barrier (\(ClusterStateChange _ mcs) _ minfo ->
     let lvl = getField . rget fldBootLevel $ minfo
     in runMaybeT $ guard (M0._mcs_stoplevel mcs <= lvl)) $ \() ->
       continue teardown

   directly barrier_timeout $ do
     lvl <- getField . rget fldBootLevel <$> get Local
     StopProcessesOnNodeRequest node <- getRequest
     let msg = "Timed out waiting for cluster barrier to reach " ++ show lvl
     modify Local $ rlens fldRep . rfield .~ Just (StopProcessesOnNodeFailed node msg)
     continue finish

   directly stop_service $ do
     StopProcessesOnNodeRequest node <- getRequest
     phaseLog "info" $ printf "%s stopped all mero services - stopping halon mero service."
                              (show node)
     l <- startJob $ StopHalonM0dRequest node
     modify Local $ rlens fldJob . rfield .~ Just l
     continue halon_m0d_stop_result

   setPhaseIf halon_m0d_stop_result ourJob $ \r -> do
     StopProcessesOnNodeRequest node <- getRequest
     let setReply v = modify Local $ rlens fldRep . rfield .~ Just v
     case r of
       -- No halon:m0d on node: suspicious but doesn't fail node stop.
       HalonM0dNotFound -> do
         setReply $ StopProcessesOnNodeOk node
       -- The service stop was cancelled, something tried to start
       -- halon:m0d again. Fail node stop.
       HalonM0dStopResult ServiceStopRequestCancelled -> do
         let msg = "halon:m0d service stop request was cancelled"
         setReply $ StopProcessesOnNodeFailed node msg
       -- Everything OK.
       HalonM0dStopResult ServiceStopRequestOk -> do
         setReply $ StopProcessesOnNodeOk node
       -- Took to long to stop halon:m0d, fail node stop with explicit
       -- message.
       HalonM0dStopResult ServiceStopTimedOut -> do
         let msg = "halon:m0d service stop timed out"
         setReply $ StopProcessesOnNodeFailed node msg
     continue finish

   return $ (\(StopProcessesOnNodeRequest node) -> return $ Right (StopProcessesOnNodeTimeout node, [teardown]))
  where
    ourJob (JobFinished lis v) _ ls = case getField $ rget fldJob ls of
      Just l | l `elem` lis -> return $ Just v
      _ -> return Nothing

    fldJob = Proxy :: Proxy '("job", Maybe ListenerId)
    fldReq = Proxy :: Proxy '("request", Maybe StopProcessesOnNodeRequest)
    fldRep = Proxy :: Proxy '("reply", Maybe StopProcessesOnNodeResult)
    fldWaitingProcs = Proxy :: Proxy '("waiting-procs", [M0.Process])
    args = fldUUID =: Nothing
       <+> fldReq  =: Nothing
       <+> fldRep  =: Nothing
       <+> fldJob  =: Nothing
       <+> fldHost =: Nothing
       <+> fldBootLevel =: M0.BootLevel maxTeardownLevel
       <+> fldWaitingProcs =: []

-- | We have failed to (re)start a process with due to the provided
-- reason.
--
-- Currently just fails the node the process is on.
ruleFailNodeIfProcessCantRestart :: Definitions RC ()
ruleFailNodeIfProcessCantRestart =
  defineSimple "castor::node::process-start-failure" $ \case
    ProcessStartFailed p r -> do
      phaseLog "info" $ "Process start failure for " ++ M0.showFid p ++ ": " ++ r
      rg <- getLocalGraph
      let m0ns = maybeToList $ (G.connectedFrom M0.IsParentOf p rg :: Maybe M0.Node)
      applyStateChanges $ map (`stateSet` nodeFailed) m0ns
    _ -> return ()

processMaintenaceStopNode :: Job MaintenanceStopNode MaintenanceStopNodeResult
processMaintenaceStopNode = Job "castor::node::maintenance::stop-processes"

ruleMaintenanceStopNode :: Definitions RC ()
ruleMaintenanceStopNode = mkJobRule processMaintenaceStopNode args $ \(JobHandle getRequest finish) -> do
   go <- phaseHandle "go"
   stop_service <- phaseHandle "stop_service"
   halon_m0d_stop_result <- phaseHandle "halon_m0d_stop_result"

   let mkProcessesAwait name next = mkLoop name (return [])
         (\result l -> case result of
             StopProcessResult (p, _) -> return .  Right $
               (rlens fldWaitingProcs %~ fieldMap (filter (/= p))) l
             StopProcessTimeout p -> do
               if p `elem` getField (rget fldWaitingProcs l)
               then return $ Left finish
               else return $ Right l)
         (getField . rget fldWaitingProcs <$> get Local >>= return . \case
             [] -> Just [next]
             _ -> Nothing)

   await_stopping_processes <- mkProcessesAwait "await_stopping_processes" stop_service

   directly go $ do
      MaintenanceStopNode node <- getRequest
      -- Get all processes except CST_HA.
      rg <- getLocalGraph
      ps <- do
        allProcs <- Node.getProcesses node <$> getLocalGraph
        return [ p | p <- allProcs
                   , let srvs = G.connectedTo p M0.IsParentOf rg
                   , not $ any (\s -> M0.s_type s == CST_HA) srvs
                   , M0.getState p rg == M0.PSOnline ]
      for_ ps $ promulgateRC . StopProcessRequest
      modify Local $ rlens fldWaitingProcs . rfield .~ ps
      continue await_stopping_processes

   directly stop_service $ do
     MaintenanceStopNode node <- getRequest
     phaseLog "info" $ printf "%s stopped all mero services - stopping halon mero service."
                              (show node)
     j <- startJob $ StopHalonM0dRequest node
     modify Local $ rlens fldJob . rfield .~ Just j
     continue halon_m0d_stop_result

   setPhaseIf halon_m0d_stop_result ourJob $ \r -> do
     MaintenanceStopNode node <- getRequest
     let setReply v = modify Local $ rlens fldRep . rfield .~ Just v
     case r of
       HalonM0dNotFound -> do
         setReply $ MaintenanceStopNodeOk node
       HalonM0dStopResult ServiceStopRequestCancelled -> do
         let msg = "halon:m0d service stop request was cancelled"
         setReply $ MaintenanceStopNodeFailed node msg
       HalonM0dStopResult ServiceStopRequestOk -> do
         setReply $ MaintenanceStopNodeOk node
       HalonM0dStopResult ServiceStopTimedOut -> do
         let msg = "halon:m0d service stop timed out"
         setReply $ MaintenanceStopNodeFailed node msg
     continue finish

   return $ \(MaintenanceStopNode node) ->
     return $ Right (MaintenanceStopNodeTimeout node, [go])
  where
    ourJob (JobFinished lis v) _ ls = case getField $ rget fldJob ls of
      Just l | l `elem` lis -> return $ Just v
      _ -> return Nothing

    fldReq = Proxy :: Proxy '("request", Maybe MaintenanceStopNode)
    fldRep = Proxy :: Proxy '("reply", Maybe MaintenanceStopNodeResult)
    fldJob = Proxy :: Proxy '("job", Maybe ListenerId)
    fldWaitingProcs = Proxy :: Proxy '("waiting-procs", [M0.Process])
    args = fldUUID =: Nothing
       <+> fldReq  =: Nothing
       <+> fldRep  =: Nothing
       <+> fldJob  =: Nothing
       <+> fldWaitingProcs =: []

-- | Request to stop a node.
requestUserStopsNode :: Definitions RC ()
requestUserStopsNode = defineSimpleTask "castor::node::stop_user_request" go where
  go (Event.StopNodeUserRequest m0fid should_force reply_to _reason) = lookupConfObjByFid m0fid >>= \case
     Nothing -> liftProcess $ sendChan reply_to (Event.NotANode m0fid)
     Just m0node -> M0.m0nodeToNode m0node <$> getLocalGraph >>= \case
       Nothing -> liftProcess $ sendChan reply_to (Event.NotANode m0fid)
       Just node ->
         if should_force
         then do
           rg <- getLocalGraph
           let (_, DeferredStateChanges f _ _) = createDeferredStateChanges
                     [stateSet m0node (TrI.constTransition M0.NSFailed)] rg -- XXX: constTransition?
           ClusterLiveness havePVers _haveSNS haveQuorum _haveRM <- calculateClusterLiveness (f rg)
           let errors = (if havePVers then id else ("No writable PVers found":))
                      $ (if haveQuorum then id else ("Quorum will be lost":))
                      $ []
           if null errors
           then initiateStop node
           else liftProcess $ sendChan reply_to (Event.CantStop m0fid node errors)
         else initiateStop node
    where
      initiateStop node = do
        promulgateRC (Event.MaintenanceStopNode node)
        liftProcess $ sendChan reply_to (StopInitiated m0fid node)
