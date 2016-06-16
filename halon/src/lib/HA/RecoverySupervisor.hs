-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This module provides the Recovery Supervisor. The Recovery Supervisor
-- ensures that there is at most one Recovery Coordinator running in the cluster
-- at any given time.
--
-- The recovery supervisors form a group of processes with a leader. Each
-- supervisor runs co-located with a replica, so if the group of replicas has
-- quorum so too does the group of supervisors. The leader starts and monitors
-- the Recovery Coordinator.

module HA.RecoverySupervisor ( recoverySupervisor) where

import HA.Logger
import HA.Replicator ( RGroup, getLeaderReplica, monitorLocalLeader )

import Control.Distributed.Process hiding (catch)

import Control.Monad.Catch
import Control.Monad ( void )


rsTrace :: String -> Process ()
rsTrace = mkHalonTracer "RS"

-- | Runs the recovery supervisor.
recoverySupervisor :: RGroup g
                   => g st -- ^ the replication group used to elect a leader
                   -> Process () -- ^ the closure used to run the recovery
                                 -- coordinator.
                   -> Process ()
recoverySupervisor rg rcP = do
    rsTrace "Starting"
    void $ waitToBecomeLeader
    rsTrace "Terminated"
   `catch` \e -> do
    rsTrace $ "Dying with " ++ show e
    liftIO $ throwM (e :: SomeException)
  where
    waitToBecomeLeader :: Process a
    waitToBecomeLeader = do
      mLeader <- getLeaderReplica rg
      here <- getSelfNode
      if mLeader == Just here then do
        rsTrace "Became leader"
        ref <- monitorLocalLeader rg
        go ref Nothing
      else do
        rsTrace $ "Waiting " ++ show mLeader
        receiveTimeout 1000000 [] >> waitToBecomeLeader

    -- Takes the pid of the recovery coordinator.
    go :: MonitorRef -> Maybe ProcessId -> Process a
    go leaderRef mRC = do
      rc <- maybe spawnRC return mRC
      pmn@(ProcessMonitorNotification ref pid _) <- expect
      rsTrace $ show pmn
      -- Respawn the RC if it died.
      if rc == pid then do
        rsTrace "Respawning rc"
        go leaderRef Nothing
      -- The leader lost the lease
      else if ref == leaderRef then do
        rsTrace "Lost the lease"
        killRC rc >> waitToBecomeLeader
      else
        go leaderRef (Just rc)

    spawnRC = do
      say "RS: I'm the new leader, so starting RC ..."
      self <- getSelfPid
      rc <- spawnLocal $ (link self >> rcP >> say "RS: RC died normally")
                `catch` \e -> do say $ "RS: RC died " ++ show e
                                 liftIO $ throwM (e :: SomeException)
      _ <- monitor rc
      return rc

    killRC rc = do
      say "RS: lease expired, so killing RC ..."
      exit rc "lease lost"
      -- Block until RC actually dies. Otherwise, a new RC may start before
      -- the old one quits.
      receiveWait
        [ matchIf (\(ProcessMonitorNotification _ pid _) -> pid == rc)
                  (const $ return ())
        ]
