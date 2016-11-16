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
  , processStartClientsOnNode
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

import           HA.Encode
import           HA.Service
import           HA.EventQueue.Types
import           HA.RecoveryCoordinator.Actions.Core
import           HA.RecoveryCoordinator.Actions.Hardware
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Actions.Mero.Node
import           HA.RecoveryCoordinator.Actions.Service (lookupInfoMsg)
import           HA.RecoveryCoordinator.Job.Actions
import           HA.RecoveryCoordinator.Events.Castor.Cluster
import           HA.RecoveryCoordinator.Events.Castor.Process
import           HA.RecoveryCoordinator.Events.Mero
import           HA.RecoveryCoordinator.Rules.Mero.Conf
import           HA.Services.Mero
import           HA.Services.Mero.RC.Actions (meroChannel, lookupMeroChannelByNode)
import           HA.Services.SSPL.CEP ( sendInterestingEvent )
import           HA.Services.SSPL.IEM ( logMeroBEError )
import           HA.Services.SSPL.LL.Resources ( InterestingEventMessage(..) )
import qualified HA.RecoveryCoordinator.Events.Cluster as Event
import           HA.RecoveryCoordinator.Events.Service as Service
import           HA.RecoveryCoordinator.Actions.Castor.Cluster

import           Mero.ConfC (ServiceType(CST_HA))
import           Mero.Notification.HAState (BEIoErr, HAMsg(..), HAMsgMeta(..))

import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Castor.Initial as CI
import           HA.Resources.HalonVars
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import qualified HA.ResourceGraph as G

import           Control.Applicative
import           Control.Distributed.Process(Process, spawnLocal, spawnAsync, processNodeId)
import           Control.Distributed.Process.Closure
import           Control.Lens
import           Control.Monad (void, guard, join)
import           Control.Monad.Trans.Maybe

import qualified Data.Aeson as Aeson
import           Data.Binary (Binary)
import           Data.Foldable (for_)
import           Data.Maybe (listToMaybe, isNothing, isJust, maybeToList)
import           Data.Monoid ((<>))
import qualified Data.Text as T
import qualified Data.Text.Lazy.Encoding as TL
import qualified Data.Text.Lazy as TL
import           Data.Typeable
import           Data.Vinyl

import           GHC.Generics

import           Network.CEP

import           System.Posix.SysInfo

import           Text.Printf

