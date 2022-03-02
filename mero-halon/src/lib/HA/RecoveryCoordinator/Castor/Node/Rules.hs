{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase       #-}
{-# LANGUAGE TemplateHaskell  #-}
{-# LANGUAGE TypeFamilies     #-}
{-# LANGUAGE TypeOperators    #-}
{-# LANGUAGE ViewPatterns     #-}
-- |
-- Copyright : (C) 2016-2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Collection of the rules for maintaining castor node.
--
-- Castor node is a hardware node with running mero-kernel, such node
-- allow to start m0t1fs clients and m0d servers on it.
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
    -- *** Stop processes on node
  , StopProcessesOnNodeRequest(..)
  , StopProcessesOnNodeResult(..)
  , ruleStopProcessesOnNode
    -- * Helpers
  , maxTeardownLevel
  ) where

import           Control.Distributed.Process (Process, spawnLocal, spawnAsync, sendChan)
import           Control.Distributed.Process.Closure
import           Control.Lens
import           Control.Monad (void, guard, when)
import           Control.Monad.Trans.Maybe
import           Data.Foldable (for_)
import           Data.Maybe (catMaybes, isNothing, isJust, maybeToList)
import           Data.Monoid ((<>))
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TL
import           Data.Typeable
import           Data.Vinyl

import qualified HA.Aeson as Aeson
import           HA.Encode
import           HA.EventQueue
import           HA.RecoveryCoordinator.Actions.Hardware
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Castor.Cluster.Actions
import           HA.RecoveryCoordinator.Castor.Cluster.Events
import qualified HA.RecoveryCoordinator.Castor.Drive.Actions as Drive
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
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.RecoveryCoordinator.RC.Events.Cluster as Event
import           HA.RecoveryCoordinator.Service.Actions (lookupInfoMsg)
import           HA.RecoveryCoordinator.Service.Events as Service
import qualified HA.ResourceGraph as G
import           HA.Resources (Has(..))
import qualified HA.Resources as R (Node(..))
import qualified HA.Resources.Castor as Cas (Host)
import qualified HA.Resources.Castor.Initial as CI
import           HA.Resources.HalonVars
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           HA.Service
import           HA.Service.Interface
import           HA.Services.Mero
import           HA.Services.SSPL.IEM (logMeroBEError)
import           HA.Services.SSPL.LL.CEP (sendInterestingEvent)
import           HA.Services.SSPL.LL.Resources ( InterestingEventMessage(..) )
import           Mero.ConfC (ServiceType(CST_CAS,CST_HA))
import           Mero.Lnet
import           Mero.Notification.HAState (BEIoErr, HAMsg(..), HAMsgMeta(..))
import           Network.CEP
import           System.Lnet
import           System.Posix.SysInfo (SysInfo(..))
import           Text.Printf

-- | All rules related to node.
-- Expected to be used in RecoveryCoordinator code.
rules :: Definitions RC ()
rules = sequence_
  [ ruleNodeNew
  , ruleStartProcessesOnNode
  , ruleStopProcessesOnNode
  , ruleFailNodeIfProcessCantRestart
  , ruleMaintenanceStopNode
  , ruleDiRebStart
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

type FldLnetInfo = '("mLnetInfo", Maybe LnetInfo)
fldLnetInfo :: Proxy FldLnetInfo
fldLnetInfo = Proxy

type FldHost = '("host", Maybe Cas.Host)
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
eventNewHalonNode = defineSimple "castor::node::event::new-node" $
  \(Event.NewNodeConnected node info) -> do
    promulgateRC $! StartProcessNodeNew node info

-- | Handle a case when mero-kernel failed to start on the node. Mark node as failed.
-- Stop halon:m0d service on the node.
--
-- Listens:      'MeroKernelFailed'
-- State-Changes: 'M0.Node' Failed
eventKernelFailed :: Definitions RC ()
eventKernelFailed = defineSimpleIf "castor::node::event::kernel-failed" g $
  \(uid, nid, msg) -> do
    todo uid
    rg <- getGraph
    let node = R.Node nid
        mm0node = M0.nodeToM0Node node rg
        mhaprocess = mm0node >>= \m0n -> Process.getHA m0n rg
    let failMsg = "mero-kernel failed to start: " ++ msg
    for_ mhaprocess $ \hp -> do
      applyStateChanges [stateSet hp $! processFailed failMsg]
    promulgateRC $ encodeP $ ServiceStopRequest node (lookupM0d rg)
    for_ mm0node $ notify . KernelStartFailure
    done uid
  where
    g (HAEvent uid (MeroKernelFailed nid msg)) _ = return $! Just (uid, nid, msg)
    g _ _ = return Nothing

-- | Handle a case when mero-cleanup failed to start on the node. Currently we
--   treat this as a kernel failure, as it effectively is.
--
-- Listens:      'MeroCleanupFailed'
-- State-Changes: 'M0.Node' Failed
eventCleanupFailed :: Definitions RC ()
eventCleanupFailed = defineSimpleIf "castor::node::event::cleanup-failed" g $
  \(uid, nid, msg) -> do
    todo uid
    rg <- getGraph
    let node = R.Node nid
        mm0node = M0.nodeToM0Node node rg
        mhaprocess = mm0node >>= \m0n -> Process.getHA m0n rg
    let failMsg = "mero-cleanup failed to start: " ++ msg
    for_ mhaprocess $ \hp -> do
      applyStateChanges [stateSet hp $! processFailed failMsg]
    promulgateRC $ encodeP $ ServiceStopRequest node (lookupM0d rg)
    for_ mm0node $ notify . KernelStartFailure
    done uid
  where
    g (HAEvent uid (MeroCleanupFailed nid msg)) _ = return $! Just (uid, nid, msg)
    g _ _ = return Nothing

-- | Handle error being thrown from Mero BE. This typically indicates something
--   like a RAID failure, but there's nothing we can do about it. It indicates
--   an unrecoverable failure; we need to mark the node as failed and send an
--   appropriate IEM.
eventBEError :: Definitions RC ()
eventBEError = defineSimpleTask "castor::node::event::be-error"
  $ \(HAMsg (beioerr :: BEIoErr) meta) -> do
    lookupConfObjByFid (_hm_source_process meta) >>= \case
      Nothing -> do
        Log.rcLog' Log.WARN $ "Unknown source process: " ++ show meta
      Just (sendingProcess :: M0.Process) -> do
        mnode <- G.connectedFrom M0.IsParentOf sendingProcess
                <$> getGraph
        case mnode of
          Just (node :: M0.Node) -> do
              -- Log an IEM about this error
              sendInterestingEvent . InterestingEventMessage $ logMeroBEError
                 ( T.pack "{ 'metadata':" <> code meta
                <> T.pack ", 'beError':" <> code beioerr
                <> T.pack "}" )
              void $ applyStateChanges [stateSet node nodeFailed]
            where
              code :: Aeson.ToJSON a => a -> T.Text
              code = TL.toStrict . TL.decodeUtf8 . Aeson.encode
          Nothing -> do
            Log.rcLog' Log.ERROR $ "No node found for source process: " ++ show meta

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
    rg <- getGraph
    case getClusterStatus rg of
      Just (M0.MeroClusterState M0.OFFLINE _ _) -> do
         Log.rcLog' Log.DEBUG "Cluster disposition is OFFLINE."
      _ -> case M0.m0nodeToNode m0node rg of
             Just node@(R.Node nid) ->
               findNodeHost node >>= \case
                 Just host -> do
                   Log.rcLog' Log.DEBUG $ "Starting new mero server."
                   Log.rcLog' Log.DEBUG $ "node.host = " ++ show nid
                   -- Take LNid address. If we don't have it, take the
                   -- address from the CST_HA service as the listen
                   -- address.
                   let meroAddr = [ ep | M0.LNid ep <- G.connectedTo host Has rg ]
                               ++ [ ep | ha_p <- maybeToList $ Process.getHA m0node rg
                                       , svc <- G.connectedTo ha_p M0.IsParentOf rg
                                       , M0.s_type svc == CST_HA
                                       , ep <- map network_id $ M0.s_endpoints svc
                                       ]
                   case meroAddr of
                     [] ->
                       Log.rcLog' Log.ERROR $ "Unable to determine mero address for host " ++ show host
                     addr : _ -> do
                       Log.rcLog' Log.DEBUG $ "node.addr = " ++ show addr
                       createMeroKernelConfig host addr
                       startMeroService host node
                 Nothing -> Log.rcLog' Log.ERROR $ "Can't find Cas.Host for node " ++ show node
             Nothing -> Log.rcLog' Log.ERROR $ "Can't find Cas.Host for node " ++ show m0node

halonM0dStopJob :: Job StopHalonM0dRequest StopHalonM0dResult
halonM0dStopJob = Job "castor::node::request::stop-halon-m0d"

-- | Request to stop halon node.
requestStopHalonM0d :: Definitions RC ()
requestStopHalonM0d = mkJobRule halonM0dStopJob args $ \(JobHandle _ finish) -> do
  service_stop_result <- phaseHandle "service_stop_result"

  let route (StopHalonM0dRequest node) = do
        rg <- getGraph
        let mhp = M0.nodeToM0Node node rg >>= \m0n -> Process.getHA m0n rg
        case mhp of
          Nothing -> do
            return $ Right (HalonM0dNotFound, [finish])
          Just hp -> do
            -- Only apply state change when we're online.
            when (M0.getState hp rg == M0.PSOnline) $ do
              void $ applyStateChanges [stateSet hp processHAStopping]
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
  query_host_info <- mkQueryLnetInfo config_created finish
  (synchronized, synchronize) <- mkSyncToConfd (rlens fldConfSyncState . rfield) announce
  dispatch <- mkDispatcher
  notifier <- mkNotifier dispatch

  let route node = getRoot >>= \case
        Nothing -> return [wait_data_load]
        Just _ -> do
          mhost <- findNodeHost node
          if isJust mhost
          then do Log.rcLog' Log.DEBUG $ show node ++ " is already in configuration."
                  return [reconnect_m0d]
          else return [query_host_info]

  let check (StartProcessNodeNew node _) = do
        mhost <- findNodeHost node
        if isNothing mhost
        then do
          Log.rcLog' Log.ERROR $ "StartProcessNodeNew sent for node with no host: " ++ show node
          return $ Right (NewMeroServerFailure node, [finish])
        else Right . (NewMeroServerFailure node,) <$> route node

  directly config_created $ do
    Just host <- getField . rget fldHost <$> get Local
    Just (LnetInfo _ lnet)  <- getField . rget fldLnetInfo <$> get Local
    StartProcessNodeNew _ info <- getRequest
    createMeroClientConfig host $
      M0.HostHardwareInfo { hhMemorySize = _si_memMiB info
                          , hhCpuCount = _si_cpus info
                          , hhLNidAddress = lnet
                          }
    continue confd_running

  setPhaseIf wait_data_load initialDataLoaded $ \() -> do
    StartProcessNodeNew node _ <- getRequest
    route node >>= switch

  setPhaseIf confd_running (barrierPass $ \mcs -> M0._mcs_runlevel mcs >= M0.BootLevel 1) $ \() -> do
    syncStat <- synchronize False
    case syncStat of
      Left err -> do Log.rcLog' Log.ERROR $ "Unable to sync new client to confd: " ++ show err
                     continue finish
      Right () -> do Log.rcLog' Log.DEBUG "confd-synched"
                     continue synchronized

  -- There are two scenarios: either halon:m0d is in graph or it is
  -- not. If it's not then we do nothing and have RC start the service
  -- in @announce@.
  --
  -- If it is in graph then monitor will be/has restarted it. If it is
  -- in graph, we have two possible scenarios. Either the service is
  -- actually running (there was a network problem but halond didn't
  -- crash) or halond was restarted (service is actually dead). In
  -- latter case everything is OK, monitor will restart service, mero
  -- will send STARTED, process goes online. In former case service is
  -- already online, the monitor doesn't do anything, mero never sends
  -- STARTED. Previously we worked around this by asking the service
  -- to reconnect its interface to mero which would cause this event
  -- to be sent. This is however not good enough because firstly it
  -- should not be necessary in principal and secondly it's cause of
  -- bugs (CASTOR-2443). Instead, ask the service to send this STARTED
  -- event itself. The service will only be able to process this
  -- request after it has bootstrapped, we do not process messages
  -- beforehand. If the service is dead, we lose the message and mero
  -- sends the event. If the service is alive, it processes the
  -- message and sends STARTED. We may get a duplicate event here (one
  -- from mero one from us). This is fine, process started rule will
  -- ignore a duplicate message. The data will be the same as long as
  -- the service announces correct process ID: this is the process ID
  -- of halond on the node. RC does not know it but halon:m0d can ask
  -- the OS for it.
  directly reconnect_m0d $ do
    StartProcessNodeNew node _ <- getRequest
    rg <- getGraph
    let R.Node nid = node
    case lookupServiceInfo node (lookupM0d rg) rg of
      [] -> do
        Log.rcLog' Log.DEBUG "No halon:m0d already running."
        continue announce
      _ -> do
        -- There's a service in RG but it may not be marked by halon
        -- is PSOnline: if we're recovering from a disconnect but
        -- halond didn't die then the service thinks its fine. Use the
        -- interface directly, skipping the PSOnline check; this way
        -- we can tell the already-running service to reconnect.
        case M0.nodeToM0Node node rg >>= \m0n -> Process.getHA m0n rg of
          Nothing -> do
            Log.rcLog' Log.ERROR $ "Can't find halon:m0d for " ++ show node
            continue finish
          Just ha -> do
            -- Send directly as service will not usually be PSOnline
            -- here. If it is then we're going to get stuck anyway
            -- (HALON-678).
            sendSvc (getInterface $ lookupM0d rg) nid AnnounceYourself
            t <- _hv_mero_kernel_start_timeout <$> getHalonVars
            waitClear
            setExpectedNotifications
              [simpleNotificationToPred $ stateSet ha processHAOnline]
            waitFor notifier
            onSuccess announce
            onTimeout t finish
            continue dispatch

  directly announce $ do
    StartProcessNodeNew node _ <- getRequest
    -- TOOD: shuffle retrigger around a bit
    rg <- getGraph
    case M0.nodeToM0Node node rg of
      Nothing -> Log.rcLog' Log.DEBUG $ "No m0node associated, not retriggering mero"
      Just m0node -> retriggerMeroNodeBootstrap m0node

    modify Local $ rlens fldRep .~ (Field . Just $ NewMeroServer node)
    continue finish

  return check
  where
    initialDataLoaded :: Event.InitialDataLoaded -> g -> l -> Process (Maybe ())
    initialDataLoaded Event.InitialDataLoaded _ _ = return $ Just ()
    initialDataLoaded Event.InitialDataLoadFailed{} _ _ = return Nothing

    fldReq = Proxy :: Proxy '("request", Maybe StartProcessNodeNew)
    fldRep = Proxy :: Proxy '("reply", Maybe NewMeroServer)
    fldN  = Proxy :: Proxy '("notifications", [AnyStateChange -> Bool])

    args = fldHost =: Nothing
       <+> fldNode =: Nothing
       <+> fldLnetInfo =: Nothing
       <+> fldUUID =: Nothing
       <+> fldReq  =: Nothing
       <+> fldRep  =: Nothing
       <+> fldConfSyncState =: defaultConfSyncState
       <+> fldN =: []
       <+> fldDispatch =: Dispatch [] (error "ruleNodeNew dispatch") Nothing

-- | Rule fragment: query node hardware information.
mkQueryLnetInfo :: forall l. (FldLnetInfo ∈ l, FldHost ∈ l, FldNode ∈ l)
                => Jump PhaseHandle -- ^ Phase handle to jump to on completion
                -> Jump PhaseHandle -- ^ Phase handle to jump to on failure.
                -> RuleM RC (FieldRec l) (Jump PhaseHandle) -- ^ Handle to start on
mkQueryLnetInfo andThen orFail = do
    query_info <- phaseHandle "queryHostInfo::query_info"
    info_returned <- phaseHandle "queryHostInfo::info_returned"

    directly query_info $ do
      Just node@(R.Node nid) <- getField . rget fldNode <$> get Local
      Log.rcLog' Log.DEBUG $ "Querying system information from " ++ show node
      liftProcess . void . spawnLocal . void
        $ spawnAsync nid $ $(mkClosure 'getLnetInfo) node
      continue info_returned

    setPhaseIf info_returned lnetOnNode $ \(HAEvent eid info) -> do
      Just node <- getField . rget fldNode <$> get Local
      Log.rcLog' Log.DEBUG $ "Received system information about " ++ show node
      mhost <- findNodeHost node
      case mhost of
        Just host -> do
          modify Local $ rlens fldLnetInfo . rfield .~ Just info
          modify Local $ rlens fldHost . rfield .~ Just host
          registerSyncGraphProcessMsg eid
          continue andThen
        Nothing -> do
          Log.rcLog' Log.ERROR $ "Unknown host"
          messageProcessed eid
          continue orFail

    return query_info
  where
    lnetOnNode :: HAEvent LnetInfo
               -> g
               -> FieldRec l
               -> Process (Maybe (HAEvent LnetInfo))
    lnetOnNode msg@(HAEvent _ (LnetInfo node _)) _ l
      | Just node == getField (rget fldNode l) = return $! Just msg
      | otherwise = return Nothing


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
-- principal RM for the cluster if present on the node and not yet set
-- for the cluster. If any processes come back as failed in any boot
-- level, we put the cluster in a failed state.
--
-- * Boot level 1 starts after passing a barrier.
--
-- * Clients start after boot level 1 is finished and cluster enters
-- the 'M0.MeroClusterRunning' state. Currently this means
-- 'CI.PLM0t1fs' processes.
--
-- This job always returns: it's not necessary for the caller to have
-- a timeout.
ruleStartProcessesOnNode :: Definitions RC ()
ruleStartProcessesOnNode = mkJobRule processStartProcessesOnNode args $ \(JobHandle getRequest finish) -> do
    kernel_failed     <- phaseHandle "kernel_failed"
    boot_level_0      <- phaseHandle "boot_level_0"
    boot_level_1      <- phaseHandle "boot_level_1"
    boot_level_2      <- phaseHandle "boot_level_2"
    boot_level_3      <- phaseHandle "boot_level_3"
    kernel_timeout    <- phaseHandle "kernel_timeout"
    dispatch          <- mkDispatcher
    notifier          <- mkNotifierAct dispatch waitClear

    let route (StartProcessesOnNodeRequest m0node) = do
          Log.tagContext Log.SM m0node Nothing
          let def = NodeProcessesStartTimeout m0node []
          r <- runMaybeT $ do
            node <- MaybeT $ M0.m0nodeToNode m0node <$> getGraph
            MaybeT $ do
              Log.tagContext Log.SM node Nothing
              rg <- getGraph
              host <- findNodeHost node  -- XXX: head
              Log.tagContext Log.SM [("host" :: String, show host)] Nothing
              modify Local $ rlens fldHost . rfield .~ host
              modify Local $ rlens fldNode . rfield .~ Just node
              if isJust $ getRunningMeroInterface m0node rg
              then return $ Just [boot_level_0]
              else do
                lookupInfoMsg node (lookupM0d rg) >>= \case
                  Nothing -> do
                    Log.rcLog' Log.DEBUG $ "Requesting halon:m0d start on " ++ show m0node
                    promulgateRC $ StartHalonM0dRequest m0node
                  Just _ -> return ()
                case Process.getHA m0node rg of
                  Nothing -> do
                    Log.rcLog' Log.ERROR $ "No HA process on " ++ show m0node
                    return Nothing
                  Just ha -> do
                    Log.rcLog' Log.DEBUG $ "Waiting for halon:m0d to come up on " ++ show m0node
                    t <- _hv_mero_kernel_start_timeout <$> getHalonVars
                    waitClear
                    setExpectedNotifications
                      [simpleNotificationToPred $ stateSet ha processHAOnline]
                    waitFor notifier
                    waitFor kernel_failed
                    onSuccess boot_level_0
                    onTimeout t kernel_timeout
                    return $ Just [dispatch]
          case r of
            -- Always explicitly fail this job so callers don't have to
            -- set and wait for a timeout on their end.
            Nothing -> do
              Log.rcLog' Log.WARN $ "Node not ready for start."
              st <- nodeFailedWith NodeProcessesStartFailure m0node
              return $ Right (st, [finish])
            Just phs -> return $ Right (def, phs)

    -- Wait for notifications for processes on the current boot level.
    -- 'ruleProcessStart' always returns which allows us to fail as
    -- fast or succeed as soon as all the processes report back: we do
    -- not have to wait for timeout to tick off if some process
    -- happens to fail to start.
    let mkProcessesAwait name next = mkLoop name (return [])
          (\result l -> do
            let exclude p = Right $
                  (rlens fldWaitingProcs %~ fieldMap (filter (/= p))) l
            StartProcessesOnNodeRequest m0node <- getRequest
            case result of
              ProcessStarted p -> do
                Log.rcLog' Log.DEBUG $ "ProcessStarted: " ++ show p
                if p `elem` getField (rget fldWaitingProcs l)
                then do
                  ps@(failed, toStart) <- getProcsStatus m0node p
                  Log.rcLog' Log.DEBUG $ "Procs status (failed, toStart): " ++ show ps
                  -- If some previously started processes got failed,
                  -- the node is probably failed, so finish immediately.
                  -- The node recovery rule might start us again soon.
                  if null toStart || (not . null) failed
                    then return $ Left finish
                    else return $ exclude p
                else return $ Right l
              ProcessConfiguredOnly p -> return $ exclude p
              ProcessStartFailed p _ -> do
                --  Alternatively, instead of checking for the
                --  process, we could check if it's our job that
                --  we're receiving information about.
                if p `elem` getField (rget fldWaitingProcs l)
                then do
                  _ <- nodeFailedWith NodeProcessesStartFailure m0node
                  return $ Left finish
                else return $ Right l
              ProcessStartInvalid p _ -> do
                if p `elem` getField (rget fldWaitingProcs l)
                then do
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
      startProcesses host (== CI.PLM0d 0) >>= \case
        [] -> do
          notifyOnClusterTransition
          continue boot_level_1
        ps -> do
          modify Local $ rlens fldWaitingProcs . rfield .~ ps
          continue boot_level_0_result

    boot_level_1_result <- mkProcessesAwait "boot_level_1_result" boot_level_2

    setPhaseIf boot_level_1
      (barrierPass $ \mcs -> M0._mcs_runlevel mcs >= M0.BootLevel 1) $ \() -> do
        Just host <- getField . rget fldHost <$> get Local
        startProcesses host (== CI.PLM0d 1) >>= \case
          [] -> do
            notifyOnClusterTransition
            continue boot_level_2
          ps -> do
            modify Local $ rlens fldWaitingProcs . rfield .~ ps
            continue boot_level_1_result

    clients_result <- mkProcessesAwait "clients_result" finish

    setPhaseIf boot_level_2
      (barrierPass $ \mcs -> M0._mcs_runlevel mcs >= M0.BootLevel 2) $ \() -> do
        Just host <- getField . rget fldHost <$> get Local
        ps <- startProcesses host m0t1fsProcess
        Log.rcLog' Log.DEBUG $ "Starting these m0tifs processes: "
                            ++ show (M0.showFid <$> ps)
        modify Local $ rlens fldWaitingProcs . rfield .~ ps
        casProcs <- Process.getAllHostingService CST_CAS <$> getGraph
        if null casProcs
        then do
          StartProcessesOnNodeRequest m0node <- getRequest
          modify Local $ rlens fldRep .rfield .~
            (Just $ NodeProcessesStarted m0node)
          continue clients_result
        else continue boot_level_3

    directly boot_level_3 $ do
      (M0.BootLevel n) <- calculateRunLevel
      StartProcessesOnNodeRequest m0node <- getRequest
      if n < 3 then do
        void $ nodeFailedWith NodeProcessesStartFailure m0node
        continue finish
      else do
        Just host <- getField . rget fldHost <$> get Local
        Log.rcLog' Log.DEBUG ("Starting clovis processes." :: String)
        modify Local $ rlens fldRep .~
          Field (Just $ NodeProcessesStarted m0node)
        ps <- startProcesses host clovisProcess
        modify Local $ rlens fldWaitingProcs . rfield %~ (ps ++)
        continue clients_result

    return route
  where
    fldReq = Proxy :: Proxy '("request", Maybe StartProcessesOnNodeRequest)
    fldRep = Proxy :: Proxy '("reply", Maybe StartProcessesOnNodeResult)
    fldWaitingProcs = Proxy :: Proxy '("waiting-procs", [M0.Process])
    fldN  = Proxy :: Proxy '("notifications", [AnyStateChange -> Bool])
    args = fldUUID =: Nothing
       <+> fldReq  =: Nothing
       <+> fldNode =: Nothing
       <+> fldRep  =: Nothing
       <+> fldHost =: Nothing
       <+> fldN =: []
       <+> fldWaitingProcs =: []
       <+> fldDispatch =: Dispatch [] (error "ruleStartProcessOnNode dispatcher") Nothing

    m0t1fsProcess CI.PLM0t1fs = True
    m0t1fsProcess _ = False

    clovisProcess (CI.PLClovis _ CI.Managed) = True
    clovisProcess _ = False

    nodeFailedWith state m0node = do
      rg <- getGraph
      let ps = getUnstartedSrvProcesses m0node rg
      modify Local $ rlens fldRep .~ (Field . Just $ state m0node ps)
      return $ state m0node ps

    getProcsStatus m0node p = do
      rg <- getGraph
      return $ getProcessesStatus m0node p rg

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
     Log.rcLog' Log.DEBUG $ "Tearing down " ++ show lvl ++ " on " ++ show node
     cluster_lvl <- getClusterStatus <$> getGraph
     barrierTimeout <- _hv_node_stop_barrier_timeout <$> getHalonVars
     case cluster_lvl of
       Just (M0.MeroClusterState M0.OFFLINE _ s)
          | i < 0 && s <= M0.BootLevel (-1) -> continue stop_service
          | i < 0 -> switch [await_barrier, timeout barrierTimeout barrier_timeout]
          | s < lvl -> do
              let msg :: String
                  msg = printf "%s is on %s while cluster is on %s - skipping"
                               (show node) (show lvl) (show s)
              Log.rcLog' Log.DEBUG msg
              continue lower_boot_level
          | s == lvl  -> continue teardown_exec
          | otherwise -> do
              let msg :: String
                  msg = printf "%s is on %s while cluster is on %s - waiting for barriers."
                               (show node) (show lvl) (show s)
              Log.rcLog' Log.DEBUG msg
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
     rg <- getGraph

     let procType = if lvl == m0t1fsBootLevel
                    then (\case CI.PLM0t1fs              -> True
                                CI.PLClovis _ CI.Managed -> True
                                _                        -> False)
                    else (== (CI.PLM0d $ M0.unBootLevel lvl))

         stillUnstopped = Node.getTypedProcessesP node procType rg & filter
          (\p -> M0.getState p rg `elem` [ M0.PSOnline
                                         , M0.PSQuiescing
                                         , M0.PSStarting
                                         , M0.PSStopping ]
          )
     case stillUnstopped of
       [] -> do let msg :: String
                    msg = printf "%s has no services on level %s - skipping to the next level"
                                 (show node) (show lvl)
                Log.rcLog' Log.DEBUG msg
                continue lower_boot_level
       ps -> do
          Log.rcLog' Log.DEBUG $ "Stopping " ++ show (M0.fid <$> ps) ++ " on " ++ show node
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
     let msg :: String
         msg = printf "%s stopped all mero services - stopping halon mero service."
                      (show node)
     Log.rcLog' Log.DEBUG msg
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
      Log.rcLog' Log.DEBUG $ "Process start failure for " ++ M0.showFid p ++ ": " ++ r
      rg <- getGraph
      let m0ns = maybeToList $ (G.connectedFrom M0.IsParentOf p rg :: Maybe M0.Node)
      void . applyStateChanges $ map (`stateSet` nodeFailed) m0ns
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
      rg <- getGraph
      ps <- do
        allProcs <- Node.getProcesses node <$> getGraph
        return [ p | p <- allProcs
                   , let srvs = G.connectedTo p M0.IsParentOf rg
                   , not $ any (\s -> M0.s_type s == CST_HA) srvs
                   , M0.getState p rg == M0.PSOnline ]
      for_ ps $ promulgateRC . StopProcessRequest
      modify Local $ rlens fldWaitingProcs . rfield .~ ps
      continue await_stopping_processes

   directly stop_service $ do
     MaintenanceStopNode node <- getRequest
     let msg :: String
         msg = printf "%s stopped all mero services - stopping halon mero service."
                      (show node)
     Log.rcLog' Log.DEBUG msg
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
     Just m0node -> M0.m0nodeToNode m0node <$> getGraph >>= \case
       Nothing -> liftProcess $ sendChan reply_to (Event.NotANode m0fid)
       Just node ->
         if should_force
         then initiateStop node
         else do
           rg <- getGraph
           let (_, DeferredStateChanges f _ _) = createDeferredStateChanges
                     [stateSet m0node (TrI.constTransition M0.NSFailed)] rg -- XXX: constTransition?
           ClusterLiveness havePVers _haveSNS haveQuorum _haveRM <- calculateClusterLiveness (f rg)
           let errors = (if havePVers then id else ("No writable PVers found":))
                      $ (if haveQuorum then id else ("Quorum will be lost":))
                      $ []
           if null errors
           then initiateStop node
           else liftProcess $ sendChan reply_to (Event.CantStop m0fid node errors)
    where
      initiateStop node = do
        promulgateRC (Event.MaintenanceStopNode node)
        liftProcess $ sendChan reply_to (StopInitiated m0fid node)

-- | 'Job' used by 'ruleDiRebStart'
jobNodeDiRebStart :: Job NodeDiRebReq NodeDiRebRes
jobNodeDiRebStart = Job "direct-rebalance-start"

-- Start direct rebalance on a node
ruleDiRebStart :: Definitions RC ()
ruleDiRebStart = mkJobRule jobNodeDiRebStart args $ \(JobHandle _ finish) -> do
  node_disks_notified <- phaseHandle "node_disks_notified"
  notify_failed <- phaseHandle "notify_failed"
  notify_timeout <- phaseHandle "notify_timeout"
  dispatcher <- mkDispatcher
  notifier <- mkNotifierSimpleAct dispatcher waitClear

  let init_rule (NodeDiRebReq node) = getNodeDiRebInformation node >>= \case
        Nothing -> do
          rg <- getGraph
          let sdevs = Node.getAttachedSDevs node rg
          if not (null sdevs)
          then do
              Log.rcLog' Log.DEBUG "starting direct rebalance"
              disks <- catMaybes <$> mapM Drive.lookupSDevDisk sdevs
              let msgs = stateSet node nodeRebalance : map (`stateSet` diskDiReb) disks
              modify Local $ rlens fldNodeDisks . rfield .~ Just (node, disks)
              notifications <- applyStateChanges msgs
              setExpectedNotifications notifications
              waitFor notifier
              waitFor notify_failed
              onSuccess node_disks_notified
              onTimeout 10 notify_timeout
              return $ Right (NodeDiRebReqFailed node "failed to start Direct rebalance", [dispatcher])
          else
              return $ Left "Not starting direct rebalance, have no devices"
        Just _ -> do
          return $ Left "Seems node is already rebalancing"

  (directRebalanceStarted, startDirectRebalanceOperation) <- mkDirectRebalanceStartOperation $ \node er -> do
    case er of
      Left s -> do
        modify Local $ rlens fldRep . rfield .~ Just (NodeDiRebReqFailed node s)
        abortDirectRebalanceStart
        continue finish
      Right _ -> do
        Log.rcLog' Log.DEBUG "NodeDirectRebalanceStartSuccess"
        modify Local $ rlens fldRep . rfield .~ Just (NodeDiRebReqSucccess node)
        continue finish

  directly node_disks_notified $ do
    Just (node, _) <- getField . rget fldNodeDisks <$> get Local
    startDirectRebalanceOperation node
    continue directRebalanceStarted

  setPhase notify_failed $ \(HAEvent uuid (M0.NotifyFailureEndpoints eps)) -> do
    todo uuid
    when (not $ null eps) $ do
      Log.rcLog' Log.WARN $ "Failed to notify " ++ show eps ++ ", not starting rebalance"
      abortDirectRebalanceStart
    done uuid
    continue finish

  directly notify_timeout $ do
    Log.rcLog' Log.WARN $ "Unable to notify Mero; cannot start rebalance"
    abortDirectRebalanceStart
    continue finish

  return init_rule
  where
    abortDirectRebalanceStart = getField . rget fldNodeDisks <$> get Local >>= \case
      Nothing -> Log.rcLog' Log.ERROR "No node info in local state"
      Just (node, _) -> do
        rdevs <- liftGraph Node.getAttachedSDevs node
        rdisks <- catMaybes <$> mapM Drive.lookupSDevDisk rdevs
        _ <- applyStateChanges $ stateSet node nodeOnline : map (`stateSet` diskOnline) rdisks
        unsetNodeDiRebStatus node

    -- XXX Handle additional device failures during direct rebalance.

    fldReq = Proxy :: Proxy '("request", Maybe NodeDiRebReq)
    fldRep = Proxy :: Proxy '("reply", Maybe NodeDiRebRes)
    fldN = Proxy :: Proxy '("pool", Maybe M0.Node)
    fldNodeDisks = Proxy :: Proxy '("node disks", Maybe (M0.Node, [M0.Disk]))

    args = fldUUID          =: Nothing
       <+> fldReq           =: Nothing
       <+> fldRep           =: Nothing
       <+> fldN             =: Nothing
       <+> fldNodeDisks     =: Nothing
       <+> fldNotifications =: []
       <+> fldDispatch      =: Dispatch [] (error "ruleDirectRebalanceStart dispatcher") Nothing
