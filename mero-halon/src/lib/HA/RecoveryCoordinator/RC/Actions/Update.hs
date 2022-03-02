-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Actions specific to handling an update of Halon itself.
module HA.RecoveryCoordinator.RC.Actions.Update where

import           Control.Distributed.Process (ProcessId, unStatic)
import           Data.Foldable (for_)
import           HA.RecoveryCoordinator.Mero
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.ResourceGraph as G
import qualified HA.Resources as R
import           HA.Resources.Update (Todo(..))
import           Network.CEP

applyTodoNode :: PhaseM RC (Maybe ProcessId) ()
applyTodoNode = do
  mtodo <- G.connectedTo R.Cluster R.Has <$> getGraph
  for_ mtodo $ \td@(Todo s) -> do
    Log.rcLog' Log.DEBUG "Applying Todo node."
    act <- liftProcess $ unStatic s
    act
    Log.rcLog' Log.DEBUG "Todo node applied successfully - removing."
    modifyGraph $ G.removeResource td
