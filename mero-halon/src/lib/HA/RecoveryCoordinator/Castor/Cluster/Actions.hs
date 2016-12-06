-- |
-- Copyright:  (C) 2015 Seagate Technology Limited.
--
module HA.RecoveryCoordinator.Castor.Cluster.Actions
  ( -- * Guards
    barrierPass
    -- *Actions
  , notifyOnClusterTransition
  ) where

import           HA.RecoveryCoordinator.RC.Actions
import           HA.RecoveryCoordinator.Actions.Mero
import qualified HA.ResourceGraph    as G
import qualified HA.Resources        as R
import qualified HA.Resources.Mero   as M0
import qualified HA.RecoveryCoordinator.Castor.Cluster.Events as Event

import Control.Distributed.Process (Process, usend)

import Network.CEP

-- | Message guard: Check if the barrier being passed is for the
-- correct level. This is used during 'ruleNewMeroServer' with the
-- actual 'MeroClusterState' message being emitted from
-- 'notifyOnClusterTransition'.
barrierPass :: (M0.MeroClusterState -> Bool)
            -> Event.ClusterStateChange
            -> g
            -> l
            -> Process (Maybe ())
barrierPass rightState (Event.ClusterStateChange _ state') _ _ =
  if rightState state' then return (Just ()) else return Nothing

-- | Send a notification when the cluster state transitions.
--
-- The user specifies the desired state for the cluster and a builder
-- for for a notification that is sent when the cluster enters that
-- state. This means we can block across nodes by waiting for such a
-- message.
--
-- Whether the cluster is in the new state is determined by
-- 'calculateMeroClusterStatus' which traverses the RG and checks the
-- current cluster status and status of the processes on the current
-- cluster boot level.
notifyOnClusterTransition :: PhaseM RC l ()
notifyOnClusterTransition = do
  rg <- getLocalGraph
  newRunLevel <- calculateRunLevel
  newStopLevel <- calculateStopLevel
  let disposition = maybe M0.OFFLINE id $ G.connectedTo R.Cluster R.Has rg
      oldState = getClusterStatus rg
      newState = M0.MeroClusterState disposition newRunLevel newStopLevel
  phaseLog "oldState" $ show oldState
  phaseLog "newState" $ show newState
  modifyGraph $ G.connect R.Cluster M0.StopLevel newStopLevel
              . G.connect R.Cluster M0.RunLevel newRunLevel
  registerSyncGraphCallback $ \self _ -> do
    usend self (Event.ClusterStateChange oldState newState)
