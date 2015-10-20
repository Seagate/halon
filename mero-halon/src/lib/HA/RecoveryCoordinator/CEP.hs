-- |
-- Copyright : (C) 2013,2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Recovery coordinator CEP rules
--

{-# LANGUAGE CPP                       #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RecordWildCards           #-}

module HA.RecoveryCoordinator.CEP where

import Prelude hiding ((.), id)
import Control.Category
import Data.Foldable (for_)

import           Control.Distributed.Process
import           Control.Distributed.Process.Internal.Types (nullProcessId)
import           Network.CEP

import           HA.EventQueue.Types
import           HA.NodeAgent.Messages
import           HA.NodeUp
import           HA.RecoveryCoordinator.Mero
import           HA.RecoveryCoordinator.Rules.Castor
import           HA.RecoveryCoordinator.Rules.Service
import           HA.Resources
import           HA.Resources.Castor
import           HA.Service
import qualified HA.EQTracker as EQT
#ifdef USE_MERO
import           HA.Services.Mero (meroRules)
#endif
import           HA.Services.Monitor (SaveProcesses(..), regularMonitor)
import           HA.Services.SSPL (ssplRules)


rcRules :: IgnitionArguments -> ProcessId -> [Definitions LoopState ()] -> Definitions LoopState ()
rcRules argv eq additionalRules = do
    initRule $ rcInitRule argv eq

    define "node-up" $ do
      nodeup      <- phaseHandle "nodeup"
      nm_started  <- phaseHandle "node_monitor_started"
      nm_start    <- phaseHandle "node_monitor_start"
      nm_failed   <- phaseHandle "node_monitor_could_not_start"
      end         <- phaseHandle "end"

      setPhaseIf nodeup notHandled $ \(HAEvent uuid (NodeUp h pid) _) -> do
        startProcessingMsg uuid
        let nid  = processNodeId pid
            node = Node nid
        liftProcess . sayRC $ "New node contacted: " ++ show nid
        known <- knownResource node
        conf <- loadNodeMonitorConf (Node nid)
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
                            sendMsg eq uuid
                            finishProcessingMsg uuid
                            continue nodeup

      directly nm_start $ do
        Starting _ nid conf svc _ <- get Local
        liftProcess $ nsendRemote nid EQT.name
          (nullProcessId nid, UpdateEQNodes $ stationNodes argv)
        registerService svc
        startService nid svc conf
        switch [nm_started, nm_failed]

      setPhaseIf nm_started serviceBootStarted $
          \(HAEvent msgid msg _) -> do
        ServiceStarted n svc cfg sp <- decodeMsg msg
        liftProcess $ sayRC $
          "started " ++ snString (serviceName svc) ++ " service on " ++ show sp
        Starting uuid _ _ _ npid <- get Local
        registerServiceName svc
        registerServiceProcess n svc cfg sp
        sendToMasterMonitor msg
        ack npid
        sendMsg eq msgid
        sendMsg eq uuid
        finishProcessingMsg uuid
        continue end

      setPhaseIf nm_failed serviceBootCouldNotStart $
          \(HAEvent msgid msg _) -> do
        ServiceCouldNotStart n svc _ <- decodeMsg msg
        liftProcess $ sayRC $
          "failed " ++ snString (serviceName svc) ++ " service on the node " ++ show n
        sendMsg eq msgid
        Starting uuid _ _ _ _ <- get Local
        finishProcessingMsg uuid
        continue end

      directly end stop

      start nodeup None

    -- EpochRequest
    defineSimple "epoch-request" $
      \(HAEvent uuid (EpochRequest pid) _) -> do
      resp <- prepareEpochResponse
      sendMsg pid resp
      sendMsg eq uuid

    defineSimple "mm-pid" $
      \(HAEvent uuid (GetMultimapProcessId sender) _) -> do
         mmid <- getMultimapProcessId
         sendMsg sender mmid
         sendMsg eq uuid

    defineSimple "dummy-event" $
      \(HAEvent uuid (DummyEvent str) _) -> do
        i <- getNoisyPingCount
        liftProcess $ sayRC $ "received DummyEvent " ++ str
        liftProcess $ sayRC $ "Noisy ping count: " ++ show i
        sendMsg eq uuid

    defineSimple "stop-request" $ \(HAEvent uuid msg _) -> do
      ServiceStopRequest node svc <- decodeMsg msg
      res                         <- lookupRunningService node svc
      for_ res $ \sp ->
        killService sp UserStop
      sendMsg eq uuid

    defineSimple "save-processes" $
      \(HAEvent uuid (SaveProcesses sp ps) _) -> do
       writeConfiguration sp ps Current
       sendMsg eq uuid

    setLogger sendLogs
    serviceRules argv eq
    ssplRules
    castorRules
#ifdef USE_MERO
    meroRules
#endif
    sequence_ additionalRules

sendLogs :: Logs -> LoopState -> Process ()
sendLogs logs ls = do
    nid <- getSelfNode
    for_ (lookupDLogServiceProcess nid ls) $ \(ServiceProcess pid) ->
      usend pid logs
