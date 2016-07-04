{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase       #-}
{-# LANGUAGE TypeFamilies     #-}
{-# LANGUAGE TypeOperators    #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Controller handling.
module HA.RecoveryCoordinator.Rules.Castor.Controller
  ( ruleControllerChanged
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
import           HA.RecoveryCoordinator.Rules.Mero.Conf
import qualified HA.ResourceGraph as G
import           HA.Resources (Has(..), Node(..), Cluster(..))
import           HA.Resources.Castor (Is(..))
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note (ConfObjectState(..), getState, showFid)
import           HA.Services.Mero (m0d)
import           HA.Services.Mero.CEP (meroChannel)
import           HA.Services.Mero.Types
import           Mero.Notification (Set(..))
import           Mero.Notification.HAState (Note(..))
import           Network.CEP


import           Control.Monad (when)
import           Data.Typeable
import           Data.Foldable
import           Text.Printf

-- | Controller state changed, handles FAILED and ONLINE
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

  setPhaseNotified notified ctrlFailed $ \(ctrl, _) -> do
    Just (eid, _) <- get Local
    phaseLog "info" $ "Controller change OK: " ++ showFid ctrl
    done eid
    stop

  directly notify_timed_out $ do
    Just (eid, (ctrl, _)) <- get Local
    phaseLog "warn" $ "Notification timed out for " ++ showFid ctrl
    done eid
    stop

  start rule_init Nothing

  where
    ctrlFailed = fmap snd

    getCtrl :: Note -> PhaseM LoopState l (Maybe (M0.Controller, ConfObjectState))
    getCtrl (Note fid' t) | t == M0_NC_FAILED || t == M0_NC_ONLINE = do
      obj <- HA.RecoveryCoordinator.Actions.Mero.lookupConfObjByFid fid'
      return $ (,) <$> obj <*> pure t
    getCtrl _ = return Nothing
