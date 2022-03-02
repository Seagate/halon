-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- This module provides the Recovery Supervisor. The Recovery Supervisor
-- ensures that there is at most one Recovery Coordinator running in the cluster
-- at any given time.
--
-- The recovery supervisors form a group of processes with a leader. Each
-- supervisor runs co-located with a replica, so if the group of replicas has
-- quorum so too does the group of supervisors. The leader starts and monitors
-- the Recovery Coordinator.

module HA.RecoverySupervisor
  ( RSPing
  , keepaliveReply
  , recoverySupervisor
  , ReallyDie(..)
  ) where

import Control.Distributed.Process hiding (catch)
import Control.Monad ( void )
import Control.Monad.Catch
import Data.Binary
import Data.Function
import qualified Data.Text as T
import GHC.Generics
import HA.Debug
import HA.Logger
import HA.Replicator ( RGroup, getLeaderReplica, monitorLocalLeader )
import Text.Read (readMaybe)

rsTrace :: String -> Process ()
rsTrace = mkHalonTracer "RS"

-- | Delay between checks if node is already a leader.
delayLeader :: Int
delayLeader = 1000000 -- 1s

-- | Timeout between pongs from RC.
pingTimeout :: Int
pingTimeout = 300000000 -- 5m

-- | Timeout between pongs from RC.
pongTimeout :: Int
pongTimeout = 5000000 -- 5s

-- | Reply to keepalive message.
-- This datatype is internal to this module, so nobody can generate
-- message of this type to trick RS.
--
-- As there is only one RC in the cluster it's ok to not keep 'ProcessId'
-- in the message payload.
data RSPong = RSPong deriving (Eq, Show, Generic)
instance Binary RSPong

-- | Keepalive request.
newtype RSPing = RSPing ProcessId deriving (Eq, Show, Generic)
instance Binary RSPing

newtype ReallyDie = ReallyDie T.Text
  deriving (Read, Show)
instance Exception ReallyDie

-- | Reply to keepalive message.
keepaliveReply :: RSPing -> Process ()
keepaliveReply (RSPing p) = usend p RSPong

-- | Runs the recovery supervisor.
recoverySupervisor :: RGroup g
                   => g st -- ^ the replication group used to elect a leader
                   -> Process () -- ^ the closure used to run the recovery
                                 -- coordinator.
                   -> Process ()
recoverySupervisor rg rcP = do
    labelProcess "ha::rs"
    rsTrace "Starting"
    void $ waitToBecomeLeader
    rsTrace "Terminated"
   `catch` \e -> do
    rsTrace $ "Dying with " ++ show e
    liftIO $ throwM (e :: SomeException)
  where
    waitToBecomeLeader :: Process a
    waitToBecomeLeader = do
      rsTrace "getLeaderReplica"
      mLeader <- getLeaderReplica rg
      here <- getSelfNode
      if mLeader == Just here then do
        rsTrace "Became leader"
        ref <- monitorLocalLeader rg
        go ref Nothing
      else do
        rsTrace $ "Waiting " ++ show mLeader
        receiveTimeout delayLeader [] >> waitToBecomeLeader

    -- Takes the pid of the recovery coordinator.
    go :: MonitorRef -> Maybe ProcessId -> Process a
    go leaderRef mRC = do
      rc <- maybe spawnRC return mRC
      maction <- receiveTimeout pingTimeout
         [ match $ \pmn@(ProcessMonitorNotification ref pid reason) -> do
             case reason of
               DiedException str -> case readMaybe str of
                 Just e@(ReallyDie r) -> do
                   say $ "RC asked to die with " ++ T.unpack r
                   throwM e
                 Nothing -> say $ "RC died with " ++ show reason
               _ -> say $ "RC died with " ++ show reason
             rsTrace $ show pmn
             -- Respawn the RC if it died.
             if rc == pid then do
               rsTrace "Respawning rc"
               return $ go leaderRef Nothing
             -- The leader lost the lease
             else if ref == leaderRef then do
               rsTrace "Lost the lease"
               return $ killRC rc "lease expired" >> waitToBecomeLeader
             else
               return $ go leaderRef (Just rc)
         ]
      case maction of
        Just action -> action
        Nothing -> do
          cleanupPongs
          usend rc . RSPing =<< getSelfPid
          mpong <- expectTimeout pongTimeout
          case mpong of
            Just RSPong -> go leaderRef (Just rc)
            Nothing -> do killRC rc "RC blocked"
                          waitToBecomeLeader

    spawnRC = do
      say "RS: I'm the new leader, so starting RC ..."
      self <- getSelfPid
      rc <- spawnLocal $ (link self >> rcP >> say "RS: RC died normally")
                `catch` \e -> do say $ "RS: RC died " ++ show e
                                 liftIO $ throwM (e :: SomeException)
      _ <- monitor rc
      return rc

    killRC rc reason = do
      say $ "RS: " ++ reason ++ ", so killing RC ..."
      exit rc reason
      -- Block until RC actually dies. Otherwise, a new RC may start before
      -- the old one quits.
      receiveWait
        [ matchIf (\(ProcessMonitorNotification _ pid _) -> pid == rc)
                  (const $ return ())
        ]

    cleanupPongs = fix $ \loop -> do
      mp <- expectTimeout 0
      case mp of
        Nothing -> return ()
        Just RSPong -> loop
