-- |
-- Copyright : (C) 2013,2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Recovery coordinator CEP rules
--

{-# LANGUAGE CPP                       #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE TemplateHaskell           #-}

module HA.RecoveryCoordinator.CEP where

import Prelude hiding ((.), id)
import Control.Applicative ((<|>))
import Control.Category
import Control.Monad (void)
import Data.Binary (Binary, encode)
import Data.Foldable (for_)
import Data.Maybe (catMaybes, listToMaybe)
import Data.Typeable (Typeable)
import GHC.Generics

import           Control.Distributed.Process
import           Control.Distributed.Process.Closure (mkClosure)
import           Control.Distributed.Process.Internal.Types (Message(..))
import           Data.UUID (nil, null)
import           Network.CEP
import           Network.HostName

import           HA.EventQueue.Types
import           HA.NodeUp
import           HA.RecoveryCoordinator.Mero
import           HA.RecoveryCoordinator.Events.Status
import           HA.RecoveryCoordinator.Events.Mero
import           HA.RecoveryCoordinator.Rules.Castor
import           HA.RecoveryCoordinator.Rules.Service
import           HA.RecoveryCoordinator.Actions.Monitor
import qualified HA.ResourceGraph as G
import           HA.Resources
import           HA.Resources.Castor
import           HA.Service
import           HA.Services.DecisionLog (decisionLog, printLogs)
import           HA.Services.Monitor
import           HA.EQTracker (updateEQNodes__static, updateEQNodes__sdict)
import qualified HA.EQTracker as EQT
import qualified HA.Resources.Castor as M0
#ifdef USE_MERO
import           Control.Monad (forM_)
import qualified Data.Text as T
import           HA.RecoveryCoordinator.Actions.Mero.Conf (getFilesystem)
import           HA.RecoveryCoordinator.Rules.Mero (meroRules)
import           HA.RecoveryCoordinator.Rules.Castor.Cluster (clusterRules)
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note (ConfObjectState(M0_NC_ONLINE, M0_NC_TRANSIENT))
import           HA.Services.Mero (meroRules, notifyMero)
import           HA.Services.SSPL (sendNodeCmd)
import           HA.Services.SSPL.LL.Resources (NodeCmd(..), IPMIOp(..))
#endif
import           HA.Services.SSPL (ssplRules)
import           HA.Services.SSPL.HL.CEP (ssplHLRules)
import           HA.Services.Frontier.CEP (frontierRules)

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
      ms   <- getNodeRegularMonitors
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
    setBuffer $ fifoBuffer (Bounded 4096)

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
              , ruleNodeStatus argv
              , ruleRecoverNode argv
              , ruleDummyEvent
              , ruleStopRequest
              ]
    setLogger sendLogs
    serviceRules argv
    ssplRules
    castorRules
    frontierRules
    ssplHLRules
#ifdef USE_MERO
    HA.Services.Mero.meroRules
    HA.RecoveryCoordinator.Rules.Mero.meroRules
    HA.RecoveryCoordinator.Rules.Castor.Cluster.clusterRules
#endif
    sequence_ additionalRules


ruleNodeUp :: IgnitionArguments -> Definitions LoopState ()
ruleNodeUp argv = define "node-up" $ do
      nodeup      <- phaseHandle "nodeup"
      nm_started  <- phaseHandle "node_monitor_started"
      nm_start    <- phaseHandle "node_monitor_start"
      nm_failed   <- phaseHandle "node_monitor_could_not_start"
      mm_reply    <- phaseHandle "master_monitor_reply"
      nm_reply    <- phaseHandle "regular_monitor_reply"
      end         <- phaseHandle "end"

      setPhaseIf nodeup notHandled $ \(HAEvent uuid (NodeUp h pid) _) -> do
        startProcessingMsg uuid
        let nid  = processNodeId pid
            node = Node nid
        liftProcess . sayRC $ "New node contacted: " ++ show nid
        known <- hasHostAttr HA_TRANSIENT (Host h) >>= \case
          False -> do
            liftProcess . sayRC $ "Potentially new node, no revival: " ++ show node
            knownResource node
          True -> do
            liftProcess . sayRC $ "Reviving old node: " ++ show node
            unsetHostAttr (Host h) HA_TRANSIENT
            unsetHostAttr (Host h) HA_DOWN
            syncGraph $ return () -- XXX: maybe we need barrier here
