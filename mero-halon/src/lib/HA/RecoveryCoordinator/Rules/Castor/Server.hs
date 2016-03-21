{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DoAndIfThenElse       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Rules specific to mero server Castor install of Mero.

module HA.RecoveryCoordinator.Rules.Castor.Server
  ( ruleNewMeroServer ) where

import           Control.Category ((>>>))
import           Control.Distributed.Process
import           Control.Monad
import           Data.Binary (Binary)
import           Data.Either (lefts, rights)
import           Data.Foldable
import           Data.Maybe (catMaybes, listToMaybe)
import           Data.Typeable (Typeable)
import           HA.EventQueue.Types
import           HA.RecoveryCoordinator.Actions.Core
import           HA.RecoveryCoordinator.Actions.Hardware
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Actions.Service (lookupRunningService)
import           HA.RecoveryCoordinator.Events.Mero
import qualified HA.ResourceGraph as G
import           HA.Resources
import           HA.Resources.Castor
import           HA.Resources.Castor.Initial (Network(Data))
import           HA.Resources.Mero hiding (Node, Process, Enclosure, Rack, fid)
import qualified HA.Resources.Mero as M0
import           HA.Services.Mero
import           HA.Services.Mero.CEP (meroChannel)
import           Mero.ConfC (Fid, ServiceType(..))
import           Network.CEP
import           Prelude

-- | Notification that barrier was passed by the cluster.
newtype BarrierPass = BarrierPass M0.MeroClusterState deriving (Binary, Show)

notifyOnClusterTranstion :: (Binary a, Typeable a)
                         => MeroClusterState -- ^ State to notify on
                         -> (MeroClusterState -> a) -- Notification to send
                         -> Maybe UUID -- Message to declare processed
                         -> PhaseM LoopState l ()
notifyOnClusterTranstion desiredState msg meid = do
  newState <- calculateMeroClusterStatus
  if newState == desiredState then do
    modifyGraph $ G.connectUnique Cluster Has newState
    syncGraphCallback $ \self proc -> do
      usend self (msg newState)
      forM_ meid proc
  else
    forM_ meid syncGraphProcessMsg

ruleNewMeroServer :: Definitions LoopState ()
ruleNewMeroServer = define "new-mero-server" $ do
    new_server <- phaseHandle "initial"
    svc_up_now <- phaseHandle "svc_up_now"
    svc_up_already <- phaseHandle "svc_up_already"
    boot_level_0_complete <- phaseHandle "boot_level_0_complete"
    boot_level_1 <- phaseHandle "boot_level_1"
    boot_level_1_complete <- phaseHandle "boot_level_1_complete"
    start_clients <- phaseHandle "start_clients"
    start_clients_complete <- phaseHandle "start_clients_complete"
    finish <- phaseHandle "finish"
    end <- phaseHandle "end"

    setPhase new_server $ \(HAEvent eid (NewMeroServer node@(Node nid)) _) -> do
      phaseLog "info" $ "NewMeroServer received for node " ++ show nid

      rg <- getLocalGraph
      case listToMaybe $ G.connectedTo Cluster Has rg of
        Just MeroClusterStopped -> do
          phaseLog "info" "Cluster is stopped."
          continue finish
        Just MeroClusterStopping{} -> do
          phaseLog "info" "Cluster is stopping."
          continue finish
        _ -> return ()

      fork CopyNewerBuffer $ do
        findNodeHost node >>= \case
          Just host -> do
            put Local $ Just (node, host, eid)
            phaseLog "info" "Starting core bootstrap"
            let mlnid = listToMaybe $ [ ip | Interface { if_network = Data, if_ipAddrs = ip:_ }
                                              <- G.connectedTo host Has rg ]
            case mlnid of
              Nothing -> do
                phaseLog "warn" $ "Unable to find Data IP addr for host "
                                ++ show host
                continue finish
              Just lnid -> do
                createMeroKernelConfig host $ lnid ++ "@tcp"
                startMeroService host node
                switch [svc_up_now, timeout 1000000 svc_up_already]
          Nothing -> do
            phaseLog "error" $ "Can't find host for node " ++ show node
            continue finish

    -- Service comes up as a result of this invocation
    setPhaseIf svc_up_now declareMeroChannelOnNode $ \chan -> do
      Just (_, host, _) <- get Local
      -- Legitimate to ignore the event id as it should be handled by the default
      -- 'declare-mero-channel' rule.
      procs <- startNodeProcesses host chan (PLBootLevel (BootLevel 0)) True
      case procs of
        [] -> let state = MeroClusterStarting (BootLevel 1) in do
          notifyOnClusterTranstion state BarrierPass Nothing
          switch [boot_level_1, timeout 5000000 finish]
        _ -> continue boot_level_0_complete

    -- Service is already up
    directly svc_up_already $ do
      Just (node, host, _) <- get Local
      rg <- getLocalGraph
      m0svc <- lookupRunningService node m0d
      case m0svc >>= meroChannel rg of
        Just chan -> do
          procs <- startNodeProcesses host chan (PLBootLevel (BootLevel 0)) True
          case procs of
            [] -> let state = MeroClusterStarting (BootLevel 1) in do
              notifyOnClusterTranstion state BarrierPass Nothing
              switch [boot_level_1, timeout 5000000 finish]
            _ -> continue boot_level_0_complete
        Nothing -> switch [svc_up_now, timeout 5000000 finish]

    -- Wait until every process comes back as finished bootstrapping
    setPhaseIf boot_level_0_complete processControlOnNode $ \(eid, e) -> do
      (procs :: [M0.Process]) <- catMaybes <$> mapM lookupConfObjByFid (lefts e)
      -- Mark successful processes as online, and others as failed.
      forM_ procs $ \p -> modifyGraph $ G.connect p Is ProcessBootstrapped
                                    >>> G.connect p Is PSOnline
      forM_ (rights e) $ \(f,r) -> lookupConfObjByFid f >>= \mp -> do
        phaseLog "warning" $ "Process " ++ show f
                          ++ " failed to start: " ++ r
        traverse_ (\(p :: M0.Process) ->
          modifyGraph $ G.connect p Is (PSFailed r)) mp
      rms <- listToMaybe
                . filter (\s -> M0.s_type s == CST_RMS)
                . join
                . filter (\s -> CST_MGS `elem` fmap M0.s_type s)
              <$> mapM getChildren procs
      traverse_ setPrincipalRMIfUnset rms
      let state = MeroClusterStarting (BootLevel 1)
      notifyOnClusterTranstion state BarrierPass (Just eid)
      switch [boot_level_1, timeout 5000000 finish]

    setPhaseIf boot_level_1 (barrierPass (MeroClusterStarting (BootLevel 1))) $ \() -> do
      Just (node, host, _) <- get Local
      g <- getLocalGraph
      m0svc <- lookupRunningService node m0d
      case m0svc >>= meroChannel g of
        Just chan -> do
          procs <- startNodeProcesses host chan (PLBootLevel (BootLevel 1)) True
          case procs of
            [] -> let state = MeroClusterStarting (BootLevel 2) in do
              notifyOnClusterTranstion state BarrierPass Nothing
              switch [start_clients, timeout 5000000 finish]
            _ -> continue boot_level_1_complete
        Nothing -> do
          phaseLog "error" $ "Can't find service for node " ++ show node
          continue finish

    -- Wait until every process comes back as finished bootstrapping
    setPhaseIf boot_level_1_complete processControlOnNode $ \(eid, e) -> do
      (procs :: [M0.Process]) <- catMaybes <$> mapM lookupConfObjByFid (lefts e)
      -- Mark successful processes as online, and others as failed.
      forM_ procs $ \p -> modifyGraph $ G.connect p Is ProcessBootstrapped
                                    >>> G.connect p Is PSOnline
      forM_ (rights e) $ \(f,r) -> lookupConfObjByFid f >>= \mp -> do
        phaseLog "warning" $ "Process " ++ show f
                          ++ " failed to start: " ++ r
        traverse_ (\(p :: M0.Process) ->
          modifyGraph $ G.connect p Is (PSFailed r)) mp
      let state = MeroClusterStarting (BootLevel 2)
      notifyOnClusterTranstion state BarrierPass (Just eid)
      switch [start_clients, timeout 5000000 finish]

    setPhaseIf start_clients (barrierPass (MeroClusterStarting (BootLevel 2))) $ \() -> do
      -- Mark the cluster as running now
      modifyGraph $ G.connectUnique Cluster Has M0.MeroClusterRunning
      Just (node, host, _) <- get Local
      rg <- getLocalGraph
      m0svc <- lookupRunningService node m0d
      case m0svc >>= meroChannel rg of
        Just chan -> do
          procs <- startNodeProcesses host chan PLM0t1fs False
          if null procs
            then continue finish
            else continue start_clients_complete
        Nothing -> continue finish

    -- Mark clients as coming up successfully.
    setPhaseIf start_clients_complete processControlOnNode $ \(eid, e) -> do
      (procs :: [M0.Process]) <- catMaybes <$> mapM lookupConfObjByFid (lefts e)
      -- Mark successful processes as online, and others as failed.
      forM_ procs $ \p -> modifyGraph $ G.connect p Is ProcessBootstrapped
                                    >>> G.connect p Is PSOnline
      forM_ (rights e) $ \(f,r) -> lookupConfObjByFid f >>= \mp -> do
        phaseLog "warning" $ "Process " ++ show f
                          ++ " failed to start: " ++ r
        traverse_ (\(p :: M0.Process) ->
          modifyGraph $ G.connect p Is (PSFailed r)) mp
      messageProcessed eid
      continue finish

    directly finish $ do
      Just (n, _, eid) <- get Local
      phaseLog "server-bootstrap" $ "Finished bootstrapping mero server at "
                                 ++ show n
      messageProcessed eid
      continue end

    directly end stop

    winit <- initWrapper new_server
    start winit Nothing
  where
    initWrapper rule = do
      wrapper_init <- phaseHandle "wrapper_init"
      wrapper_clear <- phaseHandle "wrapper_clear"
      wrapper_end <- phaseHandle "wrapper_end"
      directly wrapper_init $ switch [rule, wrapper_clear]

      directly wrapper_clear $ do
        fork NoBuffer $ continue rule
        continue wrapper_end

      directly wrapper_end stop

      return wrapper_init

    -- Check if the barrier being passed is for the correct level
    barrierPass :: MeroClusterState
                -> BarrierPass
                -> g
                -> l
                -> Process (Maybe ())
    barrierPass state (BarrierPass state') _ _ =
      if state == state' then return (Just ()) else return Nothing

    -- Check if the service process is running on this node.
    declareMeroChannelOnNode :: HAEvent DeclareMeroChannel
                             -> LoopState
                             -> Maybe (Node, Host, y)
                             -> Process (Maybe (TypedChannel ProcessControlMsg))
    declareMeroChannelOnNode _ _ Nothing = return Nothing
    declareMeroChannelOnNode (HAEvent _ (DeclareMeroChannel sp _ cc) _) ls (Just (node, _, _)) =
      case G.isConnected node Runs sp $ lsGraph ls of
        True -> return $ Just cc
        False -> return Nothing

    -- Check if the process control message is from the right node.
    processControlOnNode :: HAEvent ProcessControlResultMsg
                         -> LoopState
                         -> Maybe (Node, Host, y)
                         -> Process (Maybe (UUID, [Either Fid (Fid, String)]))
    processControlOnNode _ _ Nothing = return Nothing
    processControlOnNode (HAEvent eid (ProcessControlResultMsg nid r) _) _ (Just ((Node nid'), _, _)) =
      if nid == nid' then return $ Just (eid, r) else return Nothing
