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
import HA.RecoveryCoordinator.Actions.Mero.Failure

import HA.Resources.Castor (Is(..))
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import qualified HA.ResourceGraph as G
import HA.Services.Mero (notifyMero)
import Data.Foldable (forM_)
import Data.Maybe (listToMaybe)

import Network.CEP

updateDriveState :: M0.SDev -- ^ Drive to update state
                 -> M0.ConfObjectState -- ^ State to update to
                 -> PhaseM LoopState l ()

-- | For transient failures, we may need to create a new pool version.
updateDriveState m0sdev M0.M0_NC_TRANSIENT = do
  -- Update state in RG
  modifyGraph $ G.connectUnique m0sdev Is M0.M0_NC_TRANSIENT
  syncGraph (return ()) -- possibly we need to wait here, but I see no good
                        -- reason for that.
  -- If using dynamic failure sets, generate failure set
  graph <- getLocalGraph
  mstrategy <- getCurrentStrategy
  forM_ mstrategy $ \strategy ->
    forM_ (onFailure strategy graph) $ \graph' -> do
      putLocalGraph graph'
      syncAction Nothing M0.SyncToConfdServersInRG
  case listToMaybe $ G.connectedTo m0sdev M0.IsOnHardware graph of
    Nothing -> phaseLog "error" "Can't find Disk corresponding to sdev"
    Just m0disk ->
      -- Notify Mero
      notifyMero [M0.AnyConfObj (m0disk :: M0.Disk)] M0.M0_NC_TRANSIENT

-- | For all other states, we simply update in the RG and notify Mero.
updateDriveState m0sdev x = do
  -- Update state in RG
  modifyGraph $ G.connect m0sdev Is x
  -- Quite possibly we need to wait for synchronization result here, because
  -- otherwise we may notifyMero multiple times (if consesus will be lost).
  -- however in opposite case we may never notify mero if RC will die after
  -- sync, but before it notified mero.
  syncGraph (return ()) 
  -- Notify Mero
  graph <- getLocalGraph
  case listToMaybe $ G.connectedTo m0sdev M0.IsOnHardware graph of
    Nothing -> phaseLog "error" "Can't find Disk corresponding to sdev"
    Just m0disk ->
      -- Notify Mero
      notifyMero [M0.AnyConfObj (m0disk::M0.Disk)] x
