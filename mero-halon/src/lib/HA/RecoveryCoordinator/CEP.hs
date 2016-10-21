-- |
-- Copyright : (C) 2013-2016 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Recovery coordinator CEP rules

{-# LANGUAGE CPP                       #-}
{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE TypeOperators             #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE GADTs                     #-}

module HA.RecoveryCoordinator.CEP where

import Prelude hiding ((.), id)
import Control.Category
import Control.Lens
import Control.Monad (void, when)
import Data.Binary (Binary)
import Data.Typeable (Typeable)
import Data.Proxy
import Data.Vinyl hiding ((:~:))
import GHC.Generics

import           Control.Distributed.Process
import           Control.Distributed.Process.Closure (mkClosure)
import           Network.CEP
import           Network.HostName

import           HA.EventQueue.Types
import           HA.NodeUp
import           HA.Service
import           HA.Services.Dummy
import           HA.Services.Ping
import qualified HA.EQTracker as EQT
import           HA.RecoveryCoordinator.Mero
import           HA.RecoveryCoordinator.Events.Cluster
import           HA.RecoveryCoordinator.Rules.Castor
import qualified HA.RecoveryCoordinator.Rules.Service
import qualified HA.RecoveryCoordinator.Rules.Debug as Debug (rules)
import           HA.RecoveryCoordinator.Job.Actions
import qualified HA.ResourceGraph as G
import           HA.Resources
import           HA.Resources.Castor
import           HA.Resources.HalonVars
import           HA.Services.DecisionLog (decisionLog, printLogs)
import qualified HA.Resources.Castor as M0
import           HA.RecoveryCoordinator.RC.Actions (addNodeToCluster)
#ifdef USE_MERO
import           Data.Monoid  -- XXX: remote ifdef if possible
import qualified Data.Text as T
import           HA.RecoveryCoordinator.Events.Mero
import           HA.RecoveryCoordinator.Actions.Mero.Conf (nodeToM0Node)
import           HA.RecoveryCoordinator.Rules.Castor.Cluster (clusterRules)
import           HA.RecoveryCoordinator.Rules.Mero.Conf (applyStateChanges)
import qualified HA.RecoveryCoordinator.Rules.Mero (meroRules)
import           HA.Resources.Mero (NodeState(..))
import           HA.Services.Mero.RC (rules)
import           HA.Services.SSPL
  ( sendInterestingEvent
  , sendNodeCmdChan
  )
import           HA.Services.SSPL.IEM (logMeroClientFailed)
import           HA.Services.SSPL.LL.RC.Actions (findActiveSSPLChannel)
import           HA.Services.SSPL.LL.Resources (NodeCmd(..), IPMIOp(..), InterestingEventMessage(..))
#endif
import           Data.Foldable (for_)
import qualified HA.RecoveryCoordinator.RC.Rules (rules, initialRule)
import           HA.Services.SSPL (sspl)
import qualified HA.Services.SSPL.CEP (ssplRules, initialRule)
import           HA.Services.SSPL.HL.CEP (ssplHLRules)
import           HA.Services.Frontier.CEP (frontierRules)

import           System.Environment
import           System.IO.Unsafe (unsafePerformIO)

enableRCDebug :: Definitions LoopState ()
enableRCDebug = unsafePerformIO $ do
     mt <- lookupEnv "HALON_DEBUG_RC"
     return $ maybe (return ()) (const enableDebugMode) mt

rcInitRule :: IgnitionArguments -> RuleM LoopState (Maybe ProcessId) (Started LoopState (Maybe ProcessId))
rcInitRule argv = do
    boot        <- phaseHandle "boot"

    directly boot $ do
      h   <- liftIO getHostName
      nid <- liftProcess getSelfNode
      liftProcess $ do
         sayRC $ "My hostname is " ++ show h ++ " and nid is " ++ show (Node nid)
         sayRC $ "Executing on node: " ++ show nid
         -- TS may not be a node, so it needs to known EQ addresses in other to
         -- call promulgate
         EQT.updateEQNodes (eqNodes argv)
      liftProcess $ sayRC "RC.initialRule"
      HA.RecoveryCoordinator.RC.Rules.initialRule argv
      liftProcess $ sayRC "CEP.initialRule"
      HA.Services.SSPL.CEP.initialRule sspl
      -- guarantee that we could make progress
      liftProcess $ sayRC "sync"
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
    setDefaultHandler $ \uuid st _ s -> do
      liftProcess $ sayRC $ "unhandled message " ++ show uuid ++ ": " ++ show st
      liftProcess $ usend (lsEQPid s) uuid

    initRule $ rcInitRule argv
    sequence_ [ ruleNodeUp argv
              , ruleRecoverNode argv
              , ruleDummyEvent
              , ruleSyncPing
              , rulePidRequest
              ]
    setLogger sendLogs
    HA.RecoveryCoordinator.Rules.Service.rules
    Debug.rules argv
    HA.Services.SSPL.CEP.ssplRules sspl
    castorRules
    frontierRules
    ssplHLRules
    HA.RecoveryCoordinator.RC.Rules.rules
#ifdef USE_MERO
    HA.Services.Mero.RC.rules
    HA.RecoveryCoordinator.Rules.Mero.meroRules
    HA.RecoveryCoordinator.Rules.Castor.Cluster.clusterRules
#endif
    sequence_ additionalRules

-- | Job marker used by 'ruleNodeUp'
nodeUpJob :: Job NodeUp NewNodeConnected
nodeUpJob = Job "node-up"

-- | Listen for 'NodeUp' from connecting satellites. This rule starts
-- removes information about node is be down. And calls 'addNodeToCluster'
-- that configures node and start all required services on that node.
--
-- This rule fires through 'nodeUpJob' and deals with adding the
-- requesting 'Node' to the cluster. Brief description of each rule
-- phase below.
ruleNodeUp :: IgnitionArguments -> Definitions LoopState ()
ruleNodeUp argv = mkJobRule nodeUpJob args $ \finish -> do
  do_register <- phaseHandle "register node"

  let route (NodeUp h pid) = do -- XXX: remove pid here
        let nid  = processNodeId pid
            node = Node nid
            host = Host h
        phaseLog "node.nid" $ show nid
        phaseLog "node.host" $ show h
        hasFailed <- hasHostAttr HA_TRANSIENT (Host h)
        isDown <- hasHostAttr HA_DOWN (Host h)
        isKnown <- knownResource node
        when isKnown $ do
          publish $ OldNodeRevival node
        when (hasFailed || isDown) $ do
          phaseLog "info" $ "Reviving old node."
          phaseLog "info" $ "node = " ++ show node
          unsetHostAttr host HA_TRANSIENT
          unsetHostAttr host HA_DOWN
        registerNode node
        registerHost host
        locateNodeOnHost node host
        return (Just [do_register])

  directly do_register $ do
    Just (NodeUp _ pid) <- getField . rget fldReq <$> get Local
    let nid  = processNodeId pid
        node = Node nid
    publish $ NewNodeMsg node
    phaseLog "node.nid" $ show nid
    liftProcess $ usend pid ()
    modify Local $ rlens fldRep .~ (Field . Just $ NewNodeConnected node)
    addNodeToCluster (eqNodes argv) node
    continue finish

  return route
  where
    fldReq :: Proxy '("request", Maybe NodeUp)
    fldReq = Proxy
    fldRep :: Proxy '("reply", Maybe NewNodeConnected)
    fldRep = Proxy

    args = fldUUID =: Nothing
       <+> fldReq     =: Nothing
       <+> fldRep     =: Nothing
       <+> RNil

-- | TODO: Port tests to subscription and remove use of 'sayRC'
ruleDummyEvent :: Definitions LoopState () -- XXX: move to rules file
ruleDummyEvent = defineSimpleTask "dummy-event" $ \(DummyEvent str) -> do
  i <- getNoisyPingCount
  liftProcess $ sayRC $ "received DummyEvent " ++ str
  liftProcess $ sayRC $ "Noisy ping count: " ++ show i

ruleSyncPing :: Definitions LoopState () -- XXX: move to rules file
ruleSyncPing = defineSimple "sync-ping" $
      \(HAEvent uuid (SyncPing str) _) -> do
        eqPid <- lsEQPid <$> get Global
        registerSyncGraph $ do
          liftProcess $ sayRC $ "received SyncPing " ++ str
          usend eqPid uuid

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
  node_up     <- phaseHandle "Node already up"
  timeout_host <- phaseHandle "timeout_host"

  let start_recover (RecoverNode n1) = do
        g <- getLocalGraph
        case G.connectedFrom Runs n1 g of
          Nothing -> do
            phaseLog "warn" $ "Couldn't find host for " ++ show n1
            continue finish
          Just host -> do
            modify Local $ rlens fldNode .~ Field (Just n1)
            modify Local $ rlens fldHost .~ Field (Just host)
            modify Local $ rlens fldRetries .~ Field (Just 0)
            hasHostAttr M0.HA_TRANSIENT host >>= \case
              -- Node not already marked as down so mark it as such and
              -- notify mero
              False -> do
                setHostAttr host M0.HA_TRANSIENT
#ifdef USE_MERO
                -- ideally we would like to unregister this when
                -- monitor disconnects and not here: what if node came
                -- back before recovery fired? unlikely but who knows
                case nodeToM0Node n1 g of
                  [] -> phaseLog "warn" $ "Couldn't find any mero nodes for " ++ show n1
                  ns -> applyStateChanges $ (\n -> stateSet n NSFailed) <$> ns
                -- if the node is a mero server then power-cycle it.
                -- Client nodes can run client-software that may not be
                -- OK with reboots so we only reboot servers.
                rebootOrLogHost host
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
             -- It may be possible that node already joined and failed again.
             -- in this case new recovery rule will not be running, because
             -- this one is still running. And node monitor will be removed.
             -- A simple "hack" here is to call addNodeToCluster here.
             addNodeToCluster (eqNodes argv) node
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
             let t' = if abs maxRetries < i
                      then expirySeconds
                      else expirySeconds `div` abs maxRetries
             phaseLog "info" $ "Trying recovery again in " ++ show t' ++ " seconds for " ++ show h
             switch [timeout t' try_recover, node_up]

  setPhaseIf node_up (\(NewNodeConnected node) _ l -> do
    if Just node == getField (rget fldNode l)
    then return (Just ())
    else return Nothing) $ \() -> do
      Just node <- getField . rget fldNode <$> get Local
      modify Local $ rlens fldRep .~ (Field . Just $ RecoverNodeFinished node)
      continue finish

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

#ifdef USE_MERO
    -- Reboots the node if possible (if it's a server node) or logs an
    -- IEM otherwise.
    rebootOrLogHost :: Host -> PhaseM LoopState l ()
    rebootOrLogHost host@(Host hst) = do
      isServer <- hasHostAttr HA_M0SERVER host
      isClient <- hasHostAttr HA_M0CLIENT host
      case () of
        _ | isClient -> let msg = InterestingEventMessage $ logMeroClientFailed
                                  ( "{ 'hostname': \"" <> T.pack hst <> "\", "
                                  <> " 'reason': \"Lost connection to RC\" }")
                        in sendInterestingEvent msg
          | isServer -> do
              mchan <- findActiveSSPLChannel
              case mchan of
                Just chan ->
                  sendNodeCmdChan chan Nothing (IPMICmd IPMI_CYCLE (T.pack hst))
                Nothing ->
                  phaseLog "warn" $ "Cannot find SSPL channel to send power "
                                  ++ "cycle command."
          | otherwise ->
              phaseLog "warn" $ show host ++ " not labeled as server or client"
#endif

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
  case nodes of
    [] -> printLogs logs
    _  -> for_ nodes $ \(Node nid) ->
            nsendRemote nid (serviceLabel decisionLog) logs
  where
    rg = lsGraph ls
    nodes = [ n | host <- G.connectedTo Cluster Has rg :: [Host]
                , n <- G.connectedTo host Runs rg :: [Node]
                , not . null $ lookupServiceInfo n decisionLog rg
                ]
