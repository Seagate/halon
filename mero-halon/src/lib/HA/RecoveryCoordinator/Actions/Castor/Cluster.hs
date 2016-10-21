-- |
-- Copyright:  (C) 2015 Seagate Technology Limited.
--
module HA.RecoveryCoordinator.Actions.Castor.Cluster
  ( -- * Guards
    barrierPass
    -- *Actions
  , notifyOnClusterTransition
  ) where

import           HA.RecoveryCoordinator.Actions.Core
import           HA.RecoveryCoordinator.Actions.Mero
import qualified HA.ResourceGraph    as G
import qualified HA.Resources        as R
import qualified HA.Resources.Mero   as M0
import qualified HA.RecoveryCoordinator.Events.Castor.Cluster as Event

import Control.Category ((>>>))
import Control.Distributed.Process (Process, usend)
import Control.Lens ((<&>))

import Data.Foldable (for_)
import Data.UUID (UUID)

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
notifyOnClusterTransition :: Maybe UUID -- ^ Message to declare processed
                          -> PhaseM LoopState l ()
notifyOnClusterTransition meid = do
  oldState <- getLocalGraph <&> getClusterStatus
  newRunLevel <- calculateRunLevel
  newStopLevel <- calculateStopLevel
  disposition <- getLocalGraph <&> maybe M0.OFFLINE id
                                 . G.connectedTo R.Cluster R.Has
  let newState = M0.MeroClusterState disposition newRunLevel newStopLevel
  phaseLog "oldState" $ show oldState
  phaseLog "newState" $ show newState
  modifyGraph $ G.connect R.Cluster M0.RunLevel newRunLevel
            >>> G.connect R.Cluster M0.StopLevel newStopLevel
  registerSyncGraphCallback $ \self proc -> do
    usend self (Event.ClusterStateChange oldState newState)
    for_ meid proc