-- | All rules related to node.
-- Expected to be used in RecoveryCoordinator code.
rules :: Definitions LoopState ()
rules = sequence_
  [ ruleNodeNew
  , ruleStartProcessesOnNode
  , ruleStartClientsOnNode
  , ruleStopProcessesOnNode
  , ruleFailNodeIfProcessCantRestart
  , requestStartHalonM0d
  , requestStopHalonM0d
  , eventNewHalonNode
  , eventKernelStarted
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
eventNewHalonNode = defineSimple "castor::node::event::new-node" $ \(Event.NewNodeConnected node) -> do
  promulgateRC $! StartProcessNodeNew node

-- | Handle a case when mero-kernel was started on node. Trigger bootstrap
-- process.
--
-- Listens:         'MeroChannelDeclared'
-- Emits:           'KernelStarted'
-- State-Changes:   'M0.Node' online
eventKernelStarted :: Definitions LoopState ()
eventKernelStarted = defineSimpleTask "castor::node::event::kernel-started" $ \(MeroChannelDeclared sp _ _) -> do
  g <- getLocalGraph
  let nodes = nodeToM0Node (R.Node $ processNodeId sp) g
  applyStateChanges $ (`stateSet` M0.NSOnline) <$> nodes
  for_ nodes $ notify . KernelStarted

-- | Handle a case when mero-kernel failed to start on the node. Mark node as failed.
-- Stop halon:m0d service on the node.
--
-- Listens:      'MeroKernelFailed'
-- Emits:        'NodeKernelFailed'
-- State-Changes: 'M0.Node' Failed
eventKernelFailed :: Definitions LoopState ()
eventKernelFailed = defineSimpleTask "castor::node::event::kernel-failed" $ \(MeroKernelFailed pid msg) -> do
  g <- getLocalGraph
  let node = R.Node $ processNodeId pid
      m0nodes = nodeToM0Node node g
      haprocesses =
        [ p
        | m0node <- m0nodes
        , (p :: M0.Process) <- G.connectedTo m0node M0.IsParentOf g
        , any (\s -> M0.s_type s == CST_HA)
           $ G.connectedTo p M0.IsParentOf g
        ]
  let failMsg = "mero-kernel failed to start: " ++ msg
  applyStateChanges $ (`stateSet` M0.PSFailed failMsg) <$> haprocesses
  promulgateRC $ encodeP $ ServiceStopRequest node m0d
  for_ m0nodes $ notify . KernelStartFailure

-- | Handle error being thrown from Mero BE. This typically indicates something
--   like a RAID failure, but there's nothing we can do about it. It indicates
--   an unrecoverable failure; we need to mark the node as failed and send an
--   appropriate IEM.
eventBEError :: Definitions LoopState ()
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
              applyStateChanges [stateSet node M0.NSFailed]
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
requestStartHalonM0d :: Definitions LoopState ()
requestStartHalonM0d = defineSimpleTask "castor::node::request::start-halon-m0d" $
  \(StartHalonM0dRequest m0node) -> do
    rg <- getLocalGraph
    case getClusterStatus rg of
      Just (M0.MeroClusterState M0.OFFLINE _ _) -> do
         phaseLog "info" "Cluster disposition is OFFLINE."
      _ -> case listToMaybe $ m0nodeToNode m0node rg of
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
       Just node -> do let ps = [ stateSet p M0.PSStopping
                                | p <- G.connectedTo m0node M0.IsParentOf rg
                                , any (\s -> M0.s_type s == CST_HA)
                                      $ G.connectedTo (p::M0.Process) M0.IsParentOf rg
                                ]
                       applyStateChanges ps
                       -- XXX: currently stop of the halon:m0d does not stop
                       -- mero-kernel, thus node should no online.
                       -- applyStateChanges [stateSet m0node M0.NSOffline]
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
          phaseLog "error" $ "StartProcessNodeNew sent for node with no host: " ++ show node
          return $ Just [finish]
        else Just <$> route node

  directly config_created $ do
    Just fs <- getFilesystem
    Just host <- getField . rget fldHost <$> get Local
    Just hhi <- getField . rget fldHostHardwareInfo <$> get Local
    createMeroClientConfig fs host hhi
    continue confd_running

  setPhase wait_data_load $ \Event.InitialDataLoaded -> do
    Just (StartProcessNodeNew node) <- getField . rget fldReq <$> get Local
    route node >>= switch

  setPhaseIf confd_running (barrierPass $ \mcs -> M0._mcs_runlevel mcs >= M0.BootLevel 1) $ \() -> do
    syncStat <- syncToConfd
    case syncStat of
      Left err -> do phaseLog "error" $ "Unable to sync new client to confd: " ++ show err
                     continue finish
      Right () -> continue announce

  directly announce $ do
    mreq <- getField . rget fldReq <$> get Local
    for_ mreq $ \(StartProcessNodeNew node) -> do
      -- TOOD: shuffle retrigger around a bit
      rg <- getLocalGraph
      let m0nodes = nodeToM0Node node rg
      applyStateChanges $ flip stateSet M0.NSOnline <$> m0nodes
      case m0nodes of
        [] -> phaseLog "info" $ "No m0node associated, not retriggering mero"
        [m0node] -> retriggerMeroNodeBootstrap m0node
        m0ns -> do
          phaseLog "warn" $
            "Multiple mero nodes associated with halon node, this may be bad: " ++ show m0ns
          mapM_ retriggerMeroNodeBootstrap m0ns

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
ruleStartProcessesOnNode :: Definitions LoopState ()
ruleStartProcessesOnNode = mkJobRule processStartProcessesOnNode args $ \finish -> do
    kernel_up         <- phaseHandle "kernel_up"
    kernel_failed     <- phaseHandle "kernel_failed"
    boot_level_0      <- phaseHandle "boot_level_0"
    boot_level_1      <- phaseHandle "boot_level_1"
    kernel_timeout    <- phaseHandle "kernel_timeout"

    let route (StartProcessesOnNodeRequest m0node) = do
          phaseLog "debug" $ show m0node
          modify Local $ rlens fldRep .~ (Field . Just $ NodeProcessesStarted m0node)
          runMaybeT $ do
            node <- MaybeT $ listToMaybe . m0nodeToNode m0node <$> getLocalGraph -- XXX: list
            MaybeT $ do
              rg <- getLocalGraph
              let chan = meroChannel rg node :: Maybe (TypedChannel ProcessControlMsg)
              host <- findNodeHost node  -- XXX: head
              modify Local $ rlens fldHost . rfield .~ host
              modify Local $ rlens fldNode . rfield .~ Just node
              if isJust chan
              then return $ Just [boot_level_0]
              else do phaseLog "info" $ "starting mero processes on node " ++ show m0node
                      lookupMeroChannelByNode node >>= \case
                        Nothing -> do
                          lookupInfoMsg node m0d >>= \case
                            Nothing -> promulgateRC $ StartHalonM0dRequest m0node
                            Just _ -> phaseLog "info" "halon:m0d info in RG, waiting for it to come up through monitor"
                          -- TODO: kernel may already be up or starting, check
                          t <- _hv_mero_kernel_start_timeout <$> getHalonVars
                          return $ Just [kernel_up, kernel_failed, timeout t kernel_timeout]
                        Just _ -> return $ Just [boot_level_0]

    -- Wait for notifications for processes on the current boot level.
    -- 'ruleProcessStart' always returns which allows us to fail as
    -- fast or succeed as soon as all the processes report back: we do
    -- not have to wait for timeout to tick off if some process
    -- happens to fail to start.
    let mkProcessesAwait name next = mkLoop name (return [])
          (\result l ->
             case result of
               ProcessStarted p -> return $
                 Right $ (rlens fldWaitingProcs %~ fieldMap (filter (/= p))) l
               ProcessStartFailed _ _ -> do
                 Just (StartProcessesOnNodeRequest m0node) <- getField . rget fldReq <$> get Local
                 nodeFailedWith NodeProcessesStartFailure m0node
                 return $ Left finish)
          (getField . rget fldWaitingProcs <$> get Local >>= return . \case
             [] -> Just [next]
             _  -> Nothing)

    directly kernel_timeout $ do
      Just (StartProcessesOnNodeRequest m0node) <- getField . rget fldReq <$> get Local
      nodeFailedWith NodeProcessesStartTimeout m0node
      continue finish

    setPhaseIf kernel_up (\ks _ l ->  -- XXX: HA event?
       case (ks, getField $ rget fldReq l) of
         (  (KernelStarted node)
            , Just (StartProcessesOnNodeRequest m0node))
            | node == m0node -> return $ Just ()
         _ -> return Nothing
      ) $ \() -> continue boot_level_0

    setPhaseIf kernel_failed (\ksf _ l ->
       case (ksf, getField $ rget fldReq l) of
         (  (KernelStartFailure node)
            , Just (StartProcessesOnNodeRequest m0node))
            | node == m0node -> return $ Just m0node
         _  -> return Nothing
       ) $ \ m0node -> do
      nodeFailedWith NodeProcessesStartFailure m0node
      continue finish

    boot_level_0_result <- mkProcessesAwait "boot_level_0_result" boot_level_1

    directly boot_level_0 $ do
      Just host <- getField . rget fldHost <$> get Local
      startNodeProcesses host (M0.PLBootLevel (M0.BootLevel 0)) >>= \case
        [] -> do
          notifyOnClusterTransition Nothing
          continue boot_level_1
        ps -> do
          modify Local $ rlens fldWaitingProcs . rfield .~ ps
          continue boot_level_0_result

    boot_level_1_result <- mkProcessesAwait "boot_level_1_result" finish

    setPhaseIf boot_level_1 (barrierPass $ \mcs -> M0._mcs_runlevel mcs >= M0.BootLevel 1) $ \() -> do
      Just host <- getField . rget fldHost <$> get Local
      startNodeProcesses host (M0.PLBootLevel (M0.BootLevel 1)) >>= \case
        [] -> do
          notifyOnClusterTransition Nothing
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
       <+> fldWaitingProcs =: []

    nodeFailedWith state m0node = do
      rg <- getLocalGraph
      let ps = getUnstartedProcesses m0node rg
      modify Local $ rlens fldRep .~ (Field . Just $ state m0node ps)

processStartClientsOnNode :: Job StartClientsOnNodeRequest StartClientsOnNodeResult
processStartClientsOnNode = Job "castor::node::client::start"

-- | Start all clients on the given node.
ruleStartClientsOnNode :: Definitions LoopState ()
ruleStartClientsOnNode = mkJobRule processStartClientsOnNode args $ \finish -> do
    check_kernel_up <- phaseHandle "check-kernel-up"
    kernel_up <- phaseHandle "kernel-up"
    kernel_up_timeout <- phaseHandle "kernel-up-timeout"
    start_clients <- phaseHandle "start-clients"
    await_barrier <- phaseHandle "await_barrier"

    let mkProcessesAwait name next = mkLoop name (return [])
          (\result l ->
             case result of
               ProcessStarted p -> return $
                 Right $ (rlens fldWaitingProcs %~ fieldMap (filter (/= p))) l
               ProcessStartFailed p r -> do
                 Just (StartClientsOnNodeRequest m0node) <- getField . rget fldReq <$> get Local
                 modify Local $ rlens fldRep . rfield .~
                   Just (ClientsStartFailure m0node $ printf "%s failed to start: %s" (M0.showFid p) r)
                 return $ Left finish)
          (getField . rget fldWaitingProcs <$> get Local >>= \case
             [] -> do
               Just (StartClientsOnNodeRequest m0node) <- getField . rget fldReq <$> get Local
               modify Local $ rlens fldRep . rfield .~ Just (ClientsStartOk m0node)
               return $ Just [next]
             _  -> return Nothing)

    let route (StartClientsOnNodeRequest m0node) = do
          phaseLog "debug" $ "request start client for " ++ show m0node
          rg <- getLocalGraph
          let mnode = listToMaybe $ m0nodeToNode m0node rg
          mhost <- join <$> traverse findNodeHost mnode
          case liftA2 (,) mnode mhost of
            Nothing -> return Nothing
            Just (node,host) -> do
              modify Local $ rlens fldM0Node .~ Field (Just m0node)
              modify Local $ rlens fldNode .~ Field (Just node)
              modify Local $ rlens fldHost .~ Field (Just host)
              let hasM0d = not . null $ lookupServiceInfo node m0d rg
              case getClusterStatus rg of
                Just (M0.MeroClusterState M0.OFFLINE _ _ ) -> do
                  phaseLog "warning" $ "Request to start clients but "
                                     ++ "cluster disposition is OFFLINE."
                  return Nothing
                Just mcs | M0._mcs_runlevel mcs >= m0t1fsBootLevel && hasM0d
                  -> return $ Just [check_kernel_up]
                _ -> return $ Just [await_barrier]

        -- Before starting client stuff, we want need the cluster to be
        -- in OK state and the mero service to be up and running on the
        -- node. In presence of node reboots, the assumption that
        -- ‘MeroClusterRunning -> m0d is started on every node’ no
        -- longer holds so we explicitly check for the service. An
        -- improvement would be to check that every process on the node
        -- is up and running.
        nodeRunning p msg g l = barrierPass p msg g l >>= return . \case
          Nothing -> Nothing
          Just _ -> case getField $ rget fldNode l of
            Nothing -> error "ruleStartClientsOnNode: ‘impossible’ happened"
            Just n -> void $ listToMaybe $ lookupServiceInfo n m0d (lsGraph g)

    setPhaseIf await_barrier
        (nodeRunning (\mcs -> M0._mcs_runlevel mcs >= m0t1fsBootLevel)) $ \() -> do
      Just node <- getField . rget fldNode <$> get Local
      phaseLog "debug" $ "Past barrier on " ++ show node
      continue start_clients

    directly check_kernel_up $ do
      Just node <- getField . rget fldNode <$> get Local
      lookupMeroChannelByNode node >>= \case
        Just _ -> continue start_clients
        -- Monitor should be restarting kernel process, wait for
        -- KernelStarted/KernelFailed message
        Nothing -> do
          t <- _hv_mero_kernel_start_timeout <$> getHalonVars
          switch [kernel_up, timeout t kernel_up_timeout]

    setPhaseIf kernel_up (\ks _ l ->  -- XXX: HA event?
       case (ks, getField $ rget fldReq l) of
         (KernelStarted node, Just (StartClientsOnNodeRequest m0node))
           | node == m0node -> return $ Just ks
         _ -> return Nothing
      ) $ \case
            KernelStarted _ -> continue start_clients
            KernelStartFailure _ -> do
              Just m0node <- getField . rget fldM0Node <$> get Local
              modify Local $ rlens fldRep . rfield .~
                (Just $ ClientsStartFailure m0node "Kernel failed to start")
              continue finish

    directly kernel_up_timeout $ do
      Just m0node <- getField . rget fldM0Node <$> get Local
      modify Local $ rlens fldRep . rfield .~
        (Just $ ClientsStartFailure m0node "Waited too long for kernel")
      continue finish

    start_clients_results <- mkProcessesAwait "start_clients_results" finish

    directly start_clients $ do
      Just m0node <- getField . rget fldM0Node <$> get Local
      Just host <- getField . rget fldHost <$> get Local
      phaseLog "info" $ "Starting mero client on " ++ show host
      startNodeProcesses host M0.PLM0t1fs >>= \case
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
        <+> fldWaitingProcs =: []

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
   barrier_timeout <- phaseHandle "barrier-timeout"
   stop_service <- phaseHandle "stop-service"

   -- Continue process on the next boot level. This method include only
   -- numerical bootlevels.
   let nextBootLevel = do
         Just (M0.BootLevel i) <- getField . rget fldBootLevel <$> get Local
         modify Local $ rlens fldBootLevel .~ (Field $ Just $ M0.BootLevel (i-1)) -- XXX: improve lens
         continue teardown

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
     phaseLog "info" $ "Tearing down " ++ show lvl ++ " on " ++ show node
     cluster_lvl <- getClusterStatus <$> getLocalGraph
     case cluster_lvl of
       Just (M0.MeroClusterState M0.OFFLINE _ s)
          | i < 0 && s <= (M0.BootLevel (-1)) -> continue stop_service
          | i < 0 -> switch [await_barrier, timeout barrierTimeout barrier_timeout]
          | s < lvl -> do
              phaseLog "debug" $ printf "%s is on %s while cluster is on %s - skipping"
                                        (show node) (show lvl) (show s)
              nextBootLevel
          | s == lvl  -> continue teardown_exec
          | otherwise -> do
              phaseLog "debug" $ printf "%s is on %s while cluster is on %s - waiting for barriers."
                                        (show node) (show lvl) (show s)
              notifyOnClusterTransition Nothing
              switch [ await_barrier, timeout barrierTimeout barrier_timeout ]
       Just st -> do
         modify Local $ rlens fldRep .~ (Field . Just $ StopProcessesOnNodeStateChanged st)
         continue finish
       Nothing -> continue finish -- should not happen?

   directly teardown_exec $ do
     Just node <- getField . rget fldNode <$> get Local
     Just lvl  <- getField . rget fldBootLevel <$> get Local
     rg <- getLocalGraph

     let lbl = case lvl of
           x | x == m0t1fsBootLevel -> M0.PLM0t1fs
           x -> M0.PLBootLevel x

     -- Unstopped processes on this node
     let stillUnstopped = getLabeledProcesses lbl
                          ( \proc g -> isJust $ do
                            state <- G.connectedTo proc R.Is g
                            guard (state `elem` [ M0.PSOnline, M0.PSQuiescing
                                                , M0.PSStopping, M0.PSStarting ])
                            m0node <- G.connectedFrom M0.IsParentOf proc g
                            n <- M0.m0nodeToNode m0node g
                            guard $ n == node
                          ) rg

     case stillUnstopped of
       [] -> do phaseLog "info" $ printf "%s R.Has no services on level %s - skipping to the next level"
                                          (show node) (show lvl)
                nextBootLevel
       ps -> do
          Just (StopProcessesOnNodeRequest m0node) <- getField . rget fldReq <$> get Local
          phaseLog "info" $ "Stopping " ++ show (M0.fid <$> ps) ++ " on " ++ show node
          promulgateRC $ StopProcessesRequest m0node ps
          nextBootLevel

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
     applyStateChanges [stateSet m0node M0.NSUnknown]
     modify Local $ rlens fldRep .~ (Field . Just $ StopProcessesOnNodeTimeout)
     -- go back to teardown_exec, let it notice no more processes on
     -- this level and deal with transition into next
     continue teardown_exec

   setPhaseIf await_barrier (\(ClusterStateChange _ mcs) _ minfo ->
     runMaybeT $ do
       lvl <- MaybeT $ return $ getField . rget fldBootLevel $ minfo
       guard (M0._mcs_stoplevel mcs <= lvl)
       return ()
     ) $ \() -> continue teardown

   directly barrier_timeout $ do
     Just lvl <- getField . rget fldBootLevel <$> get Local
     phaseLog "warning" $ "Timed out waiting for cluster barrier to reach " ++ show lvl
     modify Local $ rlens fldRep .~ (Field . Just $ StopProcessesOnNodeTimeout)
     continue finish

   directly stop_service $ do
     Just node <- getField . rget fldNode <$> get Local
     phaseLog "info" $ printf "%s stopped all mero services - stopping halon mero service."
                              (show node)
     Just (StopProcessesOnNodeRequest m0node) <- getField . rget fldReq <$> get Local
     promulgateRC $ (StopHalonM0dRequest m0node)
     modify Local $ rlens fldRep .~ (Field . Just $ StopProcessesOnNodeOk)
     continue finish
   return route
  where
    barrierTimeout = 3 * 60 -- seconds
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

-- | Given 'M0.BootLevel', generate a corresponding 'M0.ProcessLabel'.
mkLabel :: M0.BootLevel -> M0.ProcessLabel
mkLabel bl@(M0.BootLevel l)
  | l == maxTeardownLevel = M0.PLM0t1fs
  | otherwise = M0.PLBootLevel bl

-- | We have failed to (re)start a process with due to the provided
-- reason.
--
-- Currently just fails the node the process is on.
ruleFailNodeIfProcessCantRestart :: Definitions LoopState ()
ruleFailNodeIfProcessCantRestart =
  defineSimple "castor::node::process-start-failure" $ \case
    ProcessStartFailed p r -> do
      phaseLog "info" $ "Process start failure for " ++ M0.showFid p ++ ": " ++ r
      rg <- getLocalGraph
      let m0ns = maybeToList $ (G.connectedFrom M0.IsParentOf p rg :: Maybe M0.Node)
      applyStateChanges $ map (`stateSet` M0.NSFailed) m0ns
    _ -> return ()
