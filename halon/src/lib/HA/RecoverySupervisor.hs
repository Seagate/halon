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
-- the Recovery Coordinator. The Replication API will be used to coordinate
-- actions of supervisors.
--
-- The following replicated state is maintained and visible to all supervisors:
--
-- > leader :: Maybe ProcessId -- pid of the leader
-- > lease_count :: Int -- increased by the leader periodically so it reports
-- >                    -- liveness
--
-- * Monitoring the RC
--
-- If the supervisor is the leader, then it starts the RC and increments
-- periodically the @lease_count@.
--
-- If the supervisor is not the leader, it checks periodically that the
-- @lease_count@ has increased. If the @lease_count@ has not changed, it
-- proposes itself as leader.
--
-- If the leader cannot increase the lease_count it means it has lost quorum and
-- the RC must be stopped. It will continue to operate as a non-leader
-- supervisor.
--
-- The update frequency of the @lease_count@ should be higher than the polling
-- frequency so at least one update is guaranteed to happen between two
-- observations if the leader is alive.
--
-- * Leader election
--
-- Each supervisor wishing to be elected submits the following update to the
-- replicator:
--
-- > \(leader,lease_count) ->
-- >   if lease_count==last_observed_lease_count then (self,lease_count+1)
-- >    else (leader,lease_count)
--
-- The supervisor whose update is applied first is elected leader. All
-- candidates have quorum to be the leader or their updates wouldn’t be
-- accepted. The values of the free variables are provided by each particular
-- candidate.
--
-- If a candidate cannot submit an update it will continue observing the
-- @lease_count@ and trying to propose itself as leader until either the
-- @lease_count@ increases or it succeeds in being elected leader.
--

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
module HA.RecoverySupervisor
    ( -- * Implementation
      recoverySupervisor
    , RSState(..)
    , __remoteTable
    ) where

import HA.Replicator ( RGroup, updateStateWith, getState )

import Control.Distributed.Process
import Control.Distributed.Process.Closure ( remotable, mkClosure )
import Control.Distributed.Process.Timeout ( retry, timeout )

import Control.Concurrent ( newMVar, takeMVar, putMVar, readMVar, newEmptyMVar )
import Control.Monad ( when, void )
import Data.Binary ( Binary )
import Data.Time ( getCurrentTime, diffUTCTime )
import Data.Typeable ( Typeable )
import GHC.Generics ( Generic )

-- | State of the recovery supervisor
data RSState = RSState { rsLeader :: Maybe ProcessId
                       , rsLeaseCount :: LeaseCount
                       , rsLeasePeriod :: Int
                       }
  deriving (Typeable, Generic, Eq, Show)

-- | Type of lease counters
type LeaseCount = Int

instance Binary RSState

-- | @setLeader (pid,leaseCount)@ sets @pid@ as the leader
-- only if the current lease count matches @leaseCount@.
--
-- Upon setting the leader it increases the lease count.
--
setLeader :: (ProcessId,LeaseCount) -> RSState -> RSState
setLeader (candidate,previousLeaseCount) rstOld =
  if previousLeaseCount == rsLeaseCount rstOld
    then RSState (Just candidate) (previousLeaseCount+1) (rsLeasePeriod rstOld)
    else rstOld

