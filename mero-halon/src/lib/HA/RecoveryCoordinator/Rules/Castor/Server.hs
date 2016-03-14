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
import           Data.List (partition)
import           Data.Maybe (catMaybes, listToMaybe, isJust)
import           Data.Typeable (Typeable)
import           GHC.Generics (Generic)
import           HA.EventQueue.Producer
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
import           Mero.ConfC (ServiceType(..))
import           Network.CEP
import           Prelude

-- | Event sent when proessing has finished for a boot level.
data BootLevelComplete = BootLevelComplete NodeId ProcessLabel
  deriving (Typeable, Generic)

instance Binary BootLevelComplete

-- | Bootstrap a new mero server.
--
-- Procedure:
--
-- * Receive 'NewMeroServer'. Mark the node as being bootstrapped.
-- Start the mero service and wait for the reply from it in the next
-- phase.
--
-- * Receive 'MeroServerCoreBootstrapped' from the mero service. Wait
-- until we have received this message for every node we have been
-- bootstrapping so far. Once we do, send a message to each node
-- telling it to start non-core services.
--
-- * Receive the non-core service message. Tell each node to start the
-- services it's in charge of.
--
-- * Wait for 'MeroServerBootstrapped' from the non-core service
-- starter. Wait until every node gets this message. Remove the RG
-- bootstrap flag from the nodes in the RG. The rule ends.
ruleNewMeroServer :: Definitions LoopState ()
ruleNewMeroServer = define "new-mero-server" $ do
  new_server <- phaseHandle "initial"
  svc_up_now <- phaseHandle "svc_up_now"
  svc_up_already <- phaseHandle "svc_up_already"
  core_bootstrapped <- phaseHandle "core-bootstrapped"
  start_remaining_services <- phaseHandle "start-remaining-services"
  finish_extra_bootstrap <- phaseHandle "finish-extra-bootstrap"
  start_clients <- phaseHandle "start_clients"
  finish <- phaseHandle "finish"
  end <- phaseHandle "end"

  let alreadyBootstrapping n g = G.isConnected Cluster Runs (ServerBootstrapCoreProcess n False) g
                                || G.isConnected Cluster Runs (ServerBootstrapProcess n False) g

      ackingLast handle newMsgEid newNid phase = do
        Just (Node nid, eid) <- get Local
        if (nid /= newNid)
        then continue handle
        else do messageProcessed eid
                put Local $ Just (Node nid, newMsgEid)
                phase

      failureHandler e nid = case rights e of
        [] -> Nothing
        xs -> Just $ do
          forM_ xs $ \(fid, ex) -> do
            phaseLog "warn" $ "Core bootstrapping of process "
                            ++ (show fid)
                            ++ " failed on "
                            ++ (show nid)
            phaseLog "warn" ex
          findNodeHost (Node nid) >>= \case
            Nothing -> return ()
            Just host ->
              setHostAttr host (HA_BOOTSTRAP_FAILED $ fmap snd xs)

      onNode :: HAEvent DeclareMeroChannel
             -> LoopState
             -> Maybe (Node, y)
             -> Process (Maybe (Host, TypedChannel ProcessControlMsg))
      onNode _ _ Nothing = return Nothing
      onNode (HAEvent _ (DeclareMeroChannel sp _ cc) _) ls (Just (node, _)) =
        let
          rg = lsGraph ls
          mhost = G.connectedFrom Runs node rg :: [Host]
          rightNode = G.isConnected node Runs sp rg
        in case (rightNode, mhost) of
          (True, [host]) -> return $ Just (host, cc)
          (_, _) -> return Nothing

  setPhase new_server $ \(HAEvent eid (NewMeroServer node@(Node nid)) _) -> do
    rg <- getLocalGraph
    case listToMaybe $ G.connectedTo Cluster Has rg of
      Just MeroClusterStopped -> do
        phaseLog "info" "Cluster is not running skip node"
        continue finish
      Just MeroClusterStopping{} -> do
        phaseLog "info" "Cluster is not running skip node"
        continue finish
      _ -> return ()

    fork CopyNewerBuffer $ do
      phaseLog "info" $ "NewMeroServer received for node " ++ show nid
      put Local $ Just (node, eid)
      findNodeHost node >>= \case
        Just host -> alreadyBootstrapping nid <$> getLocalGraph >>= \case
          True -> continue finish
          False -> do
            let pcore = ServerBootstrapCoreProcess nid False
            phaseLog "info" "Starting core bootstrap"
            modifyLocalGraph $
              return . G.connect Cluster Runs pcore . G.newResource pcore
            g <- getLocalGraph
            let mlnid = listToMaybe $ [ ip | Interface { if_network = Data, if_ipAddrs = ip:_ }
                                              <- G.connectedTo host Has g ]
            case mlnid of
              Nothing -> do
                phaseLog "warn" $ "Unable to find Data IP addr for host "
                                ++ show host
                continue finish
              Just lnid -> do
                createMeroKernelConfig host $ lnid ++ "@tcp"
                startMeroService host node
                switch [svc_up_now, timeout 5000000 svc_up_already]
        Nothing -> do
          phaseLog "error" $ "Can't find host for node " ++ show node
          continue finish

  setPhaseIf svc_up_now onNode $ \(host, chan) -> do
    -- Legitimate to avoid the event id as it should be handled by the default
    -- 'declare-mero-channel' rule.
    startNodeProcesses host chan (PLBootLevel (BootLevel 0)) True
    continue core_bootstrapped

  -- Service is already up
  directly svc_up_already $ do
    Just (node, _) <- get Local
    rg <- getLocalGraph
    m0svc <- lookupRunningService node m0d
    mhost <- findNodeHost node
    case (,) <$> mhost <*> (m0svc >>= meroChannel rg) of
      Just (host, chan) -> do
        startNodeProcesses host chan (PLBootLevel (BootLevel 0)) True
        continue core_bootstrapped
      Nothing -> switch [svc_up_now, timeout 5000000 finish]

  -- Wait until every process comes back as finished bootstrapping
  setPhase core_bootstrapped $ \(HAEvent eid (ProcessControlResultMsg nid e) _) -> do
    (procs :: [M0.Process]) <- catMaybes <$> mapM lookupConfObjByFid (lefts e)
    rms <- listToMaybe
              . filter (\s -> M0.s_type s == CST_RMS)
              . join
              . filter (\s -> CST_MGS `elem` fmap M0.s_type s)
            <$> mapM getChildren procs
    traverse_ setPrincipalRMIfUnset rms
    ackingLast core_bootstrapped eid nid $
      barrier
        Cluster Runs
        (ServerBootstrapCoreProcess nid)
        (\(ServerBootstrapCoreProcess _ b) -> b)
        start_remaining_services finish (failureHandler e nid)
        (\(ServerBootstrapCoreProcess nid' _) ->
          liftProcess . promulgateWait $ BootLevelComplete nid' (PLBootLevel (BootLevel 0)))

  setPhase start_remaining_services $ \(HAEvent eid (BootLevelComplete nid _) _) -> do
    Just (node@(Node nid'), eid') <- get Local
    g <- getLocalGraph
    case () of
      _ | (nid /= nid') -> continue start_remaining_services
        | G.isConnected Cluster Runs (ServerBootstrapProcess nid False) g -> do
            phaseLog "info" $ "Already bootstrapping: " ++ show nid
            continue finish_extra_bootstrap
        | otherwise -> do
           messageProcessed eid'
           put Local $ Just (Node nid', eid)
           modifyLocalGraph $
             return . G.connect Cluster Runs (ServerBootstrapProcess nid False)
           syncGraphBlocking
           m0svc <- lookupRunningService node m0d
           mhost <- findNodeHost (Node nid)
           case (,) <$> mhost <*> (m0svc >>= meroChannel g) of
             Just (host, chan) -> do
               startNodeProcesses host chan (PLBootLevel (BootLevel 1)) True
               continue finish_extra_bootstrap
             Nothing -> do
               phaseLog "error" $ "Can't find host for node " ++ show node
               continue finish

  setPhase finish_extra_bootstrap $ \(HAEvent eid (ProcessControlResultMsg nid _) _) -> do
    ackingLast finish_extra_bootstrap eid nid $
      barrier
        Cluster Runs
        (ServerBootstrapProcess nid)
        (\(ServerBootstrapProcess _ b) -> b)
        start_clients finish Nothing
        (\(ServerBootstrapProcess nid' _) ->
          liftProcess . promulgateWait $ BootLevelComplete nid' (PLBootLevel (BootLevel 1)))

  setPhase start_clients $ \(HAEvent eid (BootLevelComplete nid' bl) _) -> do
    Just (node@(Node nid), eid') <- get Local
    if nid == nid' && bl == PLBootLevel (BootLevel 1) then do
      messageProcessed eid'
      put Local $ Just (node, eid)
      rg <- getLocalGraph
      m0svc <- lookupRunningService node m0d
      mhost <- findNodeHost node
      case (,) <$> mhost <*> (m0svc >>= meroChannel rg) of
        Just (host, chan) -> do
          startNodeProcesses host chan PLM0t1fs False
          continue finish
        Nothing -> continue finish
    else
      continue start_clients

  directly finish $ do
    Just (n, eid) <- get Local
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


-- |
-- @
-- 'barrier' hookPoint hookRel setState viewState phandle failHandle
-- failure release
-- @
--
-- A helper for creating barriers across multiple workers. Providied
-- some user-defined tracking state for each of the workers and some
-- information on how to query it, we can synchronise by having each
-- of the workers check if it's the last one to finish its work. All
-- workers continue to @phandle@ regardless but the last one also runs
-- @release@. It should be easy to see that if @phandle@ blocks until
-- certain condition happens and @release@ satisfies that condition,
-- we have a barrier. Note there is no internal blocking mechanism:
-- this helper relies on @phandle@ to block and @release@ to unblock.
--
-- In case that @failure@ is not 'Nothing', something has gone wrong
-- with this worker so we shouldn't advance it to @phandle@ nor
-- consider it in @release@. Instead, run @failure@ which should be
-- used to mark failure for the rest of the system if necessary and
-- then advance the worker to @failHandle@. If the failed worker is
-- the last one in the pool, it will still run @release@ before
-- continuing to @failHandle@.
--
-- @viewState . setState == id@
barrier :: forall r a st l. G.Relation r a st
        => a -- ^ Resource to which tracking states are attached to
        -> r -- ^ Relation by which the tracking states are attached through
        -> (Bool -> st) -- ^ Tracker state constructor
        -> (st -> Bool) -- ^ Tracker state destructor
        -> Jump PhaseHandle -- ^ Next phase
        -> Jump PhaseHandle -- ^ Bail out phase
        -> Maybe (PhaseM LoopState l ())
        -- ^ Exception handler bootstrap process
        -> (st -> PhaseM LoopState l ())
        -- ^ Callback to execute by the last worker in the pool: this
        -- should allow the other workers to progress onto the given
        -- phase handle, effectively releasing the barrier. The
        -- release callback is applied to each of the tracking states
        -- to give it a chance to make a smart release.
        -> PhaseM LoopState l ()
barrier hookPoint hookRel setState viewState phandle failHandle failure release = do
  modifyLocalGraph $ return . G.disconnect hookPoint hookRel (setState False)
  reconnectStatus
  g <- getLocalGraph
  let finished, unfinished :: [st]
      (finished, unfinished) = partition viewState $ G.connectedTo hookPoint hookRel g
  when (null unfinished) $ do
    modifyLocalGraph $ \g0 -> do
      -- Disconect all the state trackers from the RG, we no longer
      -- need them.
      return $ foldl' (\g' sp -> G.disconnect hookPoint hookRel sp g') g0 finished
    mapM_ release finished
  continue $ if isJust failure then failHandle else phandle
  where
    -- When we have a failure handler available, use it. If not then
    -- there was no failure so insert tracking state back into RG as
    -- successful so the barrier release can catch it.
    reconnectStatus = case failure of
      Nothing -> modifyLocalGraph
                $ G.newResource (setState True)
             >>> return . G.connect hookPoint hookRel (setState True)
      Just h -> h
