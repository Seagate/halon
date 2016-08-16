-- |
-- Copyright : (C) 2013-2016 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Recovery coordinator CEP rules

{-# LANGUAGE CPP                       #-}
{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE TemplateHaskell           #-}

module HA.RecoveryCoordinator.CEP where

import Prelude hiding ((.), id)
import Control.Category
import Control.Lens
import Control.Monad (void)
import Data.Binary (Binary, encode)
import Data.Foldable (for_)
import Data.Maybe (catMaybes, listToMaybe)
import Data.Typeable (Typeable)
import Data.Proxy
import Data.Vinyl
import GHC.Generics

import           Control.Distributed.Process
import           Control.Distributed.Process.Closure (mkClosure)
import           Control.Distributed.Process.Internal.Types (Message(..))
import           Control.Monad (forM_)
import           Data.UUID (nil, null)
import           Network.CEP
import           Network.HostName

import           HA.EventQueue.Types
import           HA.NodeUp
import           HA.RecoveryCoordinator.Mero
import           HA.RecoveryCoordinator.Events.Cluster
import           HA.RecoveryCoordinator.Rules.Castor
import           HA.RecoveryCoordinator.Rules.Service
import qualified HA.RecoveryCoordinator.Rules.Debug as Debug (rules)
import           HA.RecoveryCoordinator.Actions.Job
import           HA.RecoveryCoordinator.Actions.Monitor
import qualified HA.ResourceGraph as G
import           HA.Resources
import           HA.Resources.Castor
import           HA.Resources.HalonVars
import           HA.Service
import           HA.Services.DecisionLog (decisionLog, printLogs)
import           HA.Services.Monitor
import           HA.EQTracker (updateEQNodes__static, updateEQNodes__sdict)
import qualified HA.EQTracker as EQT
import qualified HA.Resources.Castor as M0
#ifdef USE_MERO
import qualified Data.Text as T
import           HA.RecoveryCoordinator.Events.Mero
import           HA.RecoveryCoordinator.Actions.Mero.Conf (nodeToM0Node)
import           HA.RecoveryCoordinator.Rules.Castor.Cluster (clusterRules)
import           HA.RecoveryCoordinator.Rules.Mero (meroRules)
import           HA.RecoveryCoordinator.Rules.Mero.Conf (applyStateChanges)
import qualified HA.RecoveryCoordinator.RC.Rules (rules, initialRule)
import           HA.Resources.Mero (NodeState(..))
import           HA.Services.Mero (meroRules, m0d)
import           HA.Services.SSPL (sendNodeCmd)
import           HA.Services.SSPL.LL.Resources (NodeCmd(..), IPMIOp(..))
#endif
import           HA.Services.SSPL (ssplRules)
import           HA.Services.SSPL.HL.CEP (ssplHLRules)
import           HA.Services.Frontier.CEP (frontierRules)
import           Text.Printf

import           System.Environment
import           System.IO.Unsafe (unsafePerformIO)

enableRCDebug :: Definitions LoopState ()
enableRCDebug = unsafePerformIO $ do
     mt <- lookupEnv "HALON_DEBUG_RC"
     return $ maybe (return ()) (const enableDebugMode) mt

rcInitRule :: IgnitionArguments
           -> RuleM LoopState (Maybe ProcessId) (Started LoopState (Maybe ProcessId))
rcInitRule argv = do
    boot        <- phaseHandle "boot"

    directly boot $ do
      h   <- liftIO getHostName
      nid <- liftProcess getSelfNode
      liftProcess $ do
         sayRC $ "My hostname is " ++ show h ++ " and nid is " ++ show (Node nid)
         sayRC $ "Executing on node: " ++ show nid
#ifdef USE_MERO
      HA.RecoveryCoordinator.RC.Rules.initialRule
#endif
      ms   <- getNodeRegularMonitors (const True)
      liftProcess $ do
        self <- getSelfPid
        EQT.updateEQNodes $ eqNodes argv
        mpid <- spawnLocal $ do
           link self
           monitorProcess Master
        link mpid
        register masterMonitorName mpid
        usend mpid $ StartMonitoringRequest self ms
        _ <- expect :: Process StartMonitoringReply
        sayRC $ "started monitoring nodes"
      syncGraphBlocking
      liftProcess $ sayRC "continue in normal mode"

    start boot Nothing

rcRules :: IgnitionArguments -> [Definitions LoopState ()] -> Definitions LoopState ()
rcRules argv additionalRules = do

    -- XXX: we don't have any callback when buffer is full, so we will just
    -- remove oldest messages out of the buffer, this may not be good, and
    -- ideally we want something that is more clever.
    setBuffer $ fifoBuffer (Bounded 64)

    enableRCDebug

    -- Forward all messages that no rule is interested in back to EQ,
    -- so EQ could delete them.
    setDefaultHandler $ \msg s -> do
      let smsg = case msg of
            EncodedMessage f e -> "{ fingerprint = " ++ show f
              ++ ", encoding " ++ show e ++ " }"
            UnencodedMessage f b -> "{ fingerprint = " ++ show f
              ++ ", encoding " ++ show (encode b) ++ " }"
      liftProcess $ sayRC $ "unhandled message " ++ smsg
      liftProcess $ usend (lsEQPid s) (DoTrimUnknown msg)

    initRule $ rcInitRule argv
    sequence_ [ ruleNodeUp argv
              , ruleRecoverNode argv
              , ruleDummyEvent
              , ruleSyncPing
              , ruleStopRequest
              , rulePidRequest
              , ruleSetHalonVars
              ]
    setLogger sendLogs
    serviceRules argv
    Debug.rules argv
    ssplRules
    castorRules
    frontierRules
    ssplHLRules
#ifdef USE_MERO
    HA.Services.Mero.meroRules
    HA.RecoveryCoordinator.Rules.Mero.meroRules
    HA.RecoveryCoordinator.Rules.Castor.Cluster.clusterRules
    HA.RecoveryCoordinator.RC.Rules.rules
#endif
    sequence_ additionalRules

-- | Listen for 'NodeUp' from connecting satellites. This rule starts
-- the monitor on the node and also decides what to do when the
-- known has already been in the cluster previously.
--
-- TODO: Expand with brief description of the logic decisions it
-- takes.
--
-- TODO: consider porting to jobs: 'isNotHandled' is fragile as it
-- uses ref count for the message which will break when any new rule
-- 'todo's the 'NodeUp' event.
--
-- TODO: replace uses of sayRC (remember to update tests using
-- interceptors)
ruleNodeUp :: IgnitionArguments -> Definitions LoopState ()
ruleNodeUp argv = define "node-up" $ do
      nodeup      <- phaseHandle "nodeup"
      nm_started  <- phaseHandle "node_monitor_started"
      nm_start    <- phaseHandle "node_monitor_start"
      nm_failed   <- phaseHandle "node_monitor_could_not_start"
      mm_reply    <- phaseHandle "master_monitor_reply"
      nm_reply    <- phaseHandle "regular_monitor_reply"
      end         <- phaseHandle "end"

      setPhaseIf nodeup isNotHandled $ \(HAEvent uuid (NodeUp h pid) _) -> do
        todo uuid
        let nid  = processNodeId pid
            node = Node nid
        liftProcess . sayRC $ "New node contacted: " ++ show nid
        publish $ NewNodeMsg node
        hasFailed <- hasHostAttr HA_TRANSIENT (Host h)
        isDown <- hasHostAttr HA_DOWN (Host h)
        known <- case hasFailed of
          False -> do
            phaseLog "info" $ "Potentially new node, no revival: " ++ show node
            knownResource node
          True -> do
            phaseLog "info" $ "Reviving old node: " ++ show node
            notify $ OldNodeRevival node
            unsetHostAttr (Host h) HA_TRANSIENT
            unsetHostAttr (Host h) HA_DOWN
            return True
        conf <- loadNodeMonitorConf node
        if not known
          then do
            let host = Host h
            registerNode node
            registerHost host
            locateNodeOnHost node host
            fork NoBuffer $ do
              put Local (Starting uuid nid conf regularMonitor pid)
              continue nm_start
          else do
            -- Check if we already provision node with a monitor or not.
            msp  <- lookupRunningService (Node nid) regularMonitor
            case msp of
              Nothing -> do
                fork NoBuffer $ do
                  put Local (Starting uuid nid conf regularMonitor pid)
                  continue nm_start
              Just _ | hasFailed || isDown -> do
                phaseLog "info" $
                  "Node has failed but has monitor, removing halon services"
                ack pid
                fork NoBuffer $ do
                  put Local (Starting uuid nid conf regularMonitor pid)
#ifdef USE_MERO
                  findRunningServiceProcesses m0d >>= mapM_ (unregisterServiceProcess (Node nid) m0d)
#endif
                  getNodeRegularMonitors (== Node nid) >>= startNodesMonitoring
                  -- We told MM to watch the old regular monitor, it
                  -- should notice it's dead and restart it, message
                  -- about start should come and node bootstrap should
                  -- proceed and inturn old services should get
                  -- restarted after the newly restarted monitor
                  -- notices those are dead.
                  continue mm_reply
              Just _ | otherwise -> do
                phaseLog "info" $
                  "Node that hasn't failed with monitor, probably bringing up already."
                ack pid
                done uuid

      directly nm_start $ do
        Starting _ nid conf svc _ <- get Local
        _ <- liftProcess $ spawnAsync nid $
          $(mkClosure 'EQT.updateEQNodes) (eqNodes argv)
        registerService svc
        startService nid svc conf
        switch [nm_started, nm_failed]

      setPhaseIf nm_started serviceBootStarted $
          \(HAEvent msgid msg _) -> do
        ServiceStarted n svc cfg sp <- decodeMsg msg
        liftProcess $ sayRC $
          "started " ++ snString (serviceName svc) ++ " service on " ++ show sp
        registerServiceName svc
        registerServiceProcess n svc cfg sp
        startNodesMonitoring [msg]
        messageProcessed msgid
        continue mm_reply  -- XXX: retry on timeout from nm start

      setPhase mm_reply $ \StartMonitoringReply -> do
        Starting _ n _ _ _ <- get Local
        startProcessMonitoring (Node n) =<< getRunningServices (Node n)
        continue nm_reply -- XXX: retry on timeout from nm start

      setPhase nm_reply $ \StartMonitoringReply -> do
        Starting uuid nid _ _ npid <- get Local
        phaseLog "info" $ printf "started monitor service on %s with pid %s"
                                 (show (Node nid)) (show npid)
        ack npid

        phaseLog "debug " $ "Sending NewNodeConnected for " ++ show (Node nid)
        promulgateRC $ NewNodeConnected (Node nid)
        publish $ NewNodeConnected (Node nid)
        done uuid
        continue end

      setPhaseIf nm_failed serviceBootCouldNotStart $
          \(HAEvent msgid msg _) -> do
        ServiceCouldNotStart n svc _ <- decodeMsg msg
        liftProcess $ sayRC $
          "failed " ++ snString (serviceName svc) ++ " service on the node " ++ show n
        messageProcessed msgid
        Starting uuid _ _ _ _ <- get Local
        done uuid
        continue end  -- XXX: retry on timeout from nm start

      directly end stop

      startFork nodeup None

ruleDummyEvent :: Definitions LoopState ()
ruleDummyEvent = defineSimple "dummy-event" $
      \(HAEvent uuid (DummyEvent str) _) -> do
        i <- getNoisyPingCount
        liftProcess $ sayRC $ "received DummyEvent " ++ str
        liftProcess $ sayRC $ "Noisy ping count: " ++ show i
        messageProcessed uuid

ruleSyncPing :: Definitions LoopState ()
ruleSyncPing = defineSimple "sync-ping" $
      \(HAEvent uuid (SyncPing str) _) -> do
        eqPid <- lsEQPid <$> get Global
        registerSyncGraph $ do
          liftProcess $ sayRC $ "received SyncPing " ++ str
          usend eqPid uuid

ruleStopRequest :: Definitions LoopState ()
ruleStopRequest = defineSimpleTask "stop-request" $ \msg -> do
      ServiceStopRequest node svc <- decodeMsg msg
      res                         <- lookupRunningService node svc
      for_ res $ \sp ->
        killService sp Shutdown

newtype RecoverNodeFinished = RecoverNodeFinished Node
  deriving (Eq, Show, Ord, Typeable, Generic)

instance Binary RecoverNodeFinished

recoverJob :: Job RecoverNode RecoverNodeFinished
recoverJob = Job "recover-job"

-- | A rule which tries to contact a node multiple times in specific
-- time intervals, asking it to announce itself back to the TS
-- (NodeUp) so that we may handle it again.
--
-- This rule uses RecoverNode message. This rule is sent service
-- fails on a node: we always have a monitor service running on
-- nodes so if a service fails, we know we potentially have a
-- problem and try to recover, so we send RecoverNode from service
-- failure rule.
ruleRecoverNode :: IgnitionArguments -> Definitions LoopState ()
ruleRecoverNode argv = mkJobRule recoverJob args $ \finish -> do
  try_recover <- phaseHandle "try_recover"
  timeout_host <- phaseHandle "timeout_host"

  let start_recover (RecoverNode n1) = do
        g <- getLocalGraph
        case listToMaybe (G.connectedFrom Runs n1 g) of
          Nothing -> do
            phaseLog "warn" $ "Couldn't find host for " ++ show n1
            continue finish
          Just host@(Host _hst) -> do
            modify Local $ rlens fldNode .~ Field (Just n1)
            modify Local $ rlens fldHost .~ Field (Just host)
            modify Local $ rlens fldRetries .~ Field (Just 0)
            hasHostAttr M0.HA_TRANSIENT host >>= \case
              -- Node not already marked as down so mark it as such and
              -- notify mero
              False -> do
                setHostAttr host M0.HA_TRANSIENT
#ifdef USE_MERO
                case nodeToM0Node n1 g of
                  [] -> phaseLog "warn" $ "Couldn't find any mero nodes for " ++ show n1
                  ns -> applyStateChanges $ (\n -> stateSet n NSFailed) <$> ns
                -- if the node is a mero server then power-cycle it.
                -- Client nodes can run client-software that may not be
                -- OK with reboots so we only reboot servers.
                whenM (hasHostAttr M0.HA_M0SERVER host) $ do
                  ns <- nodesOnHost host
                  forM_ ns $ \(Node nid) ->
                    sendNodeCmd nid Nothing (IPMICmd IPMI_CYCLE (T.pack _hst))
#endif
              -- Node already marked as down, probably the RC died. Do
              -- the simple thing and start the recovery all over: as
              -- long as the RC doesn't die more often than a full node
              -- timeout happens, we'll finish the recovery eventually
              True -> return ()

        phaseLog "info" $ "Marked transient: " ++ show n1
        notify $ NodeTransient n1
        return $ Just [try_recover]

  directly try_recover $ do
    -- If max retries is negative, we keep doing recovery
    -- indefinitely.
    maxRetries <- getHalonVar _hv_recovery_max_retries
    Just node@(Node nid) <- getField . rget fldNode <$> get Local
    Just h <- getField . rget fldHost <$> get Local
    Just i <- getField . rget fldRetries <$> get Local
    if maxRetries > 0 && i >= maxRetries
    then continue timeout_host
    else hasHostAttr M0.HA_TRANSIENT h >>= \case
           False -> do
             phaseLog "info" $ "Recovery complete for " ++ show node
             modify Local $ rlens fldRep .~ (Field . Just $ RecoverNodeFinished node)
             continue finish
           True -> do
             phaseLog "info" $ "Recovery call #" ++ show i ++ " for " ++ show h
             notify $ RecoveryAttempt node i
             modify Local $ rlens fldRetries .~ Field (Just $ i + 1)
             void . liftProcess . callLocal . spawnAsync nid $
               $(mkClosure 'nodeUp) ((eqNodes argv), (100 :: Int))
             expirySeconds <- getHalonVar _hv_recovery_expiry_seconds
             -- Even if maxRetries is negative to indicate
             -- infinite recovery time, we use it to work out a
             -- sensible frequency between retries. If we have
             -- already tried recovery _hv_recovery_max_retries
             -- number of times, keep trying to recovery but now
             -- only every full duration of
             -- _hv_recovery_expiry_seconds..
             let t' = if abs maxRetries > i
                      then expirySeconds
                      else expirySeconds `div` abs maxRetries
             phaseLog "info" $ "Trying recovery again in " ++ show t' ++ " seconds for " ++ show h
             continue $ timeout t' try_recover

  directly timeout_host $ do
    Just node <- getField . rget fldNode <$> get Local
    Just host <- getField . rget fldHost <$> get Local
    timeoutHost host
    modify Local $ rlens fldRep .~ (Field . Just $ RecoverNodeFinished node)
    continue finish

  return start_recover
  where
    fldReq :: Proxy '("request", Maybe RecoverNode)
    fldReq = Proxy
    fldRep :: Proxy '("reply", Maybe RecoverNodeFinished)
    fldRep = Proxy
    fldNode :: Proxy '("node", Maybe Node)
    fldNode = Proxy
    fldHost :: Proxy '("host", Maybe M0.Host)
    fldHost = Proxy
    fldRetries :: Proxy '("retries", Maybe Int)
    fldRetries = Proxy

    args  = fldUUID =: Nothing
        <+> fldReq     =: Nothing
        <+> fldRep     =: Nothing
        <+> fldNode    =: Nothing
        <+> fldHost    =: Nothing
        <+> fldRetries =: Nothing
        <+> RNil

-- | Ask RC for its pid. Send the answer back to given process.
newtype RequestRCPid = RequestRCPid ProcessId
  deriving (Show, Eq, Generic, Typeable)
newtype RequestRCPidAnswer = RequestRCPidAnswer ProcessId
  deriving (Show, Eq, Generic, Typeable)

instance Binary RequestRCPid
instance Binary RequestRCPidAnswer

-- | Asks RC for its own 'ProcessId'.
rulePidRequest :: Specification LoopState ()
rulePidRequest = defineSimpleTask "rule-pid-request" $ \(RequestRCPid caller) -> do
  liftProcess $ getSelfPid >>= usend caller . RequestRCPidAnswer

-- | Send 'Logs' to decision-log services. If no service
--   is found across all nodes, just defaults to 'printLogs'.
sendLogs :: Logs -> LoopState -> Process ()
sendLogs logs ls = do
  case svcs of
    [] -> printLogs logs
    xs -> forM_ xs $ \(ServiceProcess pid) -> usend pid logs
  where
    rg = lsGraph ls
    nodes = [ n | host <- G.connectedTo Cluster Has rg :: [Host]
                , n <- G.connectedTo host Runs rg ]
    svcs = catMaybes $ map (\n -> runningService n decisionLog rg) nodes

-- * Messages which may be interesting to any subscribers (disconnect
-- tests).

newtype OldNodeRevival = OldNodeRevival Node
  deriving (Show, Eq, Typeable, Generic)
data RecoveryAttempt = RecoveryAttempt Node Int
  deriving (Show, Eq, Typeable, Generic)
newtype NodeTransient = NodeTransient Node
  deriving (Show, Eq, Typeable, Generic)
newtype NewNodeMsg = NewNodeMsg Node
  deriving (Show, Eq, Typeable, Generic)

instance Binary OldNodeRevival
instance Binary RecoveryAttempt
instance Binary NodeTransient
instance Binary NewNodeMsg
