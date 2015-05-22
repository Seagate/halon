-- |
-- Copyright : (C) 2013,2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Recovery coordinator CEP rules
--

{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module HA.RecoveryCoordinator.CEP where

import Prelude hiding ((.), id)
import Control.Category
import Control.Monad
import Data.Foldable (for_)

import Control.Distributed.Process
import Network.CEP

import           HA.EventQueue.Consumer
import           HA.NodeAgent.Messages
import           HA.NodeUp
import           HA.RecoveryCoordinator.Mero
import           HA.Resources
import           HA.Resources.Mero
import           HA.Service
import qualified HA.Services.EQTracker as EQT
#ifdef USE_MERO
import           HA.Services.Mero (meroRules)
#endif
import           HA.Services.Monitor ( SaveProcesses(..)
                                     , SetMasterMonitor(..)
                                     , monitorServiceName
                                     , regularMonitor
                                     , emptyMonitorConf
                                     )
import           HA.Services.SSPL (ssplRules)

rcRules :: IgnitionArguments -> ProcessId -> Definitions LoopState ()
rcRules argv eq = do

    -- Reconfigure
    define "reconfigure" $ \msg -> do
      ph1 <- phase "state1" $ do
        ReconfigureCmd n svc <- decodeMsg msg
        bounceServiceTo Intended n svc
      start ph1

    -- Node Up
    defineHAEvent "node-up" $ \(HAEvent eid (NodeUp h pid) _) -> do
      ph1 <- phase "state1" $ do
        let nid  = processNodeId pid
            node = Node nid

        ack pid
        known <- knownResource node
        when (not known) $ do
          liftProcess . sayRC $ "New node contacted: " ++ show nid
          let host = Host h
          registerService EQT.eqTracker
          registerNode node
          registerHost host
          locateNodeOnHost node host
          startEQTracker nid

          -- We start a new monitor for any node that's started
          registerService regularMonitor
          _ <- startService nid regularMonitor emptyMonitorConf
          return ()
        sendMsg eq eid
      start ph1

    -- Service Start
    defineHAEvent "service-start" $ \evt@(HAEvent eid msg _) -> do
      ph1 <- phase "state1" $ do
        ServiceStartRequest n@(Node nid) svc conf <- decodeMsg msg
        known   <- knownResource n
        running <- isServiceRunning n svc

        if known && not running
            then do
            registerService svc
            _ <- startService nid svc conf
            return ()
            else do
            pid <- getSelfProcessId
            sendMsg pid evt
        sendMsg eq eid
      start ph1

    -- Service Started
    defineHAEvent "service-started" $ \evt@(HAEvent eid msg _) -> do
      ph1 <- phase "state1" $ do
        ServiceStarted n svc cfg sp@(ServiceProcess pid) <-
          decodeMsg msg
        when (serviceName svc == serviceName EQT.eqTracker) $ do
          True <- liftProcess $ updateEQNodes pid (stationNodes argv)
          return ()
        publish evt

        res <- lookupRunningService n svc
        liftProcess $ sayRC $
          "started " ++ snString (serviceName svc) ++ " service"

        case res of
          Just sp' -> unregisterServiceProcess n svc sp'
          Nothing  -> registerServiceName svc

        registerServiceProcess n svc cfg sp
        let svcStr = snString $ serviceName svc

        when (serviceName svc /= monitorServiceName) $
          sendToMonitor n msg

        when (serviceName svc == monitorServiceName) $
          sendToMasterMonitor msg

        phaseLog "started" ("Service " ++ svcStr ++ " started")
        sendMsg eq eid
      start ph1

    -- Service could not start
    defineHAEvent "service-could-not-start" $ \(HAEvent eid msg _) -> do
      ph1 <- phase "state1" $ do
        ServiceCouldNotStart (Node n) svc cfg <- decodeMsg msg
        startService n svc cfg
        sendMsg eq eid
      start ph1

    -- Service Failed
    defineHAEvent "service-failed" $ \(HAEvent eid msg _) -> do
      ph1 <- phase "state1" $ do
        ServiceFailed n svc pid <- decodeMsg msg
        res                     <- lookupRunningService n svc
        case res of
          Just (ServiceProcess spid) | spid == pid -> do
            bounceServiceTo Current n svc
          _ -> return ()
        sendMsg eq eid
      start ph1

    -- EpochRequest
    defineHAEvent "epoch-request" $ \(HAEvent eid (EpochRequest pid) _) -> do
      ph1 <- phase "state1" $ do
        resp <- prepareEpochResponse
        sendMsg pid resp
        sendMsg eq eid
      start ph1

    -- Configuration Update
    defineHAEvent "configuration-update" $ \(HAEvent eid msg _) -> do
      ph1 <- phase "state1" $ do
        ConfigurationUpdate epoch opts svc nodeFilter <- decodeMsg msg

        epid <- getEpochId
        when (epoch == epid) $
          reconfigureService opts svc nodeFilter
        sendMsg eq eid
      start ph1

    defineHAEvent "mm-pid" $
      \(HAEvent eid (GetMultimapProcessId sender) _) -> do
         ph1 <- phase "state1" $ do
           mmid <- getMultimapProcessId
           sendMsg sender mmid
           sendMsg eq eid
         start ph1

    defineHAEvent "dummy-event" $ \(HAEvent eid DummyEvent _) -> do
      ph1 <- phase "state1" $ do
        i <- getNoisyPingCount
        liftProcess $ sayRC $ "Noisy ping count: " ++ show i
        sendMsg eq eid
      start ph1

    defineHAEvent "stop-request" $ \(HAEvent eid msg _) -> do
      ph1 <- phase "state1" $ do
        ServiceStopRequest node svc <- decodeMsg msg
        res                         <- lookupRunningService node svc
        for_ res $ \sp ->
          killService sp UserStop
        sendMsg eq eid
      start ph1

    defineHAEvent "save-processes" $
      \(HAEvent eid (SaveProcesses sp ps) _) -> do
        ph1 <- phase "state1" $ do
          writeConfiguration sp ps Current
          sendMsg eq eid
        start ph1

    defineHAEvent "set-master-monitor" $
      \(HAEvent eid (SetMasterMonitor sp) _) -> do
        ph1 <- phase "state1" $ do
          registerMasterMonitor sp
          sendMsg eq eid
        start ph1

    setLogger sendLogs

    ssplRules
#ifdef USE_MERO
    meroRules
#endif

sendLogs :: Logs -> LoopState -> Process ()
sendLogs logs ls =
    for_ (lookupDLogServiceProcess ls) $ \(ServiceProcess pid) -> do
      usend pid logs
