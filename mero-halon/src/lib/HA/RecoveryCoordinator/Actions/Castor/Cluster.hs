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

import Control.Distributed.Process (Process, usend)

import Data.Binary (Binary)
import Data.Foldable (for_)
import Data.Typeable (Typeable)
import Data.UUID (UUID)

import Network.CEP

-- | Message guard: Check if the barrier being passed is for the
-- correct level. This is used during 'ruleNewMeroServer' with the
-- actual 'BarrierPass' message being emitted from
-- 'notifyOnClusterTransition'.
barrierPass :: (M0.MeroClusterState -> Bool)
            -> Event.BarrierPass
            -> g
            -> l
            -> Process (Maybe ())
barrierPass rightState (Event.BarrierPass state') _ _ =
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
notifyOnClusterTransition :: (Binary a, Typeable a)
                          => (M0.MeroClusterState -> Bool) -- ^ States to notify on
                          -> (M0.MeroClusterState -> a) -- Notification to send
                          -> Maybe UUID -- Message to declare processed
                          -> PhaseM LoopState l ()
notifyOnClusterTransition desiredState msg meid = do
  newState <- calculateMeroClusterStatus
  if desiredState newState then do
    let state'  = case desiredState of
         _ | newState == M0.MeroClusterStarting clusterStartedBootLevel ->
              M0.MeroClusterRunning
         _ -> newState
    phaseLog "info" $ "Cluster state changed to " ++ show state'
    modifyGraph $ G.connectUnique R.Cluster R.Has state'
    syncGraphCallback $ \self proc -> do
      usend self (msg state')
      for_ meid proc
  else
    for_ meid syncGraphProcessMsg
