{-# LANGUAGE TypeOperators #-}
-- |
-- Copyright : (C) 2013,2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- * Recovery coordinator
--
-- LEGEND: RC - recovery coordinator, R - replicator, RG - resource graph.
--
-- Behaviour of RC is determined by the state of RG and incoming HA events that
-- are posted by R from the event queue maintained by R. After recovering an HA
-- event, RC instructs R to drop the event, using a globally unique identifier.

{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE CPP                        #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}

module HA.RecoveryCoordinator.Mero
       ( module HA.RecoveryCoordinator.Actions.Core
       , module HA.RecoveryCoordinator.Actions.Hardware
       , module HA.RecoveryCoordinator.Actions.Service
       , IgnitionArguments(..)
       , GetMultimapProcessId(..)
       , sayRC
       , ack
       , getSelfProcessId
       , sendMsg
       , makeRecoveryCoordinator
       , prepareEpochResponse
       , getEpochId
       , decodeMsg
       , lookupDLogServiceProcess
       , sendToMonitor
       , registerMasterMonitor
       , getMultimapProcessId
       , getNoisyPingCount
       , sendToMasterMonitor
       , rcInitRule
       , handled
       , startProcessingMsg
       , finishProcessingMsg
       , loadNodeMonitorConf
       , notHandled
       ) where

import Prelude hiding ((.), id, mapM_)
import HA.EventQueue.Types (HAEvent(..))
import HA.Resources
import HA.Resources.Castor (Host(..))
import HA.Service
import HA.Services.DecisionLog
import HA.Services.Monitor
import HA.Services.Noisy

import qualified HA.EQTracker as EQT

import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Hardware
import HA.RecoveryCoordinator.Actions.Service
import qualified HA.ResourceGraph as G

import Control.Distributed.Process
import Control.Distributed.Process.Serializable

import Control.Monad
import Control.Wire hiding (when)

import Data.Binary (Binary)
import Data.ByteString (ByteString)
import Data.Dynamic
import qualified Data.Map.Strict as Map
import qualified Data.Set as S
import Data.Maybe (fromMaybe)
import Data.UUID (UUID)
import Data.Word

import GHC.Generics (Generic)

import Network.CEP
import Network.HostName

-- | Initial configuration data.
data IgnitionArguments = IgnitionArguments
  { -- | The names of all tracking station nodes.
    stationNodes :: [NodeId]
  } deriving (Generic,Typeable)

instance Binary IgnitionArguments

-- | An internal message type.
data NodeAgentContacted = NodeAgentContacted ProcessId
         deriving (Typeable, Generic)

instance Binary NodeAgentContacted

data GetMultimapProcessId =
    GetMultimapProcessId ProcessId deriving (Typeable, Generic)

instance Binary GetMultimapProcessId

waitServiceToStart :: Service a
                   -> HAEvent ServiceStartedMsg
                   -> LoopState
                   -> l
                   -> Process (Maybe (HAEvent ServiceStartedMsg))
waitServiceToStart s evt@(HAEvent _ msg _) g l = do
    res <- notHandled evt g l
    case res of
      Nothing -> return Nothing
      Just _  -> do
        ServiceStarted n svc _ _ <- decodeP msg
        snid                     <- getSelfNode
        let Node nid = n
        if serviceName svc == (serviceName s) && nid == snid
          then return $ Just evt
          else return Nothing

notHandled :: HAEvent a -> LoopState -> l -> Process (Maybe (HAEvent a))
notHandled evt@(HAEvent eid _ _) ls _
    | S.member eid $ lsHandled ls = return Nothing
    | otherwise                   = return $ Just evt

handled :: ProcessId -> HAEvent a -> PhaseM LoopState l ()
handled eq (HAEvent eid _ _) = do
    ls <- get Global
    let ls' = ls { lsHandled = S.insert eid $ lsHandled ls }
    put Global ls'
    sendMsg eq eid

finishProcessingMsg :: UUID -> PhaseM LoopState l ()
finishProcessingMsg eid = do
    ls <- get Global
    let ls' = ls { lsHandled = S.delete eid $ lsHandled ls }
    put Global ls'

startProcessingMsg :: UUID -> PhaseM LoopState l ()
startProcessingMsg eid = do
    ls <- get Global
    let ls' = ls { lsHandled = S.insert eid $ lsHandled ls }
    put Global ls'

rcInitRule :: IgnitionArguments
           -> ProcessId
           -> RuleM LoopState (Maybe ProcessId) (Started LoopState (Maybe ProcessId))
rcInitRule argv eq = do
    boot        <- phaseHandle "boot"
    start_mm    <- phaseHandle "start_master_monitor"
    mm_started  <- phaseHandle "master_monitor_started"
    mm_conf     <- phaseHandle "master_monitor_conf"
    nm_started  <- phaseHandle "node_monitor_started"

    directly boot $ do
      h   <- liftIO getHostName
      nid <- liftProcess getSelfNode
      liftProcess . sayRC $ "My hostname is " ++ show h ++ " and nid is " ++ show (Node nid)
      let node = Node nid
          host = Host h
      liftProcess . sayRC $ "Executing on node: " ++ show nid
      registerNode node
      registerHost host
      locateNodeOnHost node host
      liftProcess $ EQT.updateEQNodes $ stationNodes argv
      continue start_mm

    directly start_mm $ do
      nid  <- liftProcess getSelfNode
      conf <- stealMasterMonitorConf
      _    <- startService nid masterMonitor conf
      continue mm_started

    setPhaseIf mm_started (waitServiceToStart masterMonitor) $ \evt -> do
      handled eq evt
      ServiceStarted _ _ _ (ServiceProcess mpid) <- decodeMsg (eventPayload evt)
      liftProcess $ link mpid
      continue mm_conf

    setPhase mm_conf $
        \evt@(HAEvent _ (SetMasterMonitor sp@(ServiceProcess pid)) _) -> do
      liftProcess $ usend pid =<< getSelfPid
      registerMasterMonitor sp
      handled eq evt
      liftProcess $ sayRC $ "started master-monitor service"
      -- We start a new monitor for any node that's started
      registerService regularMonitor
      nid  <- liftProcess getSelfNode
      conf <- loadNodeMonitorConf (Node nid)
      startService nid regularMonitor conf
      continue nm_started

    setPhaseIf nm_started (waitServiceToStart regularMonitor) $
      \evt@(HAEvent _ msg _) -> do
        ServiceStarted n svc cfg sp <- decodeMsg msg
        registerServiceName svc
        registerServiceProcess n svc cfg sp
        sendToMasterMonitor msg
        handled eq evt
        liftProcess $ do
          sayRC $ "started " ++ snString (serviceName svc) ++ " service"
          sayRC $ "continuing in normal mode"

    start boot Nothing

stealMasterMonitorConf :: PhaseM LoopState l MonitorConf
stealMasterMonitorConf = do
    rg <- getLocalGraph
    let action = do
          sp   <- lookupMasterMonitor rg
          conf <- readConfig sp Current rg
          return (sp, conf)
    case action of
      Nothing         -> return emptyMonitorConf
      Just (sp, conf) -> do
        let rg' = disconnectConfig sp Current >>>
                  G.disconnect Cluster MasterMonitor sp $ rg
        putLocalGraph rg'
        return conf

loadNodeMonitorConf :: Node -> PhaseM LoopState l MonitorConf
loadNodeMonitorConf node = do
    res <- lookupRunningService node regularMonitor
    rg  <- getLocalGraph
    let action = do
          sp <- res
          readConfig sp Current rg
    return $ fromMaybe emptyMonitorConf action

registerMasterMonitor :: ServiceProcess MonitorConf -> PhaseM LoopState l ()
registerMasterMonitor sp = modifyLocalGraph $ \rg ->
    return $ G.connect Cluster MasterMonitor sp rg

lookupMasterMonitor :: G.Graph -> Maybe (ServiceProcess MonitorConf)
lookupMasterMonitor rg =
    case G.connectedTo Cluster MasterMonitor rg of
      [sp] -> Just sp
      _    -> Nothing

ack :: ProcessId -> PhaseM LoopState l ()
ack pid = liftProcess $ usend pid ()

getSelfProcessId :: PhaseM g l ProcessId
getSelfProcessId = liftProcess getSelfPid

getNoisyPingCount :: PhaseM LoopState l Int
getNoisyPingCount = do
    phaseLog "rg-query" "Querying noisy ping count."
    rg <- getLocalGraph
    let (rg', i) =
          case G.connectedTo noisy HasPingCount rg of
            [] ->
              let nrg = G.connect noisy HasPingCount (NoisyPingCount 0) $
                        G.newResource (NoisyPingCount 0) rg in
              (nrg, 0)
            pc@(NoisyPingCount iPc) : _ ->
              let newPingCount = NoisyPingCount (iPc + 1)
                  nrg = G.connect noisy HasPingCount newPingCount $
                        G.newResource newPingCount $
                        G.disconnect noisy HasPingCount pc rg in
              (nrg, iPc)
    putLocalGraph rg'
    return i

lookupDLogServiceProcess :: NodeId -> LoopState -> Maybe (ServiceProcess DecisionLogConf)
lookupDLogServiceProcess nid ls =
    runningService (Node nid) decisionLog $ lsGraph ls

sendToMonitor :: Serializable a => Node -> a -> PhaseM LoopState l ()
sendToMonitor node a = do
    res <- lookupRunningService node regularMonitor
    forM_ res $ \(ServiceProcess pid) ->
      liftProcess $ do
        sayRC $ "Sent to Monitor on " ++ show node ++ " to " ++ show pid
        usend pid a

-- | Sends a message to the Master Monitor.
sendToMasterMonitor :: Serializable a => a -> PhaseM LoopState l ()
sendToMasterMonitor a = do
    self <- liftProcess getSelfNode
    spm  <- fmap lookupMasterMonitor getLocalGraph
    -- In case the `MasterMonitor` link is not established, look for a
    -- local instance
    spm' <- lookupRunningService (Node self) masterMonitor
    forM_ (spm <|> spm') $ \(ServiceProcess mpid) -> liftProcess $ do
      sayRC "Sent to Master monitor"
      usend mpid a

sayRC :: String -> Process ()
sayRC s = say $ "Recovery Coordinator: " ++ s

sendMsg :: Serializable a => ProcessId -> a -> PhaseM g l ()
sendMsg pid a = liftProcess $ usend pid a

decodeMsg :: ProcessEncode a => BinRep a -> PhaseM g l a
decodeMsg = liftProcess . decodeP

initialize :: ProcessId -> Process G.Graph
initialize mm = do
    rg <- G.getGraph mm
    if G.null rg then say "Starting from empty graph."
                 else say "Found existing graph."
    -- Empty graph means cluster initialization.
    let rg' | G.null rg =
            G.newResource Cluster >>>
            G.newResource (Epoch 0 "y = x^2" :: Epoch ByteString) >>>
            G.connect Cluster Has (Epoch 0 "y = x^2" :: Epoch ByteString) $ rg
            | otherwise = rg
    return rg'

prepareEpochResponse :: PhaseM LoopState l EpochResponse
prepareEpochResponse = do
    rg <- getLocalGraph

    let edges :: [G.Edge Cluster Has (Epoch ByteString)]
        edges = G.edgesFromSrc Cluster rg
        G.Edge _ Has target = head edges

    return $ EpochResponse $ epochId target

getEpochId :: PhaseM LoopState l Word64
getEpochId = do
    rg <- getLocalGraph

    let edges :: [G.Edge Cluster Has (Epoch ByteString)]
        edges = G.edgesFromSrc Cluster rg
        G.Edge _ Has target = head edges

    return $ epochId target

getMultimapProcessId :: PhaseM LoopState l ProcessId
getMultimapProcessId = fmap lsMMPid $ get Global

----------------------------------------------------------
-- Recovery Co-ordinator                                --
----------------------------------------------------------

-- | The entry point for the RC.
--
-- Before evaluating 'recoveryCoordinator', the global network variable needs
-- to be initialized with 'HA.Network.Address.writeNetworkGlobalIVar'. This is
-- done automatically if 'HA.Network.Address.startNetwork' is used to create
-- the transport.
makeRecoveryCoordinator :: ProcessId -- ^ pid of the replicated multimap
                        -> Definitions LoopState ()
                        -> Process ()
makeRecoveryCoordinator mm rm = do
    rg      <- HA.RecoveryCoordinator.Mero.initialize mm
    startRG <- G.sync rg
    execute (LoopState startRG Map.empty mm S.empty) $ do
      rm
      setRuleFinalizer $ \ls -> do
        newGraph <- G.sync $ lsGraph ls
        return ls { lsGraph = newGraph }

-- remotable [ 'recoveryCoordinator ]
