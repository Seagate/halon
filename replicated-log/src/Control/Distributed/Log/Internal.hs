-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Replicate state machines and their logs. This module is intended to be
-- imported qualified.

{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Control.Distributed.Log.Internal
    ( replica
      -- * Operations on handles
    , Handle
    , updateHandle
    , remoteHandle
    , RemoteHandle
    , clone
      -- * Creating new log instances and operations
    , Hint(..)
    , Log(..)
    , Config(..)
    , new
    , append
    , status
    , reconfigure
    , addReplica
    , killReplica
    , removeReplica
      -- * Remote Tables
    , Control.Distributed.Log.Internal.__remoteTable
    , Control.Distributed.Log.Internal.__remoteTableDecl
    , ambassador__tdict -- XXX unused, exported to guard against warning.
      -- * Other
    , callLocal
    ) where

import Control.Distributed.Log.Messages
import Control.Distributed.Log.Policy (NominationPolicy)
import Control.Distributed.Log.Policy as Policy
    ( notThem
    , notThem__static
    , orpn
    , orpn__static
    )
import Control.Distributed.Process.Batcher
import Control.Distributed.Process.Consensus hiding (Value)
import Control.Distributed.Process.Timeout

-- Preventing uses of spawn and call because of
-- https://cloud-haskell.atlassian.net/browse/DP-104
import Control.Distributed.Process hiding (callLocal, send, spawn, call)
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Scheduler (schedulerIsEnabled)
import Control.Distributed.Process.Internal.Types
    ( LocalProcessId(..)
    , nullProcessId
    )
import Control.Distributed.Static
    (closureApply, staticApply, staticClosure)

-- Imports necessary for acid-state.
import Data.Acid as Acid
import Data.Binary (decode)
import Data.SafeCopy
import Control.Monad.State (get, put)
import Control.Monad.Reader (ask)

import Control.Applicative ((<$>))
import Control.Concurrent
import Control.Exception (SomeException, throwIO)
import Control.Exception.Enclosed (tryAny)
import Control.Monad
import Data.Constraint (Dict(..))
import Data.Int (Int64)
import Data.List (intersect, partition, sortBy)
import qualified Data.Foldable as Foldable
import Data.Function (on)
import Data.Binary (Binary, encode)
import Data.Maybe
import Data.Monoid (Monoid(..))
import qualified Data.Map as Map
import Data.Ratio (Ratio, numerator, denominator)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Prelude hiding (init, log)
import Network.Transport (EndPointAddress(..))
import System.Clock

deriving instance Typeable Eq

-- | An auxiliary type for hiding parameters of type constructors
data Some f = forall a. Some (f a) deriving (Typeable)

-- | An internal type used only by 'callLocal'.
data Done = Done
  deriving (Typeable,Generic)

instance Binary Done

-- XXX pending inclusion of a fix to callLocal upstream.
--
-- https://github.com/haskell-distributed/distributed-process/pull/180
callLocal :: Process a -> Process a
callLocal p = mask_ $ do
  mv <-liftIO $ newEmptyMVar
  self <- getSelfPid
  pid <- spawnLocal $ try p >>= liftIO . putMVar mv
                      >> when schedulerIsEnabled (usend self Done)
  when schedulerIsEnabled $ do Done <- expect; return ()
  liftIO (takeMVar mv >>= either (throwIO :: SomeException -> IO a) return)
    `onException` do
       -- Exit the worker and wait for it to terminate.
       bracket (monitor pid) unmonitor $ \ref -> do
         exit pid "callLocal was interrupted"
         receiveWait
           [ matchIf (\(ProcessMonitorNotification ref' _ _) -> ref == ref')
                     (const $ return ())
           ]

-- | Find the gaps in a partial sequence such that, if the partial sequence and
-- the gaps were sorted, the resulting list would form a contiguous sequence.
--
-- Formally:
--
-- > forall xs . xs /= []
-- >   => sort (xs ++ concat (gaps xs)) == [minimum xs .. maximum xs]
--
gaps :: (Enum a, Ord a) => [a] -> [[a]]
gaps = go
  where go [] = []
        go [_] = []
        go (x:xs@(x':_)) | gap <- [succ x..pred x']
                         , not (null gap) = gap : go xs
                         | otherwise = go xs

-- | Information about a log entry.
data Hint
      -- | Assume nothing, be pessimistic.
    = None
      -- | Executing the command has effect on replicated state, but executing
      -- multiple times has same effect as executing once.
    | Idempotent
      -- | Executing the command has no effect on replicated state, i.e.
      -- executing multiple times has same effect as executing zero or more
      -- times.
    | Nullipotent
    deriving (Eq, Ord, Show, Generic, Typeable)

instance Monoid Hint where
    mempty = None
    mappend = min

instance Binary Hint

data Log a = forall s ref. Serializable ref => Log
    { -- | Yields the initial value of the log.
      logInitialize :: Process s

      -- | Yields the list of references of available snapshots.
      -- Each reference is accompanied with the 'DecreeId' of the next log entry
      -- to execute.
      --
      -- On each node this function could return different results.
      --
    , logGetAvailableSnapshots :: Process [(DecreeId, ref)]

      -- | Yields the snapshot identified by ref.
      --
      -- If the snapshot cannot be retrieved an exception is thrown.
      --
      -- After a succesful call, the snapshot returned or a newer snapshot must
      -- appear listed by @logGetAvailableSnapshots@.
      --
    , logRestore :: ref -> Process s

      -- | Writes a snapshot together with the 'DecreeId' of the next log index.
      --
      -- Returns a reference which any replica can use to get the snapshot
      -- with 'logRestore'.
      --
      -- After a succesful call, the dumped snapshot or a newer snapshot must
      -- appear listed in @logGetAvailableSnapshots@.
      --
    , logDump :: DecreeId -> s -> Process ref

      -- | State transition callback.
    , logNextState      :: s -> a -> Process s
    } deriving (Typeable)

data Config = Config
    { -- The name of this log
      logName :: String

      -- | The consensus protocol to use.
    , consensusProtocol :: forall a. SerializableDict a -> Protocol NodeId a

      -- | For any given node, the directory in which to store persistent state.
    , persistDirectory  :: NodeId -> FilePath

      -- | The length of time before leases time out, in microseconds.
    , leaseTimeout      :: Int

      -- | The length of time before a leader should seek lease renewal, in
      -- microseconds. To avoid leader churn, you should ensure that
      -- @leaseRenewTimeout <= leaseTimeout@.
    , leaseRenewTimeout :: Int

      -- | Scale the lease by this factor in non-leaders to protect against
      -- clock drift. This value /must/ be greater than 1.
    , driftSafetyFactor :: Ratio Int64

      -- | Takes the amount of executed entries since last snapshot.
      -- Returns true whenever a snapshot of the state should be saved.
    , snapshotPolicy :: Int -> Process Bool

      -- | This is the amount of microseconds a replica will wait for a snapshot
      -- to load before giving up.
    , snapshotRestoreTimeout :: Int
    } deriving (Typeable)

-- | The type of decree values. Some decrees are control decrees, that
-- reconfigure the group. Note that stopping a group completely can be done by
-- reconfiguring to the null membership list. And reconfiguring with the same
-- membership list encodes a no-op.
data Value a
      -- | Batch of values.
    = Values [a]
      -- | Lease start time and list of replicas.
    | Reconf TimeSpec [NodeId]
    deriving (Eq, Generic, Typeable)

instance Binary a => Binary (Value a)

instance Serializable a => SafeCopy (Value a) where
    getCopy = contain $ fmap decode $ safeGet
    putCopy = contain . safePut . encode

isReconf :: Value a -> Bool
isReconf (Reconf _ _) = True
isReconf _            = False

-- | A type for internal requests.
data Request a = Request
    { requestSender   :: [ProcessId]
    , requestValue    :: Value a
    , requestHint     :: Hint
      -- | @Just d@ signals a lease request, where @d@ is the decree on which
      -- the request is valid.
      --
      -- Any reconfiguration executed in a future decree before the lease
      -- request is executed invalidates the request.
      --
      -- If a lease request is submitted while a Reconf message produced by a
      -- client is sitting in the mailbox, the effects of the client
      -- reconfiguration could be overwritten by the lease request. In order to
      -- prevent this, the @requestForLease@ field helps discarding lease
      -- requests which have become dated.
      --
    , requestForLease :: Maybe LegislatureId
    }
  deriving (Generic, Typeable)

instance Binary a => Binary (Request a)

-- | A type for batcher messages.
data BatcherMsg a = BatcherMsg
    { batcherMsgAmbassador :: ProcessId
    , batcherMsgEpoch      :: LegislatureId
    , batcherMsgRequest    :: Request a
    }
  deriving (Generic, Typeable)

instance Binary a => Binary (BatcherMsg a)

-- | Ask a replica to print status and send Max messages.
data Status = Status deriving (Typeable, Generic)
instance Binary Status

instance Binary TimeSpec

data TimerMessage = LeaseRenewalTime
  deriving (Generic, Typeable)

instance Binary TimerMessage

replicaLabel :: String -> String
replicaLabel = (++ ".replica")

acceptorLabel :: String -> String
acceptorLabel = (++ ".acceptor")

sendReplica :: Serializable a => String -> NodeId -> a -> Process ()
sendReplica name nid = nsendRemote nid $ replicaLabel name

sendAcceptor :: Serializable a => String -> NodeId -> a -> Process ()
sendAcceptor name nid = nsendRemote nid $ acceptorLabel name

queryMissingFrom :: String
                 -> Int      -- ^ next decree to execute
                 -> [NodeId] -- ^ replicas to query
                 -> Map.Map Int (Value a) -- ^ log
                 -> Process ()
queryMissingFrom name w replicas log = do
    let pw = pred w
        ns = concat $ gaps $ (pw:) $ Map.keys $ snd $ Map.split pw log
    self <- getSelfPid
    forM_ ns $ \n -> do
        forM_ replicas $ \ρ -> do
            sendReplica name ρ $ Query self n

-- | Stores acceptors, replicas, their 'LegislatureId', the epoch and the log.
--
-- See Note [Epochs].
--
-- At all times the latest membership of the log can be recovered by
-- executing the reconfiguration decrees in modern history. See Note
-- [Trimming the log].
data Memory a = Memory [NodeId]
                       LegislatureId
                       LegislatureId
                       (Map.Map Int a)
  deriving Typeable

$(deriveSafeCopy 0 'base ''Memory)
$(deriveSafeCopy 0 'base ''NodeId)
$(deriveSafeCopy 0 'base ''LocalProcessId)
$(deriveSafeCopy 0 'base ''EndPointAddress)
$(deriveSafeCopy 0 'base ''LegislatureId)

memoryInsert :: Int -> a -> Update (Memory a) ()
memoryInsert n v = do
    Memory replicas leg epoch log <- get
    put $ Memory replicas leg epoch (Map.insert n v log)

memoryGet :: Acid.Query (Memory a)
                        ( [NodeId]
                        , LegislatureId
                        , LegislatureId
                        , Map.Map Int a
                        )
memoryGet = do
    Memory replicas leg epoch log <- ask
    return (replicas, leg, epoch, log)

-- | Removes all entries below the given watermark from the log.
memoryTrim :: [NodeId]
           -> LegislatureId
           -> LegislatureId
           -> Int
           -> Update (Memory a) ()
memoryTrim replicas leg epoch w = do
    Memory _ _ _ log <- get
    put $ Memory replicas leg epoch $ snd $ Map.split (pred $ w) log

$(makeAcidic ''Memory ['memoryInsert, 'memoryGet, 'memoryTrim])

-- | Removes all entries below the given index from the log.
--
-- See note [Trimming the log]
trimTheLog :: Serializable a
           => AcidState (Memory (Value a))
           -> FilePath      -- ^ Directory for persistence
           -> [NodeId]   -- ^ Acceptors
           -> LegislatureId -- ^ 'LegislatureId' of given membership
           -> LegislatureId -- ^ Epoch of the given membership
           -> Int           -- ^ Log index
           -> IO ()
trimTheLog acid _persistDir ρs leg epoch w0 = do
    update acid $ MemoryTrim ρs leg epoch w0
    -- TODO: fix checkpoints in acid-state.
    -- "log-size-remains-bounded" and "durability" were failing because
    -- acid-state would complain that the checkpoint file is missing.
    --
    -- createCheckpoint acid
    -- This call collects all acid data needed to reconstruct states prior to
    -- the last checkpoint.
    -- Acid.createArchive acid
    -- And this call removes the collected state.
    -- removeDirectoryRecursive $ persistDir </> "Archive"

-- | Small view function for extracting a specialized 'Protocol'. Used in 'replica'.
unpackConfigProtocol :: Serializable a => Config -> (Config, Protocol NodeId (Value a))
unpackConfigProtocol Config{..} = (Config{..}, consensusProtocol SerializableDict)

-- | The internal state of a replica.
data ReplicaState s ref a = Serializable ref => ReplicaState
  { -- | The pid of the proposer process.
    stateProposerPid       :: ProcessId
    -- | The pid of the timer process.
  , stateTimerPid          :: ProcessId
    -- | Handle to persist the log.
  , stateAcidHandle        :: AcidState (Memory (Value a))
    -- | The time at which the last lease started.
  , stateLeaseStart        :: TimeSpec
    -- | The list of node ids of the replicas.
  , stateReplicas          :: [NodeId]
    -- | This is the decree identifier of the next proposal to confirm. All
    -- previous decrees are known to have passed consensus.
  , stateUnconfirmedDecree :: DecreeId
    -- | This is the decree identifier of the next proposal to do.
    --
    -- For now, it must never be an unreachable decree (i.e. a decree beyond the
    -- reconfiguration decree that changes to a new legislature) or any
    -- proposal using the decree identifier will never be acknowledged or
    -- executed.
    --
    -- Invariant: @stateUnconfirmedDecree <= stateCurrentDecree@
    --
  , stateCurrentDecree     :: DecreeId
    -- | The reference to the last snapshot saved.
  , stateSnapshotRef       :: Maybe ref
    -- | The watermark of the lastest snapshot
    --
    -- See note [Trimming the log].
  , stateSnapshotWatermark :: DecreeId
    -- | The identifier of the next decree to execute.
  , stateWatermark         :: DecreeId
    -- | The state yielded by the last executed decree.
  , stateLogState          :: s
    -- | The LegislatureId where the leader became the leader
    -- See Note [Epochs].
  , stateEpoch             :: LegislatureId
    -- | Batcher of client requests
  , stateBatcher           :: ProcessId

  -- from Log {..}
  , stateLogRestore        :: ref -> Process s
  , stateLogDump           :: DecreeId -> s -> Process ref
  , stateLogNextState      :: s -> a -> Process s

  } deriving (Typeable)

-- Note [Trimming the log]
-- ~~~~~~~~~~~~~~~~~~~~~~~
--
-- We trim the log whenever a snapshot is made. We don't trim, however, all
-- entries below the snapshot watermark.
--
-- Each replica has an ancient history, a medieval history and a modern history.
--
-- Modern history starts on the watermark of the last snapshot and reaches to
-- present. Medieval history starts on the watermark of the second-to-last
-- snapshot. And ancient history is all of te earliest period.
--
-- At all times, the log includes medieval and modern history. Thus, whenever
-- we make a snapshot, we trim medieval history and modern history becomes
-- medieval.
--
-- Medieval history is not necessary from the local standpoint. But if we
-- trimmed medieval history, the replica wouldn't be able to answer queries
-- about relatively recent decrees when modern history has just started (i.e.
-- immediately after making a snapshot).

-- Note [Teleportation]
-- ~~~~~~~~~~~~~~~~~~~~
--
-- A decree in legislature @l@ is "reachable" if all decrees before it are
-- known, and the last reconfiguration decree opens a legislature @l'@ such that
-- @l' <= l@.
--
-- All decrees known to be reachable inhabit all legislatures. That is, they are
-- independent of any legislature. We are therefore free to ascribe an arbitrary
-- legislature to any reachable decree. Doing so is called "teleporation". For
-- reachability to be closed under teleportation, we must teleport to
-- legislatures greater than or equal to @l@. When the original legislature of
-- a reachable decree is unknown, we use 'maxBound'.
--
-- Currently the logic deciding whether to apply a Reconf decree and how to
-- update the current decree id after a Reconf assumes that teleportation always
-- uses maxBound. This is wrong and should be fixed, but for now this is an
-- additional constraint on teleportation.
-- https://app.asana.com/0/12314345447678/16427250405254

-- Note [Epochs]
-- ~~~~~~~~~~~~~
--
-- When a client abandons a request by sending a new one before receiving the
-- acknowledgement, the implementation guarantees that the abandoned request
-- won't be served after the new request.
--
-- For this sake, the term of each leader replica is called an epoch, and it is
-- identified with the `LegislatureId` of the legislature where the replica
-- became a leader.
--
-- Each client sends the requests accompanied by the last known epoch. The
-- leader replica, discards the requests which do not belong to the current
-- epoch. For the leader, there is no way to know if a request from a previous
-- epoch has been abandoned or not.

-- | One replica of the log. All incoming values to add to the log are submitted
-- for consensus. A replica does not acknowledge values being appended to the
-- log until the replicas have reached consensus about the update, hence reached
-- sufficient levels of durability and fault tolerance according to what the
-- consensus protocol in use permits.
--
-- The 'logNextState' state transition callback is invoked sometime thereafter
-- to transition the state machine associated with the replica to the next
-- state. All replicas see the values in the log in the same order, so that the
-- state machine at each replica makes the same transitions in the same order.
--
-- A replica may be lagging because it missed a consensus event. So replicas can
-- query other replicas for the value of any log entry. But the query messages
-- can themselves sometimes get lost. So replicas regularly advertize the
-- highest entry number in their log. This is a convenient way to get replicas
-- to retry queries without blocking and/or keeping any extra state around about
-- still pending queries.
replica :: forall a. Dict (Eq a)
        -> SerializableDict a
        -> Config
        -> Log a
        -> TimeSpec
        -> DecreeId
        -> LegislatureId
        -> [NodeId]
        -> Process ()
replica Dict
        SerializableDict
        (unpackConfigProtocol -> (Config{..}, Protocol{prl_propose}))
        (Log {..})
        leaseStart0
        decree
        epoch0
        replicas0 = do
   say $ "New replica started in " ++ show (decreeLegislatureId decree)

   self <- getSelfPid
   here <- getSelfNode
   let leg0 = decreeLegislatureId decree
   bracket (liftIO $ openLocalStateFrom (persistDirectory here)
                                        (Memory replicas0 leg0 epoch0 Map.empty)
           )
           (liftIO . closeAcidState)
           $ \acid -> do
    sns <- logGetAvailableSnapshots
    -- Try the snapshots from the most recent to the less recent.
    let findSnapshot []               = (DecreeId 0 0,) <$> logInitialize
        findSnapshot ((w0, ref) : xs) = restoreSnapshot (logRestore ref) >>=
                                        maybe (findSnapshot xs) (return . (w0,))
    (w0, s) <- findSnapshot $ sortBy (flip compare `on` fst) sns

    -- Replay backlog if any.
    (replicas', leg', epoch', log) <-
      liftIO $ Acid.query acid MemoryGet
    say $ "Log size of replica: " ++ show (Map.size log)
    -- We have a membership list comming from the function parameters
    -- and a membership list comming from disk.
    --
    -- We adopt the membership list with the highest legislature.
    let replicas  = if leg0 >= leg' then replicas0 else replicas'
        epoch     = if leg0 >= leg' then epoch0 else epoch'
        leg       = max leg0 leg'

    -- Teleport all decrees to the highest possible legislature, since all
    -- recorded decrees must be replayed. This has no effect on the current
    -- decree number and the watermark. See Note [Teleportation].
    forM_ (Map.toList log) $ \(n,v) -> do
        usend self $ Decree Stored (DecreeId maxBound n) v

    let d = DecreeId leg (max (decreeNumber decree) $
                            if Map.null log
                              then decreeNumber w0
                              else succ $ fst $ Map.findMax log
                         )
        others = filter (/= here) replicas
    queryMissingFrom logName (decreeNumber w0) others $
        Map.insert (decreeNumber d) undefined log

    timerPid <- spawnLocal $ link self >> timer
    leaseStart0' <- setLeaseTimer timerPid leaseStart0 replicas
    bpid <- spawnLocal $ link self >> batcher (sendBatch self)
    ppid <- spawnLocal $ link self >> proposer self bpid Bottom replicas

    go ReplicaState
         { stateProposerPid = ppid
         , stateTimerPid = timerPid
         , stateAcidHandle = acid
         , stateLeaseStart = leaseStart0'
         , stateReplicas = replicas
         , stateUnconfirmedDecree = d
         , stateCurrentDecree = d
         , stateSnapshotRef   = Nothing
         , stateSnapshotWatermark = w0
         , stateWatermark = w0
         , stateLogState = s
         , stateEpoch    = epoch
         , stateBatcher  = bpid
         , stateLogRestore = logRestore
         , stateLogDump = logDump
         , stateLogNextState = logNextState
         }
  where
    -- Restores a snapshot with the given operation and returns @Nothing@ if an
    -- exception is thrown or if the operation times-out.
    restoreSnapshot :: Process s -> Process (Maybe s)
    restoreSnapshot restore =
       mask_ (tryAny $ timeout snapshotRestoreTimeout restore) >>= \case
         Left  _  -> return Nothing
         Right ms -> return ms

    sendBatch :: ProcessId
              -> [(ProcessId, LegislatureId, Request a)]
              -> Process ()
    sendBatch ρ rs = do
      let (nps, other0) =
            partition ((Nullipotent ==) . requestHint . batcherMsgRequest) $
            map (\(a, e, r) -> BatcherMsg a e r) rs
          (rcfgs, other) =
            partition (isReconf . requestValue . batcherMsgRequest) other0
      -- Submit the last configuration request in the batch.
      unless (null rcfgs) $ do
        usend ρ [last rcfgs]
        expect
      -- Submit the non-nullipotent requests.
      unless (null other) $ do
        usend ρ other
        expect
      -- Send nullipotent requests after all other batched requests.
      unless (null nps) $ do
        usend ρ nps
        expect

    adjustForDrift :: Int -> Int
    adjustForDrift t = fromIntegral $
      -- Perform multiplication in Int64 arithmetic to reduce the chance
      -- of an overflow.
      fromIntegral t * numerator   driftSafetyFactor
      `div` denominator driftSafetyFactor

    -- Sets the timer to renew or request the lease and returns the time at
    -- which the lease is started.
    setLeaseTimer :: ProcessId     -- ^ pid of the timer process
                  -> TimeSpec      -- ^ time at which the request was submitted
                  -> [NodeId]   -- ^ replicas
                  -> Process TimeSpec
    setLeaseTimer timerPid requestStart ρs = do
      -- If I'm the leader, the lease starts at the time
      -- the request was made. Otherwise, it starts now.
      self <- getSelfPid
      here <- getSelfNode
      now <- liftIO $ getTime Monotonic
      let timeSpecToMicro (TimeSpec s ns) = s * 1000000 + ns `div` 1000
          (leaseStart', t) =
             if [here] == take 1 ρs then
               ( requestStart
               , max 0 $ (leaseTimeout - leaseRenewTimeout) -
                         fromIntegral (timeSpecToMicro $ now - requestStart)
               )
             -- Adjust the lease timeout to account for some clock drift, so
             -- non-leaders think the lease is slightly longer.
             else (now, adjustForDrift leaseTimeout)

      usend timerPid (self, t, LeaseRenewalTime)
      return leaseStart'

    -- A timer process. When receiving @(pid, t, msg)@, the process waits for
    -- @t@ microsenconds and then it sends @msg@ to @pid@.
    --
    -- If while waiting, another @(pid', t', msg')@ value is received, the
    -- wait resumes with the new parameters.
    --
    timer :: Process ()
    timer = expect >>= wait
      where
        wait :: (ProcessId, Int, TimerMessage) -> Process ()
        wait (sender, t, msg) =
          expectTimeout t >>= maybe (usend sender msg >> timer) wait

    -- The proposer process makes consensus proposals.
    -- Proposals are aborted when a reconfiguration occurs.
    proposer ρ bpid s αs =
      receiveWait
        [ match $ \r@(d , request@(Request {requestValue = v :: Value a})) -> do
            self <- getSelfPid
            -- The MVar stores the result of the proposal.
            -- With an MVar we can ensure that:
            --  * when we abort the proposal, the result is not communicated;
            --  * when the result is communicated, the proposal is not aborted.
            -- If both things could happen simultaneously, we would need to
            -- write the code to handle that case.
            mv <- liftIO newEmptyMVar
            pid <- spawnLocal $ do
                     link self
                     result <- runPropose'
                                 (prl_propose (sendAcceptor logName) αs d v) s
                     liftIO $ putMVar mv result
                     usend self ()
            let -- After this call the mailbox is guaranteed to be free of @()@
                -- notifications from the worker.
                --
                -- Returns true if the worker was blocked.
                clearNotifications = do
                  -- block proposal
                  blocked <- liftIO $ tryPutMVar mv undefined
                  -- consume the final () if not blocked
                  when (not blocked) expect
                  return blocked
            (αs', r', blocked) <- receiveWait
                      [ match $ \() -> return (αs, r, False)
                      , match $ \αs' -> do
                          -- reconfiguration of the proposer
                          (,,) αs' r <$> clearNotifications
                      , match $ \r' -> do
                          -- Let the batcher know of the aborted request.
                          when (isNothing $ requestForLease request) $
                            usend bpid ()
                          -- a new request intended to replace the current one
                          (,,) αs r' <$> clearNotifications
                      ]
            if blocked then do
              exit pid "proposer reconfiguration"
              -- If the leader loses the lease, resending the request will cause
              -- the proposer to compete with replicas trying to acquire the
              -- lease.
              --
              -- TODO: Consider if there is a way to avoid competition of
              -- proposers here.
              usend self r'
              proposer ρ bpid s αs'
            else do
              (v',s') <- liftIO $ takeMVar mv
              usend ρ (d, v', request)
              proposer ρ bpid s' αs'

        , match $ proposer ρ bpid s
        ]

    go :: ReplicaState s ref a -> Process b
    go st@(ReplicaState ppid timerPid acid leaseStart ρs d cd msref w0 w s
                        epoch bpid stLogRestore stLogDump stLogNextState
          ) =
     do
        self <- getSelfPid
        here <- getSelfNode
        (_, _, _, log) <- liftIO $ Acid.query acid MemoryGet
        let others = filter (/= here) ρs

            -- Returns the leader if the lease has not expired.
            getLeader :: IO (Maybe NodeId)
            getLeader = do
              now <- getTime Monotonic
              -- Adjust the period to account for some clock drift, so
              -- non-leaders think the lease is slightly longer.
              let adjustedPeriod = if here == head ρs
                    then leaseTimeout
                    else adjustForDrift leaseTimeout
              if not (null ρs) &&
                now - leaseStart < fromInteger (toInteger adjustedPeriod * 1000)
              then return $ Just $ head ρs
              else return Nothing

            -- | Makes a lease request. It takes the legislature on which the
            -- request is valid.
            mkLeaseRequest :: LegislatureId -> [ProcessId] -> [NodeId]
                           -> Process (Request a)
            mkLeaseRequest l senders replicas = do
              now <- liftIO $ getTime Monotonic
              let ρs' = here : filter (here /=) replicas
              return Request
                { requestSender   = senders
                , requestValue    = Reconf now ρs' :: Value a
                , requestHint     = None
                , requestForLease = Just l
                }

        receiveWait
            [ -- The lease is about to expire, so try to renew it.
              matchIf (\_ -> w == cd) $ -- The log is up-to-date and fully
                                        -- executed.
                       \LeaseRenewalTime -> do
                  mLeader <- liftIO $ getLeader
                  cd' <- if maybe True (== here) mLeader then do
                      leaseRequest <-
                        mkLeaseRequest (decreeLegislatureId d) [] ρs
                      usend ppid (cd, leaseRequest)
                      return $ succ cd
                    else
                      return cd
                  usend timerPid (self, leaseTimeout, LeaseRenewalTime)
                  go st{ stateCurrentDecree = cd' }

            , matchIf (\(Decree _ dᵢ _ :: Decree (Value a)) ->
                        -- Take the max of the watermark legislature and the
                        -- incoming legislature to deal with teleportation of
                        -- decrees. See Note [Teleportation].
                        dᵢ < max w w{decreeLegislatureId = decreeLegislatureId dᵢ}) $
                       \_ -> do
                  -- We must already know this decree, or this decree is from an
                  -- old legislature, so skip it.
                  go st

              -- Commit the decree to the log.
            , matchIf (\(Decree locale dᵢ _) ->
                        locale /= Stored && w <= dᵢ && decreeNumber dᵢ == decreeNumber w) $
                       \(Decree locale dᵢ v) -> do
                  _ <- liftIO $ Acid.update acid $
                           MemoryInsert (decreeNumber dᵢ) (v :: Value a)
                  case locale of
                      -- Ack back to the client.
                      Local κs -> forM_ κs $ flip usend ()
                      _ -> return ()
                  usend self $ Decree Stored dᵢ v
                  go st

              -- Execute the decree
            , matchIf (\(Decree locale dᵢ _) ->
                        locale == Stored && w <= dᵢ && decreeNumber dᵢ == decreeNumber w) $
                       \(Decree _ dᵢ v) -> do
                let maybeTakeSnapshot w' s' = do
                      takeSnapshot <- snapshotPolicy
                                        (decreeNumber w' - decreeNumber w0)
                      if takeSnapshot then do
                        say $ "Log size when trimming: " ++ show (Map.size log)
                        -- First trim the log and only then save the snapshot.
                        -- This guarantees that if later operation fails the
                        -- latest membership can still be recovered from disk.
                        liftIO $ trimTheLog
                          acid (persistDirectory (processNodeId self)) ρs
                          (decreeLegislatureId d) epoch (decreeNumber w0)
                        sref' <- stLogDump w' s'
                        return (w', Just sref')
                      else
                        return (w0, msref)
                case v of
                  Values xs -> do
                      s' <- foldM stLogNextState s xs
                      let d'  = max d w'
                          cd' = max cd w'
                          w'  = succ w
                      (w0', msref') <- maybeTakeSnapshot w' s'
                      go st{ stateUnconfirmedDecree = d'
                           , stateCurrentDecree     = cd'
                           , stateSnapshotRef       = msref'
                           , stateSnapshotWatermark = w0'
                           , stateWatermark         = w'
                           , stateLogState          = s'
                           }
                  Reconf requestStart ρs'
                    -- Only execute a reconfiguration if we are on an earlier
                    -- configuration.
                    | decreeLegislatureId d <= decreeLegislatureId w -> do
                      let d' = w' { decreeNumber = max (decreeNumber d) (decreeNumber w') }
                          cd' = w' { decreeNumber = max (decreeNumber cd) (decreeNumber w') }
                          w' = succ w{decreeLegislatureId = succ (decreeLegislatureId w)}

                      -- Update the list of acceptors of the proposer...
                      usend ppid ρs'

                      (w0', msref') <- maybeTakeSnapshot w' s

                      -- Tick.
                      usend self Status

                      leaseStart' <- setLeaseTimer timerPid requestStart ρs'
                      let epoch' = if take 1 ρs' /= take 1 ρs
                                     then decreeLegislatureId d'
                                     else epoch

                      go st{ stateLeaseStart = leaseStart'
                           , stateReplicas = ρs'
                           , stateUnconfirmedDecree = d'
                           , stateCurrentDecree = cd'
                           , stateEpoch = epoch'
                           , stateSnapshotRef       = msref'
                           , stateSnapshotWatermark = w0'
                           , stateWatermark = w'
                           }
                    | otherwise -> do
                      let w' = succ w{decreeLegislatureId = succ (decreeLegislatureId w)}
                      say $ "Not executing " ++ show dᵢ
                      (w0', msref') <- maybeTakeSnapshot w' s
                      go st{ stateSnapshotRef       = msref'
                           , stateSnapshotWatermark = w0'
                           , stateWatermark = w'
                           }

              -- If we get here, it's because there's a gap in the decrees we
              -- have received so far. Compute the gaps and ask the other
              -- replicas about how to fill them up.
            , matchIf (\(Decree locale dᵢ _) ->
                        locale == Remote && w < dᵢ && not (Map.member (decreeNumber dᵢ) log)) $
                       \(Decree locale dᵢ v) -> do
                  _ <- liftIO $ Acid.update acid $ MemoryInsert (decreeNumber dᵢ) v
                  (_, _, _, log') <- liftIO $ Acid.query acid MemoryGet
                  queryMissingFrom logName (decreeNumber w) others log'
                  --- XXX set cd to @max cd (succ dᵢ)@?
                  --
                  -- Probably not, because then the replica might never find the
                  -- values of decrees which are known to a quorum of acceptors
                  -- but unknown to all online replicas.
                  --
                  --- XXX set d to @min cd (succ dᵢ)@?
                  --
                  -- This Decree could have been teleported. So, we shouldn't
                  -- trust dᵢ, unless @decreeLegislatureId dᵢ < maxBound@.
                  usend self $ Decree locale dᵢ v
                  go st

              -- Lease requests.
            , matchIf (\r -> cd == w     -- The log is up-to-date and fully
                                         -- executed.
                        && isJust (requestForLease r) -- This is a lease request.
                      ) $
                       \(request :: Request a) -> do
                  cd' <- case requestForLease request of
                    -- Discard the lease request if it corresponds to an old
                    -- legislature.
                    Just l | l < decreeLegislatureId d -> return cd
                    -- Send to the proposer otherwise.
                    _ -> do
                      usend ppid (cd, request)
                      return $ succ cd
                  go st{ stateCurrentDecree = cd' }

              -- Client requests.
            , match $ \request@(μ, e, _ :: Request a) -> do
                  mLeader <- liftIO getLeader
                  if epoch <= e && mLeader == Just here then do
                    usend bpid request
                  else when (e < epoch) $
                         usend μ (epoch, ρs)
                  go st

              -- Message from the batcher
              --
              -- XXX The guard avoids proposing values for unreachable decrees.
            , matchIf (\_ -> cd == w) $ \(rs :: [BatcherMsg a]) -> do
                  mLeader <- liftIO getLeader
                  (s', cd') <- case mLeader of
                     -- Drop the request and ask for the lease.
                     Nothing -> do
                       leaseRequest <-
                         mkLeaseRequest (decreeLegislatureId d) [] ρs
                       usend ppid (cd, leaseRequest)
                       -- Notify the batcher.
                       usend bpid ()
                       return (s, succ cd)

                     -- Drop the request.
                     Just leader | here /= leader -> do
                       -- Notify the batcher.
                       usend bpid ()
                       -- Notify the ambassadors.
                       forM_ (map batcherMsgAmbassador rs) $
                         flip usend (epoch, ρs)
                       return (s, cd)

                     -- I'm the leader, so handle the request.
                     _ -> do
                       let values (Values xs) = xs
                           values _           = []
                       if all
                            ((Nullipotent ==) . requestHint . batcherMsgRequest)
                            rs
                       then do
                         -- Serve nullipotent requests from the local state.
                         s' <- foldM stLogNextState s $
                                 concatMap
                                   (values . requestValue . batcherMsgRequest)
                                   rs
                         -- Notify the batcher.
                         usend bpid ()
                         -- Notify the clients.
                         forM_ (concatMap
                                  (requestSender . batcherMsgRequest) rs
                               ) $
                           flip usend ()
                         return (s', cd)
                       else do
                         let (rs', old) =
                               partition ((epoch <=) . batcherMsgEpoch) rs
                         -- Notify the ambassadors of old requests.
                         forM_ (map batcherMsgAmbassador old) $
                           flip usend (epoch, ρs)
                         case rs' of
                           -- Notify the batcher.
                           [] -> do usend bpid ()
                                    return (s, cd)
                           BatcherMsg { batcherMsgRequest = r } : _ -> do
                             usend ppid
                               ( cd
                               , if isReconf $ requestValue r then r
                                 else Request
                                   { requestSender =
                                       concatMap
                                         (requestSender . batcherMsgRequest) rs'
                                   , requestValue  =
                                       Values $ concatMap
                                         ( values
                                         . requestValue
                                         . batcherMsgRequest
                                         )
                                         rs'
                                   , requestHint     = None
                                   , requestForLease = Nothing
                                   }
                               )
                             return (s, succ cd)
                  go st{ stateCurrentDecree = cd', stateLogState = s' }

              -- Message from the proposer process
              --
              -- The request is dropped if the decree was accepted with a
              -- different value already.
            , match $
                  \(dᵢ, vᵢ, Request κs (v :: Value a) _ rLease) -> do
                  -- If the passed decree accepted other value than our
                  -- client's, don't treat it as local (ie. do not report back
                  -- to the client yet).
                  let κs' | isNothing rLease = bpid : κs
                          | otherwise        = κs
                      locale = if v == vᵢ then Local κs' else Remote
                  usend self $ Decree locale dᵢ vᵢ
                  forM_ others $ \ρ -> do
                      sendReplica logName ρ $ Decree Remote dᵢ vᵢ

                  when (v /= vᵢ && isNothing rLease) $
                    -- Send rejection ack.
                    usend bpid ()

                  let d' = max d (succ dᵢ)
                  go st{ stateUnconfirmedDecree = d' }

              -- Try to service a query if the requested decree is not too old.
            , matchIf (\(Query _ n) -> fst (Map.findMin log) <= n) $
                       \(Query ρ n) -> do
                  case Map.lookup n log of
                            -- See Note [Teleportation].
                    Just v -> usend ρ $ Decree Remote (DecreeId maxBound n) v
                    Nothing -> return ()
                  go st

              -- The decree of the query is old-enough.
            , match $ \(Query ρ n) -> do
                  case msref of
                    Just sref -> usend ρ $
                      SnapshotInfo ρs (decreeLegislatureId d) epoch sref w0 n
                    Nothing   -> return ()
                  go st

              -- Get the state from another replica if it is newer than ours
              -- and the original query has not been satisfied.
              --
              -- It does not quite eliminate the chance of multiple snapshots
              -- being read in cascade, but it makes it less likely.
            , match $ \(SnapshotInfo ρs' leg' epoch' sref' w0' n) ->
                  if not (Map.member n log) && decreeNumber w <= n &&
                     decreeNumber w < decreeNumber w0' then do

                    let leg  = decreeLegislatureId d
                        leg'' = max leg leg'
                        epoch'' = if leg' >= leg then epoch' else epoch
                        ρs'' = if leg' >= leg then ρs' else ρs
                    -- Trimming here ensures that the log does not accumulate
                    -- decrees indefinitely if the state is oftenly restored
                    -- before saving a snapshot.
                    liftIO $ trimTheLog
                      acid (persistDirectory (processNodeId self)) ρs''
                      leg'' epoch'' (decreeNumber w0)

                    when (leg < leg') $ usend ppid ρs'

                    leaseStart' <- if leg < leg'
                                   then setLeaseTimer timerPid 0 ρs'
                                   else return leaseStart

                    -- TODO: get the snapshot asynchronously
                    st' <- restoreSnapshot (stLogRestore sref') >>= \case
                             Nothing -> return st
                             Just s' -> return st
                                         { stateSnapshotRef       = Just sref'
                                         , stateWatermark         = w0'
                                         , stateSnapshotWatermark = w0'
                                         , stateLogState          = s'
                                         }
                    let d'  = DecreeId leg'' (max (decreeNumber w0')
                                                  (decreeNumber d))
                        cd' = DecreeId leg'' (max (decreeNumber w0')
                                                  (decreeNumber cd))
                    go st' { stateLeaseStart        = leaseStart'
                           , stateReplicas          = ρs''
                           , stateUnconfirmedDecree = d'
                           , stateCurrentDecree     = cd'
                           , stateEpoch             = epoch''
                           }
                  else go st

              -- Upon getting the max decree of another replica, compute the
              -- gaps and query for those.
            , matchIf (\(Max _ d' _ _) -> decreeNumber d < decreeNumber d') $
                       \(Max ρ d' epoch' ρs') -> do
                  say $ "Got Max " ++ show d'
                  usend ppid ρs'
                  queryMissingFrom logName (decreeNumber w) [processNodeId ρ] $
                    Map.insert (decreeNumber d') undefined log

                  let leg  = decreeLegislatureId d
                      leg' = decreeLegislatureId d'
                      leg'' = max leg leg'
                      epoch'' = if leg < leg' then epoch' else epoch
                      ρs'' = if leg < leg' then ρs' else ρs
                      d'' = DecreeId leg'' $ decreeNumber d'
                  when (leg < leg') $ usend ppid ρs'

                  leaseStart' <- if leg < leg'
                                 then setLeaseTimer timerPid 0 ρs'
                                 else return leaseStart

                  let cd' = max d'' cd
                  go st
                    { stateLeaseStart = leaseStart'
                    , stateUnconfirmedDecree = d''
                    , stateCurrentDecree = cd'
                    , stateReplicas = ρs''
                    , stateEpoch = epoch''
                    }

              -- Ignore max decree if it is lower than the current decree.
            , matchIf (\_ -> otherwise) $ \(_ :: Max) -> do
                  go st

              -- Replicas are going to join or leave the group.
            , matchIf (\(_, e, _) -> epoch <= e) $
                       \(μ, _, Helo π cpolicy) -> do

                  policy <- unClosure cpolicy
                  let ρs' = policy ρs
                      -- Place the proposer at the head of the list
                      -- of replicas to be considered as future leader.
                      ρs'' = here : filter (/= here) ρs'

                  mLeader <- liftIO $ getLeader
                  case mLeader of
                    -- Ask for the lease using the proposed membership.
                    -- Thus reconfiguration is possible even when the group has
                    -- no leaders and there is no quorum to elect one.
                    Nothing -> do
                      r <- mkLeaseRequest (decreeLegislatureId d) [π] ρs''
                      usend ppid (d, r)

                      -- Update the list of acceptors of the proposer, so we
                      -- have a chance to suceed when there is no quorum.
                      usend ppid (intersect ρs ρs')

                      if d == cd then go st { stateCurrentDecree = succ cd }
                      else go st

                    -- Drop the request.
                    Just leader | here /= leader -> do
                      usend μ (epoch, ρs)
                      go st

                    -- I'm the leader, so handle the request.
                    _ -> do

                      requestStart <- liftIO $ getTime Monotonic
                      -- Get self to propose reconfiguration...
                      usend self ( μ
                                 , epoch
                                 , Request
                                     { requestSender   = [π]
                                     , requestValue    =
                                         Reconf requestStart ρs'' :: Value a
                                     , requestHint     = None
                                     , requestForLease = Nothing
                                     }
                                 )

                      -- Update the list of acceptors of the proposer, so we
                      -- have a chance to suceed when there is no quorum.
                      usend ppid (intersect ρs ρs')

                      go st

            , matchIf (\(_, e, _ :: Helo) -> e < epoch) $
                      \(μ, _, _) -> do
                  usend μ (epoch, ρs)
                  go st

              -- An ambassador wants to know who the leader is.
            , match $ \μ -> do
                  usend μ (epoch, ρs)
                  go st

            -- Clock tick - time to advertize. Can be sent by anyone to any
            -- replica to provoke status info.
            , match $ \Status -> do
                  -- Forget about all previous ticks to avoid broadcast storm.
                  let loop = expectTimeout 0 >>= maybe (return ()) (\() -> loop)
                  when (not schedulerIsEnabled) loop

                  say $ "Status info:" ++
                      "\n\tunconfirmed decree: " ++ show d ++
                      "\n\tdecree:             " ++ show cd ++
                      "\n\twatermark:          " ++ show w ++
                      "\n\treplicas:           " ++ show ρs
                  forM_ others $ \ρ -> sendReplica logName ρ $
                    Max self d epoch ρs
                  go st
            ]

dictValue :: SerializableDict a -> SerializableDict (Value a)
dictValue SerializableDict = SerializableDict

dictList :: SerializableDict a -> SerializableDict [a]
dictList SerializableDict = SerializableDict

dictNodeId :: SerializableDict NodeId
dictNodeId = SerializableDict

dictMax :: SerializableDict Max
dictMax = SerializableDict

dictTimeSpec :: SerializableDict TimeSpec
dictTimeSpec = SerializableDict

-- | Like 'uncurry', but extract arguments from a 'Max' message rather than
-- a pair.
unMax :: (DecreeId -> LegislatureId -> [NodeId] -> a)
      -> Max
      -> a
unMax f (Max _ d epoch ρs) = f d epoch ρs

remotable [ 'replica
          , 'unMax
          , 'dictValue
          , 'dictList
          , 'dictNodeId
          , 'dictMax
          , 'dictTimeSpec
          , 'consensusProtocol
          ]

sdictValue :: Typeable a
           => Static (SerializableDict a)
           -> Static (SerializableDict (Value a))
sdictValue sdict = $(mkStatic 'dictValue) `staticApply` sdict

sdictMax :: Static (SerializableDict Max)
sdictMax = $(mkStatic 'dictMax)

listNodeIdClosure :: [NodeId] -> Closure [NodeId]
listNodeIdClosure xs =
    closure (staticDecode ($(mkStatic 'dictList) `staticApply` sdictNodeId))
            (encode xs)

-- | Serialization dictionary for 'NodeId'
sdictNodeId :: Static (SerializableDict NodeId)
sdictNodeId = $(mkStatic 'dictNodeId)

nodeIdClosure :: NodeId -> Closure NodeId
nodeIdClosure x = closure (staticDecode sdictNodeId) (encode x)

timeSpecClosure :: TimeSpec -> Closure TimeSpec
timeSpecClosure ts =
    closure (staticDecode $(mkStatic 'dictTimeSpec)) (encode ts)

unMaxCP :: Typeable a
        => Closure (  DecreeId
                   -> LegislatureId
                   -> [NodeId]
                   -> Process a
                   )
        -> CP Max a
unMaxCP f = staticClosure $(mkStatic 'unMax) `closureApply` f

expectSpawn :: SpawnRef -> Process ProcessId
expectSpawn ref =
    receiveWait [ matchIf (\(DidSpawn ref' _) -> ref' == ref) $
                           \(DidSpawn _ pid) -> return pid
                ]

replicaClosure :: Typeable a
               => Static (Dict (Eq a))
               -> Static (SerializableDict a)
               -> Closure Config
               -> Closure (Log a)
               -> Closure (  TimeSpec
                          -> DecreeId
                          -> LegislatureId
                          -> [NodeId]
                          -> Process ()
                          )
replicaClosure sdict1 sdict2 config log =
    staticClosure $(mkStatic 'replica)
      `closureApply` staticClosure sdict1
      `closureApply` staticClosure sdict2
      `closureApply` config
      `closureApply` log

-- | Hide the 'ProcessId' of the ambassador to a log behind an opaque datatype
-- making it clear that the ambassador acts as a "handle" to the log - it does
-- not uniquely identify the log, since there can in general be multiple
-- ambassadors to the same log.
data Handle a =
    Handle (Static (Dict (Eq a)))
           (Static (SerializableDict a))
           (Closure Config)
           (Closure (Log a))
           ProcessId
    deriving (Typeable, Generic)

instance Eq (Handle a) where
    Handle _ _ _ _ μ == Handle _ _ _ _ μ' = μ == μ'

-- | A handle to a log created remotely. A 'RemoteHandle' can't be used to
-- access a log, but it can be cloned into a local handle.
data RemoteHandle a =
    RemoteHandle (Static (Dict (Eq a)))
                 (Static (SerializableDict a))
                 (Closure Config)
                 (Closure (Log a))
                 (Closure (Process ()))
   deriving (Typeable, Generic)

instance Typeable a => Binary (RemoteHandle a)

-- | @ambassadorAux@ provides the implementation of @ambassador@ out of the
-- @remotableDecl@ use below. This improves compiler errors, mostly.
ambassadorAux :: forall a . SerializableDict a
              -> Config
              -> [NodeId]
              -> ([NodeId] -> Closure (Process ()))
              -> Process ()
ambassadorAux _ _ [] _ = do
    say "ambassador: Set of replicas must be non-empty."
    die "ambassador: Set of replicas must be non-empty."
ambassadorAux SerializableDict Config{logName, leaseTimeout} (ρ0 : others)
              cAmbassador =
    monitorReplica ρ0 >>= go 0 (Just ρ0) others
  where
    go :: LegislatureId    -- ^ The epoch of the replicas (use 0 while unknown)
       -> Maybe NodeId  -- ^ The leader replica if known
       -> [NodeId]      -- ^ The other replicas
       -> MonitorRef       -- ^ The monitor ref of a replica we are contacting
       -> Process b
    go epoch mLeader ρs ref = receiveWait
      [ match $ \(Clone δ) -> do
          usend δ $ cAmbassador $ maybe id (:) mLeader ρs
          go epoch mLeader ρs ref

      , match $ \Status -> do
          Foldable.forM_ mLeader $ flip (sendReplica logName) Status
          go epoch mLeader ρs ref

        -- The leader replica changed.
      , match $ \(epoch', ρ' : ρs') -> do
          -- Only update the replicas if they are at the same or higher
          -- epoch.
          if epoch <= epoch' then do
            unmonitor ref
            monitorReplica ρ' >>= go epoch' (Just ρ') ρs'
          else do
            when (isNothing mLeader) $ do
              -- Give some time to other replicas to elect a leader.
              liftIO $ threadDelay leaseTimeout
              -- Ask the head replica for the new leader.
              let ρ'' : _ = ρs
              getSelfPid >>= sendReplica logName ρ''
            go epoch mLeader ρs ref

      , match $ \(ProcessMonitorNotification ref' _ _) -> do
          if ref == ref' then do
            -- Give some time to other replicas to elect a leader.
            liftIO $ threadDelay leaseTimeout
            -- Continue poking at the disconnected leader if there
            -- are no more replicas.
            let ρ : ρss = maybe ρs (: ρs) mLeader
                ρs'@(ρ' : _) = ρss ++ [ρ]
            ref'' <- monitorReplica ρ'
            -- Ask the head replica for the new leader.
            getSelfPid >>= sendReplica logName ρ'
            go epoch Nothing ρs' ref''
          else
            go epoch mLeader ρs ref

        -- A new replica was added to the group.
      , match $ \ρ' -> do
          let ρs' = if mLeader == Just ρ' then ρs
                    -- Discard pids of replicas on the same node.
                    else filter (/= ρ') ρs ++ [ρ']
          go epoch mLeader ρs' ref

        -- A reconfiguration request
      , match $ \m@(Helo κ _) -> do
          usend κ ()
          self <- getSelfPid
          -- A reconfiguration decree does not need to go necessarily to the
          -- leader. The replicas might have lost quorum and could be unable to
          -- elect a new leader.
          let ρ  : ρss = ρs
              ρs' = maybe (ρss ++ [ρ]) (const ρs) mLeader
          sendReplica logName (maybe ρ id mLeader) (self, epoch, m)
          go epoch mLeader ρs' ref

        -- A request
      , match $ \a -> do
          forM_ (requestSender a) $ flip usend ()
          self <- getSelfPid
          Foldable.forM_ mLeader $ flip (sendReplica logName)
                                        (self, epoch, a :: Request a)
          go epoch mLeader ρs ref
      ]

    monitorReplica ρ = do
      whereisRemoteAsync ρ (replicaLabel logName)
      expectTimeout leaseTimeout >>= \case
        Just (WhereIsReply _ mpid) -> do
          monitor $ maybe (nullProcessId ρ) id mpid
        Nothing -> monitor (nullProcessId ρ)

remotableDecl [
    [d| -- | The ambassador to a cgroup is a local process that stands as a proxy to
        -- the cgroup. Its sole purpose is to provide a 'ProcessId' to stand for the
        -- cgroup and to forward all messages to the cgroup.
        ambassador :: ( Static (Some SerializableDict)
                      , Closure Config
                      , [NodeId]
                      )
                      -> Process ()
        ambassador (ssdict, cConfig, replicas) = do
          Some sdict <- unStatic ssdict
          config <- unClosure cConfig
          ambassadorAux sdict config replicas $ \ρs ->
            $(mkClosure 'ambassador) (ssdict, cConfig, ρs)

        mkSomeSDict :: SerializableDict a -> Some SerializableDict
        mkSomeSDict = Some

        initialLegislatureId :: LegislatureId
        initialLegislatureId = 0

        -- | @localSpawnAndRegister label p@ spawns a process locally
        -- which runs @p@ and registers the process with the given @label@.
        --
        -- If the process cannot be registered, the closure is not run.
        localSpawnAndRegister :: String -> Process () -> Process ()
        localSpawnAndRegister label p = do
          pid <- spawnLocal $ do
                   () <- expect
                   p
          register label pid `onException` exit pid "localSpawnAndRegister"
          usend pid ()
    |] ]

-- | Append an entry to the replicated log.
append :: Serializable a => Handle a -> Hint -> a -> Process ()
append (Handle _ _ _ _ μ) hint x = callLocal $ do
    self <- getSelfPid
    -- If we are interrupted, because the request is abandoned, we want to
    -- yield control back only after the ambassador acknowledges reception of
    -- the request. Thus we preserve the arrival order of requests. We cannot
    -- use uninterruptibleMask_ because of DP-105.
    withMonitor μ $ mask_ $ do
      usend μ $ Request
        { requestSender   = [self]
        , requestValue    = Values [x]
        , requestHint     = hint
        , requestForLease = Nothing
        }
      let loopingWait = receiveWait
            [ match return
            , match $ \(ProcessMonitorNotification _ _ _) -> return ()
            ] `onException` loopingWait
      loopingWait
    expect

-- | Make replicas advertize their status info.
status :: Serializable a => Handle a -> Process ()
status (Handle _ _ _ _ μ) = usend μ Status

-- | Updates the handle so it communicates with the given replica.
updateHandle :: Handle a -> NodeId -> Process ()
updateHandle (Handle _ _ _ _ α) = usend α

remoteHandle :: Handle a -> Process (RemoteHandle a)
remoteHandle (Handle sdict1 sdict2 config log α) = do
    self <- getSelfPid
    usend α $ Clone self
    RemoteHandle sdict1 sdict2 config log <$> expect

-- | Terminate the given process and wait until it dies.
exitAndWait :: ProcessId -> Process ()
exitAndWait p = callLocal $ bracket (monitor p) unmonitor $ \ref -> do
    exit p "exitAndWait"
    receiveWait
      [ matchIf (\(ProcessMonitorNotification ref' _ _) -> ref' == ref)
                (const $ return ())
      ]

-- | Spawns and registers a process running the given process in the given node.
--
-- If the process cannot be registered this function does nothing.
--
-- Returns when registration has either succeeded or failed.
spawnAndRegister :: NodeId -> String -> Closure (Process ()) -> Process ()
spawnAndRegister nid label' cp = callLocal $ do
    ref <- spawnAsync nid $ $(mkClosure 'localSpawnAndRegister) label'
                               `closureApply` cp
    pid <- expectSpawn ref
    mref <- monitor pid
    receiveWait
      [ matchIf (\(ProcessMonitorNotification ref' _ _) -> mref == ref')
                (const $ return ())
      ]

-- | Create a group of replicated processes.
--
-- spawns one replica process on each node in @nodes@. The behaviour of the
-- replica upon receipt of a message is determined by the @logClosure@ argument
-- which provides a callback for initilizing the state and another
-- callback for making transitions.
--
-- The argument @leaseTimeout@ indicates the length of the lease period
-- in microseconds. The lease period indicates how long the leader is guaranteed
-- to have no competition from other replicas when serving requests
-- as measured since the lease was requested.
--
-- The argument @leaseRenewalMargin@ indicates in microsencods with how much
-- anticipation the leader must renew the lease before the lease period
-- is over. A precondition is that @2 * leaseRenewalMargin < leaseTimeout@.
--
-- The returned 'Handle' identifies the group.
new :: Typeable a
    => Static (Dict (Eq a))
    -> Static (SerializableDict a)
    -> Closure Config
    -> Closure (Log a)
    -> [NodeId]
    -> Process (Handle a)
new sdict1 sdict2 config log nodes = do
    conf <- unClosure config
    let protocol = staticClosure $(mkStatic 'consensusProtocol)
                     `closureApply` config
                     `closureApply` staticClosure (sdictValue sdict2)
    forM_ nodes $ \nid ->
      spawnAndRegister nid
                       (acceptorLabel $ logName conf) $
                       acceptorClosure $(mkStatic 'dictNodeId)
                                       protocol
                                       nid

    now <- liftIO $ getTime Monotonic

    forM_ nodes $ \nid ->
      spawnAndRegister nid
                       (replicaLabel $ logName conf) $
                       replicaClosure sdict1 sdict2 config log
                         `closureApply` timeSpecClosure now
                         `closureApply` staticClosure initialDecreeIdStatic
                         `closureApply` staticClosure
                                          $(mkStatic 'initialLegislatureId)
                         `closureApply` listNodeIdClosure nodes

    -- Create a new local proxy for the cgroup.
    Handle sdict1 sdict2 config log <$>
      spawnLocal ( ambassador ( staticApply $(mkStatic 'mkSomeSDict) sdict2
                              , config
                              , nodes
                              )
                 )

-- | Propose a reconfiguration according the given nomination policy. Note that
-- in general, it is only safe to remove replicas if they are /certainly/ dead.
reconfigure :: Typeable a
            => Handle a
            -> Closure NominationPolicy
            -> Process ()
reconfigure (Handle _ _ _ _ μ) cpolicy = callLocal $ do
    self <- getSelfPid
    -- If we are interrupted, because the request is abandoned, we want to
    -- yield control back only after the ambassador acknowledges reception of
    -- the request. Thus we preserve the arrival order of requests. We cannot
    -- use uninterruptibleMask_ because of DP-105.
    withMonitor μ $ mask_ $ do
      usend μ $ Helo self cpolicy
      let loopingWait = receiveWait
            [ match return
            , match $ \(ProcessMonitorNotification _ _ _) -> return ()
            ] `onException` loopingWait
      loopingWait
    expect

-- | Start a new replica on the given node, adding it to the group pointed to by
-- the provided handle. Example usage:
--
-- > addReplica h nid leaseRenewalMargin
--
-- Note that the new replica will block until it gets a Max broadcast by one of
-- the existing replicas. In this way, the replica will not service any client
-- requests until it has indeed been accepted into the group.
addReplica :: Typeable a
           => Handle a
           -> NodeId
           -> Process ()
addReplica h@(Handle sdict1 sdict2 config log _) nid = do
    conf <- unClosure config
    now <- liftIO $ getTime Monotonic
    let protocol = staticClosure $(mkStatic 'consensusProtocol)
                     `closureApply` config
                     `closureApply` staticClosure (sdictValue sdict2)
    spawnAndRegister nid
                     (acceptorLabel $ logName conf) $
                     acceptorClosure $(mkStatic 'dictNodeId)
                                     protocol
                                     nid
    -- See comment about effect of 'cpExpect' in docstring above.
    spawnAndRegister nid
                     (replicaLabel $ logName conf)
                     (bindCP (cpExpect sdictMax) $
                        unMaxCP $ replicaClosure sdict1 sdict2 config log
                                    `closureApply` timeSpecClosure now
                     )

    reconfigure h $ $(mkStaticClosure 'Policy.orpn)
        `closureApply` nodeIdClosure nid

-- | Kill the replica and acceptor.
killReplica :: Typeable a
              => Handle a
              -> NodeId
              -> Process ()
killReplica (Handle _ _ config _ _) nid = do
    conf <- unClosure config
    whereisRemoteAsync nid (acceptorLabel $ logName conf)
    whereisRemoteAsync nid (replicaLabel $ logName conf)
    replicateM_ 2 $ receiveWait
      [ matchIf (\(WhereIsReply l _) -> elem l [ acceptorLabel $ logName conf
                                               , replicaLabel $ logName conf
                                               ]
                ) $
                 \(WhereIsReply _ mpid) -> case mpid of
                    Nothing -> return ()
                    Just p  -> exitAndWait p
      ]

-- | Kill the replica and acceptor and remove it from the group.
removeReplica :: Typeable a
              => Handle a
              -> NodeId
              -> Process ()
removeReplica h nid = do
    killReplica h nid
    reconfigure h $ staticClosure $(mkStatic 'Policy.notThem)
        `closureApply` listNodeIdClosure [nid]

clone :: Typeable a => RemoteHandle a -> Process (Handle a)
clone (RemoteHandle sdict1 sdict2 config log f) =
    Handle sdict1 sdict2 config log <$> (spawnLocal =<< unClosure f)
