{-# LANGUAGE LambdaCase            #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

module HA.RecoveryCoordinator.Actions.Mero
  ( module HA.RecoveryCoordinator.Actions.Mero.Conf
  , module HA.RecoveryCoordinator.Actions.Mero.Core
  , module HA.RecoveryCoordinator.Actions.Mero.Spiel
  , updateDriveState
  )
where

import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Mero.Conf
import HA.RecoveryCoordinator.Actions.Mero.Core
import HA.RecoveryCoordinator.Actions.Mero.Spiel

import HA.Resources.Castor (Is(..))
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import qualified HA.ResourceGraph as G
import HA.Services.Mero (notifyMero)

import Control.Monad (when)

import Network.CEP

updateDriveState :: M0.SDev -- ^ Drive to update state
                 -> M0.ConfObjectState -- ^ State to update to
                 -> PhaseM LoopState l ()

-- | For transient failures, we may need to create a new pool version.
updateDriveState m0sdev M0.M0_NC_TRANSIENT = do
  -- Update state in RG
  modifyGraph $ G.connectUnique m0sdev Is M0.M0_NC_TRANSIENT
  syncGraph
  -- If using dynamic failure sets, generate failure set
  getM0Globals >>= \case
    Just x | CI.m0_failure_set_gen x == CI.Dynamic -> do
      syncNeeded <- createPVerIfNotExists
      when syncNeeded $ syncAction Nothing M0.SyncToConfdServersInRG
    _ -> return ()
  -- Notify Mero
  notifyMero [M0.AnyConfObj m0sdev] M0.M0_NC_TRANSIENT

-- | For all other states, we simply update in the RG and notify Mero.
updateDriveState m0sdev x = do
  -- Update state in RG
  modifyGraph $ G.connect m0sdev Is x
  syncGraph
  -- Notify Mero
  notifyMero [M0.AnyConfObj m0sdev] x