remotable [ 'setLeader ]

-- | Runs the recovery supervisor.
recoverySupervisor :: RGroup g
                   => g RSState -- ^ the replication group used to store
                                -- the RS state
                   -> Process ProcessId
                         -- ^ the closure used to start the recovery
                         -- coordinator: It must return immediately yielding
                         -- the pid of the RC.
                   -> Process ()
recoverySupervisor rg rcP = do
    rst <- retry 1000000 (getState rg)
    go (Left $ rsLeasePeriod rst) rst
  where
    -- Takes the pid of the Recovery Coordinator and the last observed
    -- state. If the pid of the RC is not available we give it the next
    -- lease period in microseconds.
    go :: Either Int ProcessId -> RSState -> Process ()
    -- I'm the leader
    go (Right rc) previousState = do
      timer <- newTimer (rsLeasePeriod previousState) $ do
        say "RS: lease expired, so killing RC ..."
        exit rc "quorum lost"
        -- Block until RC actually dies. Otherwise, a new RC may start before
        -- the old one quits.
        void $ monitor rc
        receiveWait
            [ matchIf (\(ProcessMonitorNotification _ pid _) -> pid == rc)
                      (const $ return ())
            ]
      self <- getSelfPid
      rstNew <- rsUpdate self previousState
      canceled <- waitAndCancel timer
      -- Has RC died? (either for RC internal reasons or because of the timer)
      rcDied <- rcHasDied rc
      if not rcDied && canceled && rsLeader rstNew == Just self then
         -- RC is still alive, the timer was canceled and I'm still the leader.
         -- TODO: The check for leadership seems redundant if clock drift is
         -- bounded, which is a fundamental assumption. Should we remove the
         -- test?
         go (Right rc) rstNew
       else do
         -- RC has died, will be killed by the timer or someone else
         -- has taken leadership.
         when rcDied $ say "RS: RC died, RSs will elect a new leader"
         go (Left $ rsLeasePeriod previousState) rstNew

    -- I'm not the leader
    go (Left oldLeasePeriod) previousState = do
      -- When shortening the lease, take the longer period to avoid
      -- interrupting the next leader before its lease expires.
      let leasePeriod = max oldLeasePeriod (rsLeasePeriod previousState)
      when (Nothing /= rsLeader previousState) $
        -- Wait for the polling period if there is some known leader only.
        -- Otherwise, jump immediately to leader election.
        void $ receiveTimeout (pollingPeriod leasePeriod) []
      timer <- newTimer leasePeriod $ return ()
      self <- getSelfPid
      rstNew <- rsUpdate self previousState
      canceled <- cancel timer
      if canceled && rsLeader rstNew == Just self then do
         -- Timer has not expired and I'm the new leader.
         say "RS: I'm the new leader, so starting RC ..."
         rc <- rcP
         _ <- monitor rc
         go (Right rc) rstNew
       else do
         -- Timer has expired or I'm not the leader.
         go (Left $ rsLeasePeriod previousState) rstNew

    -- We make the polling period slightly bigger than the lease.
    pollingPeriod = (`div` 10) . (* 11)

    -- | Updates the state proposing the current process as leader if
    -- there has not been updates since the state was last observed.
    rsUpdate self rst = do
      void $ timeout (pollingPeriod $ rsLeasePeriod rst) $
        updateStateWith rg $
          $(mkClosure 'setLeader) (self,rsLeaseCount rst)
      retry (pollingPeriod $ rsLeasePeriod rst) $ getState rg

    -- | Yields @True@ iff a notification about RC death has arrived.
    rcHasDied rc = do
       mn <- expectTimeout 0
       case mn of
         Just (ProcessMonitorNotification _ pid reason)
           | pid == rc -> do say $ "RS: RC died: " ++ show reason
                             return True
           | otherwise -> rcHasDied rc
         Nothing -> return False

-- | Type of timers
--
-- If @cancel timer@ is evaluated before the timer expires, the
-- @action@ is never performed.
--
-- If @cancel timer@ is evaluated after the timer expires, the
-- @action@ is performed.
--
-- @cancel timer@ returns @False@ if the @action@ was run to completion.
-- Otherwise, it returns @True@ in which case the action will be never
-- performed.
--
-- @waitAndCancel timer@ is like @cancel timer@ but blocks until the timer
-- expires.
--
data Timer = Timer { cancel :: Process Bool, waitAndCancel :: Process Bool }

-- | @timer <- newTimer timeout action@ performs @action@ after waiting
-- @timeout@ microseconds.
newTimer :: Int -> Process a -> Process Timer
newTimer timeoutPeriod action = do
  mv <- liftIO $ newMVar Nothing -- @Nothing@ if action was canceled or not
                                 -- performed, otherwise @Just canceled@
  mdone <- liftIO newEmptyMVar   -- @()@ iff action completed or was canceled
  self <- getSelfPid
  -- Since the timer may fire arbitrarily late, we should prevent the user from
  -- canceling the action after the time period has expired. To avoid this,
  -- @cancel@ and @waitCancel@ read the clock and verify that the timeout period
  -- has not passed.
  t0 <- liftIO $ getCurrentTime
  pid <- spawnLocal $ flip finally (liftIO $ putMVar mdone ()) $ do
      link self
      void $ receiveTimeout timeoutPeriod []
      canceled <- liftIO $ takeMVar mv
      case canceled of
        Nothing -> do void $ action
                      liftIO $ putMVar mv $ Just False
        Just _ -> liftIO $ putMVar mv canceled
  let cancelCall = do
        canceled <- liftIO $ takeMVar mv
        case canceled of
          Nothing -> do
            tf <- liftIO $ getCurrentTime
            if floor (diffUTCTime tf t0 * 1000000) >= timeoutPeriod
            then liftIO $ do -- don't cancel if the timer period expired
                   putMVar mv Nothing
                   -- wait for the timer process to complete
                   readMVar mdone
                   return False
            else do exit pid "RecoverySupervisor.timer: canceled"
                    -- wait for the timer process to die
                    liftIO $ readMVar mdone
                    liftIO $ putMVar mv $ Just True
                    return True
          Just c -> do liftIO $ putMVar mv canceled
                       return c
  let waitAndCancelCall = liftIO $ do
        canceled <- takeMVar mv
        case canceled of
          Nothing -> do
            tf <- getCurrentTime
            if floor (diffUTCTime tf t0 * 1000000) >= timeoutPeriod
            then do -- don't cancel if the timer period expired
                    putMVar mv Nothing
                    -- wait for the timer process to complete
                    readMVar mdone
                    return False
            else do putMVar mv $ Just True
                    -- wait for the timer process to acknowledge
                    readMVar mdone
                    return True
          Just c -> do putMVar mv canceled
                       return c
  return $ Timer { cancel = cancelCall
                 , waitAndCancel = waitAndCancelCall
                 }
