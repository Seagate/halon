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
import SSPL.Bindings

import HA.EventQueue.Consumer
import HA.NodeUp
import HA.RecoveryCoordinator.Mero
import HA.Resources
import HA.Service
import HA.Services.SSPL

rcRules :: IgnitionArguments -> ProcessId -> RuleM LoopState ()
rcRules argv eq = do

    -- Reconfigure
    define id $ \msg -> do
        ReconfigureCmd n svc <- decodeMsg msg
        _                    <- bounceServiceTo Intended n svc
        return ()

    -- Node Up
    defineHAEvent id $ \(HAEvent _ (NodeUp pid) _) -> do
        let nid  = processNodeId pid
            node = Node nid

        ack pid
        known <- knownResource node
        when (not known) $ do
          registerNode node
          startEQTracker argv nid
          syncResourceGraph

    -- Service Start
    defineHAEvent id $ \evt@(HAEvent _ msg _) -> do
        ServiceStartRequest n@(Node nid) svc conf <- decodeMsg msg
        known   <- knownResource n
        running <- isServiceRunning n svc

        if known && not running
            then do
            registerService svc
            _ <- startService nid svc conf
            syncResourceGraph
            else do
            pid <- getSelfProcessId
            sendMsg pid evt

    -- Service Started
    defineHAEvent id $ \(HAEvent _ msg _) -> do
        ServiceStarted n svc@Service{..} cfg sp <- decodeMsg msg
        res <- lookupRunningService n svc

        case res of
          Just sp' -> unregisterPreviousServiceProcess n svc sp'
          Nothing  -> registerServiceName svc

        registerServiceProcess n svc cfg sp
        syncResourceGraph

    -- Service Failed
    defineHAEvent id $ \(HAEvent eid msg _) -> do
        ServiceFailed n svc <- decodeMsg msg
        _ <- bounceServiceTo Current n svc
        sendMsg eq eid

    -- EpochRequest
    defineHAEvent id $ \(HAEvent _ (EpochRequest pid) _) -> do
        resp <- prepareEpochResponse
        sendMsg pid resp

    -- Configuration Update
    defineHAEvent id $ \(HAEvent _ msg _) -> do
        ConfigurationUpdate epoch opts svc nodeFilter <- decodeMsg msg

        epid <- getEpochId
        when (epoch == epid) $
            updateServiceConfiguration opts svc nodeFilter

    defineHAEvent id $
        \(HAEvent _ (DeclareChannels pid svc acs) _) -> do
            registerChannels svc acs
            ack pid

    -- SSPL Monitor drivemanager
    defineHAEvent id $ \(HAEvent _ (nid, mrm) _) -> do
        let disk_status = monitorResponseMonitor_msg_typeDisk_status_drivemanagerDiskStatus mrm
        when (disk_status == "inuse_removed") $ do
          let msg = InterestingEventMessage "Bunnies, bunnies it must be bunnies."
          sendInterestingEvent nid msg
