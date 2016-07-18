{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase       #-}
{-# LANGUAGE TypeFamilies     #-}
{-# LANGUAGE TypeOperators    #-}
{-# LANGUAGE ViewPatterns     #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Controller handling.
module HA.RecoveryCoordinator.Rules.Castor.Controller
  ( ruleControllerChanged
  , ruleShouldFailController
  ) where

import           HA.Encode
import           Control.Monad.Trans.Maybe
import           Data.Either (partitionEithers, rights)
import           Data.Maybe (catMaybes, listToMaybe, mapMaybe)
import           HA.EventQueue.Types
import           HA.RecoveryCoordinator.Actions.Core
import           HA.RecoveryCoordinator.Actions.Hardware
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Actions.Service (lookupRunningService)
import           HA.RecoveryCoordinator.Events.Mero
import           HA.RecoveryCoordinator.Rules.Castor.Node (StartProcessesOnNodeRequest(..))
import           HA.RecoveryCoordinator.Rules.Mero.Conf
import qualified HA.ResourceGraph as G
import           HA.Resources (Has(..),  Cluster(..), Runs(..))
import qualified HA.Resources.Castor as R
import           HA.Resources.Castor (Is(..))
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note (ConfObjectState(..), getState, showFid)
import           HA.Services.Mero (m0d)
import           HA.Services.Mero.CEP (meroChannel)
import           HA.Services.Mero.Types
import           Mero.ConfC (ServiceType(CST_HA))
import           Mero.Notification (Set(..))
import           Mero.Notification.HAState (Note(..))
import           Network.CEP

import           Control.Monad (when)
import           Data.Typeable
import           Data.Foldable
import           Data.List (nub)
import           Text.Printf

-- | Controller state changed, handles FAILED and ONLINE.
ruleControllerChanged :: Definitions LoopState ()
ruleControllerChanged = define "controller-changed" $ do
  rule_init <- phaseHandle "rule_init"
  notified <- phaseHandle "notified"
  notify_timed_out <- phaseHandle "notify_timed_out"

  setPhase rule_init $ \(HAEvent eid (Set ns) _) -> do
    ctrls <- catMaybes <$> mapM getCtrl ns
    for_ ctrls $ \(ctrl, t) -> fork NoBuffer $ do
      todo eid
      phaseLog "info" $ "Notifying about " ++ showFid ctrl ++ " " ++ show t
      applyStateChanges [ stateSet ctrl t ]
      put Local $ Just (eid, (ctrl, t))
      switch [notified, timeout 10 notify_timed_out]

  setPhaseNotified notified ctrlState $ \(ctrl, t) -> do
    Just (eid, _) <- get Local
    phaseLog "info" $ "Controller change OK: " ++ showFid ctrl
    rg <- getLocalGraph
    let ns = [ n | (h :: R.Host) <- G.connectedTo ctrl M0.At rg
                 , (n :: M0.Node) <- G.connectedTo h Runs rg ]
    when (t == M0_NC_ONLINE) $ do
      -- Request an explicit restart of the processes on the node.
      -- Just failing the processes is not good enough: halon will try
      -- to restart all processes at once and that fails. Instead we
      -- restart them in nice order.
      when (length ns /= 1) $ do
        phaseLog "warn" $ "Expected 1 node for controller, found: " ++ show ns
      mapM_ (promulgateRC . StartProcessesOnNodeRequest) ns

    done eid
    stop

  directly notify_timed_out $ do
    Just (eid, (ctrl, _)) <- get Local
    phaseLog "warn" $ "Notification timed out for " ++ showFid ctrl
    done eid
    stop

  startFork rule_init Nothing

  where
    ctrlState = fmap snd

    getCtrl :: Note -> PhaseM LoopState l (Maybe (M0.Controller, ConfObjectState))
    getCtrl (Note fid' t) | t == M0_NC_FAILED || t == M0_NC_ONLINE = do
      obj <- HA.RecoveryCoordinator.Actions.Mero.lookupConfObjByFid fid'
      return $ (,) <$> obj <*> pure t
    getCtrl _ = return Nothing

-- | If every process on a controller has failed, fail the controller.
ruleShouldFailController :: Definitions LoopState ()
ruleShouldFailController = define "controller-should-fail" $ do
  rule_init <- phaseHandle "rule_init"
  setPhaseInternalNotificationWithState rule_init isProcFailed $ \(eid, map fst -> (procs :: [M0.Process])) -> do
    todo eid
    rg <- getLocalGraph
    for_ (nub $ concatMap (`getCtrl` rg) procs) $ \(ctrl, ps) -> when (all (`pFailed` rg) ps) $ do
      applyStateChanges [stateSet ctrl M0_NC_FAILED]
    done eid

  startFork rule_init ()
  where
    isHalonProcess p rg =
      any (\s -> M0.s_type s == CST_HA) $ G.connectedTo p M0.IsParentOf rg

    isProcFailed (M0.PSFailed _) = True
    isProcFailed _ = False

    pFailed p rg = case getState p rg of
      M0.PSFailed _ -> True
      -- Ignore state of halon process
      _ | isHalonProcess p rg -> True
      _ -> False

    getCtrl p rg = [ (c, (G.connectedTo n M0.IsParentOf rg :: [M0.Process]))
                   | (n :: M0.Node) <- G.connectedFrom M0.IsParentOf p rg
                   , (c :: M0.Controller) <- G.connectedTo n M0.IsOnHardware rg
                   , getState c rg /= M0_NC_FAILED
                   ]