#ifdef USE_MERO
            g <- getLocalGraph
            let nodes = [ M0.AnyConfObj n
                        | (c :: M0.Controller) <- G.connectedFrom M0.At (Host h) g
                        , (n :: M0.Node) <- G.connectedFrom M0.IsOnHardware c g
                        ]
            notifyMero nodes M0_NC_ONLINE
#endif
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
            continue nodeup
          else do
            -- Check if we already provision node with a monitor or not.
            msp  <- lookupRunningService (Node nid) regularMonitor
            case msp of
              Nothing -> do
                fork NoBuffer $ do
                  put Local (Starting uuid nid conf regularMonitor pid)
                  continue nm_start
                continue nodeup
              Just _  -> do liftProcess . sayRC $ "node is already provisioned: " ++ show nid
                            ack pid
                            messageProcessed uuid
                            finishProcessingMsg uuid
                            continue nodeup

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
        liftProcess $ sayRC $ "Sending ack to " ++ show npid
        ack npid
        liftProcess $ sayRC $ "Ack sent to " ++ show npid
        messageProcessed uuid
        sendNewMeroNodeMsg <- findNodeHost (Node nid) >>= return . \case
          Nothing -> promulgateRC $ NewMeroClient (Node nid)
          Just host -> do
            g <- getLocalGraph
            if G.isConnected host Has HA_M0SERVER g
            then promulgateRC $ NewMeroServer (Node nid)
            -- if we don't have the server label, assume mero client
            -- even if no client label
            else promulgateRC $ NewMeroClient (Node nid)
#ifdef USE_MERO
        getFilesystem >>= \case
           Nothing ->
             phaseLog "info" "Configuration data was not loaded yet, skipping"
           Just{} -> sendNewMeroNodeMsg
#else
        sendNewMeroNodeMsg
#endif
        finishProcessingMsg uuid
        continue end

      setPhaseIf nm_failed serviceBootCouldNotStart $
          \(HAEvent msgid msg _) -> do
        ServiceCouldNotStart n svc _ <- decodeMsg msg
        liftProcess $ sayRC $
          "failed " ++ snString (serviceName svc) ++ " service on the node " ++ show n
        messageProcessed msgid
        Starting uuid _ _ _ _ <- get Local
        finishProcessingMsg uuid
        continue end  -- XXX: retry on timeout from nm start

      directly end stop

      start nodeup None

ruleNodeStatus :: IgnitionArguments -> Definitions LoopState ()
ruleNodeStatus argv = defineSimple "node-status" $
      \(HAEvent uuid (NodeStatusRequest n@(Node nid) lis) _) -> do
        rg <- getLocalGraph
        let
          isStation = nid `elem` (eqNodes argv)
          isSatellite = G.memberResource n rg
          response = NodeStatusResponse n isStation isSatellite
        liftProcess $ mapM_ (flip usend response) lis
        messageProcessed uuid

ruleDummyEvent :: Definitions LoopState ()
ruleDummyEvent = defineSimple "dummy-event" $
      \(HAEvent uuid (DummyEvent str) _) -> do
        i <- getNoisyPingCount
        liftProcess $ sayRC $ "received DummyEvent " ++ str
        liftProcess $ sayRC $ "Noisy ping count: " ++ show i
        messageProcessed uuid

ruleStopRequest :: Definitions LoopState ()
ruleStopRequest = defineSimple "stop-request" $ \(HAEvent uuid msg _) -> do
      ServiceStopRequest node svc <- decodeMsg msg
      res                         <- lookupRunningService node svc
      for_ res $ \sp ->
        killService sp Shutdown
      messageProcessed uuid

data RecoverNodeAck = RecoverNodeAck UUID
  deriving (Eq, Show, Typeable, Generic)

