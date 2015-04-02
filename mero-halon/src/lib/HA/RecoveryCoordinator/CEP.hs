{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
-- |
-- Copyright : (C) 2013,2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Recovery coordinator CEP rules
--
module HA.RecoveryCoordinator.CEP where

import Prelude hiding ((.), id)
import Control.Category
import Control.Monad

import Control.Distributed.Process
import Network.CEP

import HA.EventQueue.Consumer
import HA.NodeAgent.Messages
import HA.NodeUp
import HA.RecoveryCoordinator.Mero
import HA.Resources
import HA.Service
import qualified HA.Services.EQTracker as EQT
import HA.Services.SSPL (ssplRules)

rcRules :: IgnitionArguments -> ProcessId -> RuleM LoopState ()
rcRules argv eq = do

    -- Reconfigure
    define "reconfigure" id $ \msg -> do
        ReconfigureCmd n svc <- decodeMsg msg
        bounceServiceTo Intended n svc

    -- Node Up
    defineHAEvent "node-up" id $ \(HAEvent _ (NodeUp pid) _) -> do
        let nid  = processNodeId pid
            node = Node nid

        ack pid
        known <- knownResource node
        when (not known) $ do
          registerNode node
          startEQTracker nid

    -- Service Start
    defineHAEvent "service-start" id $ \evt@(HAEvent _ msg _) -> do
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

    -- Service Started
    defineHAEvent "service-started" id $ \(HAEvent _ msg _) -> do
        ServiceStarted n svc cfg sp@(ServiceProcess pid) <-
          decodeMsg msg
        when (serviceName svc == serviceName EQT.eqTracker) $ do
          True <- liftProcess $ updateEQNodes pid (stationNodes argv)
          return ()
        res <- lookupRunningService n svc
        liftProcess $ sayRC $
          "started " ++ snString (serviceName svc) ++ " service"

        case res of
          Just sp' -> unregisterPreviousServiceProcess n svc sp'
          Nothing  -> registerServiceName svc

        registerServiceProcess n svc cfg sp

    -- Service could not start
    defineHAEvent "service-could-not-start" id $ \(HAEvent _ msg _) -> do
        ServiceCouldNotStart (Node n) svc cfg <- decodeMsg msg
        startService n svc cfg

    -- Service Failed
    defineHAEvent "service-failed" id $ \(HAEvent _ msg _) -> do
        ServiceFailed n svc pid <- decodeMsg msg
        res                     <- lookupRunningService n svc
        case res of
          Just (ServiceProcess spid) | spid == pid -> do
            bounceServiceTo Current n svc
          _ -> return ()

    -- EpochRequest
    defineHAEvent "epoch-request" id $ \(HAEvent _ (EpochRequest pid) _) -> do
        resp <- prepareEpochResponse
        sendMsg pid resp

    -- Configuration Update
    defineHAEvent "configuration-update" id $ \(HAEvent _ msg _) -> do
        ConfigurationUpdate epoch opts svc nodeFilter <- decodeMsg msg

        epid <- getEpochId
        when (epoch == epid) $
            updateServiceConfiguration opts svc nodeFilter

    defineHAEvent "mm-pid" id $
      \(HAEvent _ (GetMultimapProcessId sender) _) -> do
         mmid <- getMultimapProcessId
         sendMsg sender mmid

    defineHAEvent "dummy-event" id $ \(HAEvent _ DummyEvent _) -> do
        i <- getNoisyPingCount
        liftProcess $ sayRC $ "Noisy ping count: " ++ show i

    onEveryHAEvent $ \(HAEvent eid _ _) s -> do
        usend eq eid
        return s

    ssplRules
