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
      -- * Timer
    , Timer(..)
    , newTimer
    , timeSpecToMicro
    ) where

import HA.Logger
import HA.Replicator ( RGroup, updateStateWith, getState )

import Control.Distributed.Process
import Control.Distributed.Process.Closure ( remotable, mkClosure )
import Control.Distributed.Process.Timeout ( retry, timeout )

import Control.Exception ( SomeException, throwIO )
import Control.Monad ( when, void )
import Data.Binary ( Binary )
import Data.Int ( Int64 )
import Data.IORef ( newIORef, atomicModifyIORef )
import Data.Maybe ( isNothing )
import Data.Typeable ( Typeable )
import GHC.Generics ( Generic )
import System.Clock


rsTrace :: String -> Process ()
rsTrace = mkHalonTracer "RS"

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
                   -> Process () -- ^ the closure used to run the recovery
                                 -- coordinator.
                   -> Process ()
recoverySupervisor rg rcP = do
    rst <- retry 1000000 (getState rg)
    go (Left $ rsLeasePeriod rst) rst
    rsTrace $ "Terminated"
   `catch` \e -> do
    rsTrace $ "Dying with " ++ show e
    liftIO $ throwIO (e :: SomeException)
  where
    -- Takes the pid of the Recovery Coordinator, the remaining amount of
    -- microseconds of the current lease and the last observed state. If the pid
    -- of the RC is not available we give it the next lease period in
    -- microseconds.
    go :: Either Int (ProcessId, Int) -> RSState -> Process ()
    -- I'm the leader
    go (Right (rc, remaining)) previousState = do
      let leaseAllowance = rsLeasePeriod previousState `div` 3
      leaseTimer <- newTimer remaining $ killRC rc
      void $ receiveTimeout (max 0 (remaining - leaseAllowance)) []

      t0 <- liftIO $ getTime Monotonic
      rstNew <- rsUpdate previousState
      canceled <- cancel leaseTimer
      -- Has RC died? (either for RC internal reasons or because of the timer)
      rcDied <- rcHasDied rc
      tf <- liftIO $ getTime Monotonic
      let remaining' =
            fromIntegral (rsLeasePeriod rstNew) - timeSpecToMicro (tf - t0)
      self <- getSelfPid
      if remaining' > 0 && rsLeader rstNew == Just self then do
         -- The lease has not expired and I'm still the leader.
         rc' <- if not canceled || rcDied then
                  spawnRC
                else
                  return rc
         go (Right (rc', fromIntegral remaining')) rstNew
       else do
         -- RC has died, will be killed by the timer or someone else
         -- has taken leadership.
         when rcDied $ say "RS: lease expired"
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

      t0 <- liftIO $ getTime Monotonic
      rstNew <- rsUpdate previousState
      self <- getSelfPid
      tf <- liftIO $ getTime Monotonic
      let remaining =
            fromIntegral (rsLeasePeriod rstNew) - timeSpecToMicro (tf - t0)
      if remaining > 0 && rsLeader rstNew == Just self then do
         -- The lease has not expired and I'm the new leader.
         rc <- spawnRC
         go (Right (rc, fromIntegral remaining)) rstNew
       else do
         -- Timer has expired or I'm not the leader.
         go (Left $ rsLeasePeriod previousState) rstNew

    spawnRC = do
      say "RS: I'm the new leader, so starting RC ..."
      self <- getSelfPid
      rc <- spawnLocal $ (link self >> rcP >> say "RS: RC died normally")
                `catch` \e -> do say $ "RS: RC died " ++ show (e::SomeException)
                                 liftIO $ throwIO e
      _ <- monitor rc
      return rc

    killRC rc = do
      say "RS: lease expired, so killing RC ..."
      exit rc "quorum lost"
      -- Block until RC actually dies. Otherwise, a new RC may start before
      -- the old one quits.
      void $ monitor rc
      receiveWait
        [ matchIf (\(ProcessMonitorNotification _ pid _) -> pid == rc)
                  (const $ return ())
        ]

    -- We make the polling period slightly bigger than the lease.
    pollingPeriod = (`div` 10) . (* 11)

    -- | Updates the state proposing the current process as leader if
    -- there has not been updates since the state was last observed.
    rsUpdate rst = do
      self <- getSelfPid
      rsTrace "Competing for the lease"
      void $ timeout (pollingPeriod $ rsLeasePeriod rst) $
        updateStateWith rg $
          $(mkClosure 'setLeader) (self, rsLeaseCount rst)
      rst' <- retry (pollingPeriod $ rsLeasePeriod rst) $ do
        rsTrace "Reading the lease"
        getState rg
      rsTrace $ "Read the lease: " ++ show rst'
      return rst'

    -- | Yields @True@ iff a notification about RC death has arrived.
    rcHasDied rc = do
       mn <- expectTimeout 0
       case mn of
         Just (ProcessMonitorNotification _ pid _reason)
           | pid == rc -> return True
           | otherwise -> rcHasDied rc
         Nothing -> return False

timeSpecToMicro :: TimeSpec -> Int64
timeSpecToMicro (TimeSpec s ns) = s * 1000000 + ns `div` 1000

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
data Timer = Timer { cancel :: Process Bool }

-- | @timer <- newTimer timeout action@ performs @action@ after waiting
-- @timeout@ microseconds.
newTimer :: Int -> Process () -> Process Timer
newTimer timeoutPeriod action = do
    -- @doneRef@ is @Just canceled@ iff the timer was canceled or action ran to
    -- completion.
    doneRef <- liftIO $ newIORef Nothing
    -- Since the timer may fire arbitrarily late, we should prevent the user
    -- from canceling the action after the time period has expired. To avoid
    -- this, @cancel@ reads the clock and verifies that the timeout period has
    -- not passed.
    t0 <- liftIO $ getTime Monotonic
    pid <- spawnLocal $ do
      void $ receiveTimeout timeoutPeriod []
      done <- liftIO $ atomicModifyIORef doneRef $ \m ->
        case m of
          Nothing -> (Just False, m)
          _       -> (         m, m)
      when (isNothing done) action
    let cancelCall = mask_ $ do
          tf <- liftIO $ getTime Monotonic
          let expired = timeSpecToMicro (tf - t0) > fromIntegral timeoutPeriod
          done <- liftIO $ atomicModifyIORef doneRef $ \m ->
            case m of
              Nothing | not expired -> (Just True, m)
              _                     -> (        m, m)
          result <- if not expired && isNothing done then do
                      exit pid "Timer canceled"
                      return True
                    else
                      return $ maybe False id done
          bracket (monitor pid) unmonitor $ \ref ->
            receiveWait
              [ matchIf (\(ProcessMonitorNotification ref' _ _) -> ref == ref')
                        (const $ return ())
              ]
          return result
    return $ Timer { cancel = cancelCall }