instance Binary RecoverNodeAck

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
ruleRecoverNode argv = define "recover-node" $ do
      let expirySeconds = 300
          maxRetries = 5
      start_recover <- phaseHandle "start_recover"
      try_recover <- phaseHandle "try_recover"
      timeout_host <- phaseHandle "timeout_host"
      finalize_rule <- phaseHandle "finalize_rule"

      setPhase start_recover $ \(RecoverNode uuid n1) -> do
        startProcessingMsg uuid
        g <- getLocalGraph

        case listToMaybe (G.connectedFrom Runs n1 g) of
          Nothing -> return ()
          Just host@(Host _hst) -> hasHostAttr M0.HA_TRANSIENT host >>= \case
            -- Node not already marked as down so mark it as such and
            -- notify mero
            False -> do
              setHostAttr host M0.HA_TRANSIENT
#ifdef USE_MERO
              let nodes = [ n
                          | (c :: M0.Controller) <- G.connectedFrom M0.At host g
                          , (n :: M0.Node) <- G.connectedFrom M0.IsOnHardware c g
                          ]
              notifyMero (M0.AnyConfObj <$> nodes) M0_NC_TRANSIENT
              -- if the node is a mero server then power-cycle it.
              -- Client nodes can run client-software that may not be
              -- OK with reboots so we only reboot servers.
              whenM (hasHostAttr M0.HA_M0SERVER host) $ do
                ns <- nodesOnHost host
                forM_ ns $ \(Node nid) ->
                  sendNodeCmd nid Nothing (IPMICmd IPMI_CYCLE (T.pack _hst))
#endif
              put Local (uuid, Just (n1, host, 0))
            -- Node already marked as down, probably the RC died. Do
            -- the simple thing and start the recovery all over: as
            -- long as the RC doesn't die more often than a full node
            -- timeout happens, we'll finish the recovery eventually
            True -> put Local (uuid, Just (n1, host, 0))
        liftProcess $ sayRC $ "Marked node transient: " ++ show n1

        continue try_recover

      let ackMsg m = if Data.UUID.null m
                     then return ()
                     else finishProcessingMsg m >> messageProcessed m

      directly try_recover $ do
        get Local >>= \case
          (uuid, Just (Node nid, h, i)) | i >= maxRetries -> continue timeout_host
                                        | otherwise -> do
            hasHostAttr M0.HA_TRANSIENT h >>= \case
              False -> ackMsg uuid
              True -> do
                liftProcess $ sayRC "Inside try_recover"
                put Local (uuid, Just (Node nid, h, i + 1))
                void . liftProcess . callLocal . spawnAsync nid $
                  $(mkClosure 'nodeUp) ((eqNodes argv), (100 :: Int))
                let t' = expirySeconds `div` maxRetries
                liftProcess $ sayRC $ "try_recover again in " ++ show t' ++ " seconds for " ++ show h
                continue $ timeout t' try_recover
          _ -> return ()

      directly timeout_host $ do
        let log' = liftProcess . sayRC
        (uuid, st) <- get Local
        case st of
          Just (n1, h, i) -> do
            log' $ "timeout_host Just " ++ show (n1, h, i)
            timeoutHost h
            put Local (nil, Nothing)
          _ -> log' "timeout_host nothing" >> return ()
        syncGraphProcess $ \self -> usend self $ RecoverNodeAck uuid
        continue finalize_rule

      setPhase finalize_rule $ \(RecoverNodeAck uuid) -> ackMsg uuid

      start start_recover (nil, Nothing)


-- | Send 'Logs' to decision-log service. First it tries to send to
-- decision-log on own node. If service is not found, it tries to find
-- the service on another node and send the logs there. If no service
-- is found across all nodes, just defaults to 'printLogs'.
sendLogs :: Logs -> LoopState -> Process ()
sendLogs logs ls = do
  nid <- getSelfNode
  case lookupDLogServiceProcess nid ls <|> svc of
    Just (ServiceProcess pid) -> usend pid logs
    Nothing -> printLogs logs
  where
    rg = lsGraph ls
    nodes = [ n | host <- G.connectedTo Cluster Has rg :: [Host]
                , n <- G.connectedTo host Runs rg ]
    svc = listToMaybe . catMaybes $
          map (\n -> runningService n decisionLog rg) nodes
