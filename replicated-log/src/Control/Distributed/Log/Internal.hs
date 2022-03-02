-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Replicate state machines and their logs. This module is intended to be
-- imported qualified.

{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE CPP #-}

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
    , LogId
    , toLogId
    , new
    , spawnReplicas
    , append
    , status
    , reconfigure
    , recover
    , monitorLog
    , monitorLocalLeader
    , getLeaderReplica
    , addReplica
    , killReplica
    , removeReplica
    , getMembership
      -- * Remote Tables
    , Control.Distributed.Log.Internal.__remoteTable
    ) where

import Prelude hiding ((<$>), (<*>), init, log)
import Control.Distributed.Log.Messages
import qualified Control.Distributed.Log.Persistence as P
import Control.Distributed.Log.Persistence.LevelDB
import Control.Distributed.Log.Persistence (PersistentStore, PersistentMap)
import Control.Distributed.Log.Policy (NominationPolicy)
import Control.Distributed.Log.Policy as Policy
    ( notThem
    , notThem__static
    , orpn
    , orpn__static
    )
import Control.Distributed.Log.Trace
import Control.Distributed.Process.Batcher (batcher)
import Control.Distributed.Process.Consensus hiding (Value)
import qualified Control.Distributed.Process.Pool.Bounded as Bounded
    ( submitTask
    , ProcessPool
    , newProcessPool
    )
import qualified Control.Distributed.Process.Pool.Keyed as Keyed
    ( submitTask
    , ProcessPool
    , newProcessPool
    )
import Control.Distributed.Process.Timeout

-- Preventing uses of spawn and call because of
-- https://cloud-haskell.atlassian.net/browse/DP-104
import Control.Distributed.Process hiding
    (spawn, bracket, mask, catch, try, finally)
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Scheduler (schedulerIsEnabled)
import Control.Distributed.Process.Internal.Types (nullProcessId)
import Control.Distributed.Static
    (closureApply, staticApply, staticClosure)

import Control.Arrow (second)
import Control.Concurrent hiding (newChan)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TChan
import Control.Monad hiding (forM_)
import Control.Monad.Catch
import Data.Binary (Binary, encode, decode)
import qualified Data.ByteString.Lazy as BSL (ByteString, length)
import Data.Constraint (Dict(..))
import Data.Foldable (forM_)
import Data.Function (fix)
import Data.Int (Int64)
import Data.List (partition, sortBy, nub, intersect, sort)
import qualified Data.Foldable as Foldable
import Data.Function (on)
import Data.IORef
import Data.Maybe
#if ! MIN_VERSION_base(4,8,0)
import Data.Monoid (Monoid(..))
#endif
import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.String (fromString)
import Data.Ratio (Ratio, numerator, denominator)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Prelude hiding (init, log)
import System.Clock
import System.FilePath ((</>))
import System.Directory (doesDirectoryExist, getCurrentDirectory)


nlogTrace :: LogId -> String -> Process ()
nlogTrace (LogId s) msg = logTrace $ s ++ ": " ++ msg

deriving instance Typeable Eq

-- | An auxiliary type for hiding parameters of type constructors
data Some f = forall a. Some (f a) deriving (Typeable)

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

-- | The identity of a replica group.
newtype LogId = LogId String
  deriving (Typeable, Binary, Show, Eq)

-- | Produces a LogId from a 'String'.
toLogId :: String -> LogId
toLogId = LogId

-- TODO: Make requirements on snapshot availability explicit.
--
-- The log has two persisted components: a snapshot and a write-ahead log (WAL).
-- Only the WAL is locally available. Thus for this implementation to deliver
-- its guarantees, some requirements on how the user makes the snapshots
-- available needs to be formulated.
--
-- Some related discussion is here:
-- https://github.com/tweag/halon/pull/185

data Log a = forall s ref. Serializable ref => Log
    { -- | Yields the initial value of the log.
      logInitialize :: !(Process s)

      -- | Yields the list of references of available snapshots.
      -- Each reference is accompanied with the 'DecreeId' of the next log entry
      -- to execute.
      --
      -- On each node this function could return different results.
      --
    , logGetAvailableSnapshots :: !(Process [(DecreeId, ref)])

      -- | Yields the snapshot identified by ref.
      --
      -- If the snapshot cannot be retrieved an exception is thrown.
      --
      -- After a succesful call, the snapshot returned or a newer snapshot must
      -- appear listed by @logGetAvailableSnapshots@.
      --
    , logRestore :: !(ref -> Process s)

      -- | Writes a snapshot together with the 'DecreeId' of the next log index.
      --
      -- Returns a reference which any replica can use to get the snapshot
      -- with 'logRestore'.
      --
      -- After a succesful call, the dumped snapshot or a newer snapshot must
      -- appear listed in @logGetAvailableSnapshots@.
      --
      -- The replica may interrupt this call if it takes too long.
      --
    , logDump :: !(DecreeId -> s -> Process ref)

      -- | State transition callback.
    , logNextState      :: !(s -> a -> Process s)
    } deriving (Typeable)

data Config = Config
    { -- The identity of this log
      logId :: LogId

      -- | The consensus protocol to use.
    , consensusProtocol :: forall a. SerializableDict a -> Protocol NodeId a

      -- | For any given node, the directory in which to store persistent state.
    , persistDirectory  :: NodeId -> FilePath

      -- | The length of time before leases time out, in microseconds. The
      -- period is extended by this amount every time the replica passes a
      -- decree.
    , leaseTimeout      :: Int

      -- | The length of time that a leader should anticipate to renew its
      -- lease, in microseconds. @leaseRenewTimeout@ microseconds before the
      -- leaseexpires, the leader will try to renew the lease.
      --
      -- To avoid leader churn, you should ensure that
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
      -- | Legislature to start and the list of replicas.
    | Reconf LegislatureId [NodeId]
    deriving (Eq, Generic, Typeable)

instance Binary a => Binary (Value a)

isReconf :: Value a -> Bool
isReconf (Reconf {}) = True
isReconf _           = False

-- | A type for internal requests.
data Request a = Request
    { requestSender   :: [ProcessId]
    , requestValue    :: Value a
    , requestHint     :: Hint
    }
  deriving (Generic, Typeable)

instance Binary a => Binary (Request a)

-- | A type for requests directed to the proposer process.
data ProposerRequest a = ProposerRequest
    { prDecree      :: DecreeId
      -- | This is @True@ iff the request comes from the batcher.
    , prFromBatcher :: Bool
      -- | Time at which  the request was submitted.
    , prStart       :: TimeSpec
    , prRequest     :: Request a
    }
  deriving (Generic, Typeable)

instance Binary a => Binary (ProposerRequest a)

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

replicaLabel :: LogId -> String
replicaLabel (LogId kstr) = kstr ++ ".replica"

acceptorLabel :: LogId -> String
acceptorLabel (LogId kstr) = kstr ++ ".acceptor"

batcherLabel :: LogId -> String
batcherLabel (LogId kstr) = kstr ++ ".batcher"

sendReplica :: Serializable a => LogId -> NodeId -> a -> Process ()
sendReplica name nid = nsendRemote nid $ replicaLabel name

sendAcceptor :: Serializable a => LogId -> NodeId -> a -> Process ()
sendAcceptor name nid = nsendRemote nid $ acceptorLabel name

-- | Terminate the given process and wait until it dies.
exitAndWait :: ProcessId -> Process ()
exitAndWait p = callLocal $ bracket (monitor p) unmonitor $ \ref -> do
    exit p "exitAndWait"
    receiveWait
      [ matchIf (\(ProcessMonitorNotification ref' _ _) -> ref' == ref)
                (const $ return ())
      ]

sendReplicaAsync :: Serializable a
                 => Keyed.ProcessPool NodeId -> LogId -> NodeId -> a
                 -> Process ()
sendReplicaAsync pool name nid a
  | schedulerIsEnabled = sendReplica name nid a
  | otherwise          =
    Keyed.submitTask pool nid (sendReplica name nid a)
      >>= maybe (return ()) spawnWorker
  where
    spawnWorker worker = do
      self <- getSelfPid
      void $ spawnLocal $ link self >> linkNode nid >> worker

queryMissingFrom :: Keyed.ProcessPool NodeId
                 -> LogId
                 -> Int      -- ^ next decree to execute
                 -> [NodeId] -- ^ replicas to query
                 -> Map.Map Int (Value a) -- ^ log
                 -> Process ()
queryMissingFrom sendPool name w replicas log = do
    let pw = pred w
        ns = concat $ gaps $ (pw:) $ Map.keys $ snd $ Map.split pw log
    self <- getSelfPid
    forM_ ns $ \n -> do
        forM_ replicas $ \ρ -> do
            sendReplicaAsync sendPool name ρ $ Query self n

-- | A dictionary with the persistent operations used by replicas.
data PersistenceHandle a = PersistenceHandle
    { persistentStore         :: PersistentStore
    , persistentMembershipMap :: PersistentMap Int
    , persistentLogMap        :: PersistentMap Int
      -- | This is the log stored in memory, so it doesn't have to be read from
      -- the store everytime it is requested.
    , persistentLogCache      :: IORef (Map.Map Int (Value a))
    }

insertInLog :: Serializable a => PersistenceHandle a -> Int -> Value a -> IO ()
insertInLog (PersistenceHandle {..}) n v = do
    P.atomically persistentStore $
      case v of
        Reconf leg' rs' ->
          [ P.Insert persistentLogMap n $ encode v
          , P.Insert persistentMembershipMap 0 $ encode (DecreeId leg' n, rs')
          ]
        _                 ->
          [ P.Insert persistentLogMap n $ encode v ]
    modifyIORef' persistentLogCache $ Map.insert n v

-- | Removes all entries below the given index from the log.
--
-- See note [Trimming the log]
trimTheLog :: PersistenceHandle a
           -> Int           -- ^ Log index
           -> IO ()
trimTheLog (PersistenceHandle {..}) w0 = do
    let w0' = pred w0
    (toTrim, !rest) <- Map.split w0' <$> readIORef persistentLogCache
    P.atomically persistentStore
      [ P.Trim persistentLogMap (Map.keys toTrim ++ [w0']) ]
    writeIORef persistentLogCache rest

-- | Small view function for extracting a specialized 'Protocol'. Used in 'replica'.
unpackConfigProtocol :: Serializable a => Config -> (Config, Protocol NodeId (Value a))
unpackConfigProtocol Config{..} = (Config{..}, consensusProtocol SerializableDict)

-- | Encloses an action with opening and close operations on a persistent store.
withPersistentStore :: FilePath -> (PersistentStore -> Process a) -> Process a
withPersistentStore fp =
   bracket (liftIO $ openPersistentStore fp)
           (liftIO . P.close)

-- | The internal state of a replica.
data ReplicaState s ref a = Serializable ref => ReplicaState
  { -- | The pid of the proposer process.
    stateProposerPid       :: !ProcessId
    -- | The pid of the lease renewal timer process.
    -- Ticks whenever the lease should be requested.
  , stateLeaseRenewalTimerPid :: !ProcessId
    -- | The pid of the lease timeout timer process.
    -- The timer produces a tick whenever the lease of the replica expires.
  , stateLeaseTimeoutTimerPid :: !ProcessId
    -- | Handle to persist the log.
  , statePersistenceHandle :: !(PersistenceHandle a)
    -- | The time at which the last lease started.
  , stateLeaseStart        :: !TimeSpec
    -- | The list of node ids of the replicas.
  , stateReplicas          :: [NodeId]
    -- | Tells the decree of the last proposal request sent to the proposer
    -- process.
    --
    -- Invariant: isJust stateLastProposed
    --              `implies`
    --            stateLastProposed <= Just stateWatermark
  , stateLastProposed      :: Maybe DecreeId
    -- | This is the decree identifier of the next proposal to confirm. All
    -- previous decrees are known to have passed consensus.
  , stateUnconfirmedDecree :: !DecreeId
    -- | This is the decree identifier of the next proposal to do.
    --
    -- For now, it must never be an unreachable decree (i.e. a decree beyond the
    -- reconfiguration decree that changes to a new legislature) or any
    -- proposal using the decree identifier will never be acknowledged or
    -- executed.
    --
    -- Invariant: @stateUnconfirmedDecree <= stateCurrentDecree@
    --
  , stateCurrentDecree     :: !DecreeId
    -- | The pid of the process dumping the latest snapshot and its watermark.
  , stateSnapshotDumper    :: !(Maybe (DecreeId, ProcessId))
    -- | The reference to the last snapshot saved.
  , stateSnapshotRef       :: !(Maybe ref)
    -- | The watermark of the lastest snapshot
    --
    -- See note [Trimming the log].
  , stateSnapshotWatermark :: !DecreeId
    -- | The identifier of the next decree to execute.
  , stateWatermark         :: !DecreeId
    -- | The state yielded by the last executed decree.
  , stateLogState          :: s
    -- | The LegislatureId where the leader became the leader
    -- See Note [Epochs].
  , stateEpoch             :: !LegislatureId
    -- | The decree of the last known reconfiguration.
  , stateReconfDecree      :: !DecreeId
    -- | Batcher of client requests
  , stateBatcher           :: !ProcessId
    -- | A channel to communicate lease renewal times
  , stateLeaseRenewalTimerRP :: !(ReceivePort ())
    -- | A channel to communicate lease timeouts
  , stateLeaseTimeoutTimerRP :: !(ReceivePort ())
    -- | A pool of processes to send messages asynchronously
  , stateSendPool          :: !(Keyed.ProcessPool NodeId)
    -- | A pool of processes dealing with persistence operations
  , statePersistPool       :: !Bounded.ProcessPool
    -- | The set of process doing asynchronous IO.
  , statePersistProcs      :: IORef (Maybe (Set.Set ProcessId))

  -- from Log {..}
  , stateLogRestore        :: !(ref -> Process s)
  , stateLogDump           :: !(DecreeId -> s -> Process ref)
  , stateLogNextState      :: !(s -> a -> Process s)

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

-- | A timer process. When receiving @t@, the process waits for @t@
-- microsenconds and then it sends @()@ through @sendPort@.
--
-- If while waiting, another @t'@ value is received, the wait
-- restarts with the new parameters.
--
timer :: SendPort () -> Process ()
timer sp = expect >>= wait
  where
    wait :: Int -> Process ()
    wait t =
      expectTimeout t >>= maybe (sendChan sp () >> timer sp) wait

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
        -> DecreeId
        -> [NodeId]
        -> Process ()
replica Dict
        SerializableDict
        (unpackConfigProtocol -> (Config{..}, Protocol{..}))
        (Log {..})
        leaseStart0
        decree
        legD0
        replicas0 = reportTermination "replica" $ do

   say $ "Starting new replica for " ++ show logId
   self <- getSelfPid
   here <- getSelfNode
   persistProcs <- liftIO $ newIORef $ Just Set.empty
   -- 'withLogIdLock' makes sure that any running operation on the local state
   -- completes before we try to open it. By now we have registered the replica
   -- label, so any subsequent operations on the local state won't interfere
   -- when we release the log id lock again.
   withLogIdLock logId $ return ()
   path <- localLogPath logId persistDirectory
   withPersistentStore path $ \persistentStore ->
    flip finally (cancelWaitPersistProcs persistProcs) $ do
    logMap <- liftIO $ P.getMap persistentStore $ fromString "logMap"
    membershipMap <- liftIO $ P.getMap persistentStore
                            $ fromString "membershipMap"
    logCacheRef <- liftIO $ newIORef Map.empty
    let persistenceHandle =
          PersistenceHandle persistentStore membershipMap logMap logCacheRef
    sns <- logGetAvailableSnapshots
    -- Try the snapshots from the most recent to the less recent.
    let findSnapshot []               = (DecreeId 0 0,) <$> logInitialize
        findSnapshot ((w0, ref) : xs) = restoreSnapshot (logRestore ref) >>=
                                        maybe (findSnapshot xs) (return . (w0,))
    (w0, s) <- findSnapshot $ sortBy (flip compare `on` fst) sns

    -- Replay backlog if any.
    log :: Map.Map Int (Value a) <- liftIO $ Map.fromList . map (second decode)
                                          <$> P.pairsOfMap logMap
    (legD', replicas') <- liftIO $ maybe (legD0, replicas0) decode
                                 <$> P.lookup membershipMap 0
    say $ "Log size of replica: " ++ show (Map.size log)
    -- We have a membership list comming from the function parameters
    -- and a membership list comming from disk.
    --
    -- We adopt the membership list with the highest legislature.
    let replicas = if legD0 < legD' then replicas' else replicas0
        legD     = max legD0 legD'
        epoch    = decreeLegislatureId legD

    say $ "New replica started in " ++ show (decreeLegislatureId legD)

    -- Teleport all decrees to the highest possible legislature, since all
    -- recorded decrees must be replayed. This has no effect on the current
    -- decree number and the watermark. See Note [Teleportation].
    forM_ (Map.toList log) $ \(n,v) -> do
        usend self $ Decree 0 Stored (DecreeId maxBound n) v

    let d = legD { decreeNumber = max (decreeNumber decree) $
                                    if Map.null log
                                      then decreeNumber w0
                                      else succ $ fst $ Map.findMax log
                 }
        others = filter (/= here) replicas

    sendPool <- Keyed.newProcessPool
    queryMissingFrom sendPool logId (decreeNumber w0) others $
        Map.insert (decreeNumber d) undefined log

    persistPool <- liftIO $ Bounded.newProcessPool 50

    (rtimerSP, rtimerRP) <- newChan
    rtimerPid <- spawnLocal $ link self >> timer rtimerSP
    (ttimerSP, ttimerRP) <- newChan
    ttimerPid <- spawnLocal $ link self >> timer ttimerSP
    leaseStart0' <- setLeaseTimer rtimerPid ttimerPid leaseStart0 replicas

    -- Wait for any previously running batcher to die.
    mbpid <- whereis (batcherLabel logId)
    forM_ mbpid exitAndWait
    mLeader <- getLeader leaseStart0' replicas
    bpid <- if mLeader == Just here then do
        bpid <- spawnLocal $ do
          nlogTrace logId "spawned batcher"
          link self >> reportTermination "batcher"
                         (batcher (sendBatch self) (epoch, replicas))
        register (batcherLabel logId) bpid
        return bpid
      else
        return $ nullProcessId here
    ppid <- spawnLocal $ do
              nlogTrace logId "spawned proposer"
              link self >> reportTermination "proposer"
                             (proposer self bpid w0 Bottom replicas)

    go ReplicaState
         { stateProposerPid = ppid
         , stateLeaseRenewalTimerPid = rtimerPid
         , stateLeaseTimeoutTimerPid = ttimerPid
         , statePersistenceHandle = persistenceHandle
         , stateLeaseStart = leaseStart0'
         , stateReplicas = replicas
         , stateLastProposed = Nothing
         , stateUnconfirmedDecree = d
         , stateCurrentDecree = d
         , stateSnapshotDumper = Nothing
         , stateSnapshotRef   = Nothing
         , stateSnapshotWatermark = w0
         , stateWatermark = w0
         , stateLogState = s
         , stateEpoch    = epoch
         , stateReconfDecree = legD
         , stateBatcher  = bpid
         , stateLeaseRenewalTimerRP = rtimerRP
         , stateLeaseTimeoutTimerRP = ttimerRP
         , stateSendPool = sendPool
         , statePersistPool = persistPool
         , statePersistProcs = persistProcs
         , stateLogRestore = logRestore
         , stateLogDump = logDump
         , stateLogNextState = logNextState
         }
  where
    cond b t f = if b then t else f

    reportTermination name m = do
      let LogId nLogId = logId
      catch (do
        void m
        say $ nLogId ++ ": " ++ name ++ " terminated normally"
       ) $ \e -> do
        say $ nLogId ++ ": " ++ name ++ " terminated with exception: " ++ show e
        throwM (e :: SomeException)

    -- Terminates any processes doinf async IO before the persistent store
    -- handle is closed.
    cancelWaitPersistProcs ref = do
      mprocs <- liftIO $ atomicModifyIORef ref $ \mprocs -> (Nothing, mprocs)
      case mprocs of
        Nothing -> return ()
        Just procs -> callLocal $ do
          mapM_ monitor procs
          mapM_ (`kill` "cancelWaitPersistProcs") procs
          replicateM_ (Set.size procs)
            (expect :: Process ProcessMonitorNotification)

    -- Returns the leader if the lease has not expired.
    getLeader :: TimeSpec -> [NodeId] -> Process (Maybe NodeId)
    getLeader leaseStart' ρs' = do
      here <- getSelfNode
      now <- liftIO $ getTime Monotonic
      case ρs' of
        ρ : _
            -- Adjust the period to account for some clock drift, so
            -- non-leaders think the lease is slightly longer.
          | let adjustedPeriod = if here == ρ then leaseTimeout
                                   else adjustForDrift leaseTimeout
          , now - leaseStart' < fromInteger (toInteger adjustedPeriod * 1000)
           -> return $ Just ρ
        _  -> return Nothing

    -- Restores a snapshot with the given operation and returns @Nothing@ if an
    -- exception is thrown or if the operation times-out.
    restoreSnapshot :: Process s -> Process (Maybe s)
    restoreSnapshot restore =
       callLocal (try $ timeout snapshotRestoreTimeout restore) >>= \case
         Left (e :: SomeException) -> do
           nlogTrace logId $ "restoreSnapshot: failed with " ++ show e
           return Nothing
         Right ms -> return ms

    sendBatch :: ProcessId
              -> (LegislatureId, [NodeId])
              -> [(ProcessId, LegislatureId, Request a)]
              -> Process (LegislatureId, [NodeId])
    sendBatch ρ s0 rs0 = do
      s@(epoch, ρs) <- flip fix s0 $ \loop s -> expectTimeout 0
                         >>= maybe (return s) loop
      let (rs1, withOldEpoch) = partition (\(_, e, _) -> e >= epoch) rs0
      forM_ (nub $ map (\(μ, _, _) -> μ) withOldEpoch) $ \μ -> do
        nlogTrace logId $ "batcher: rejected client request " ++ show (μ, epoch)
        usend μ (epoch, ρs)
      forM_ withOldEpoch $ \(_, _, r) ->
        forM_ (requestSender r) $ flip usend False
      flip fix rs1 $ \loop rs2 -> if null rs2 then return s else do
        let -- Pick requests until the size of the encoding exceeds a threshold.
            -- Otherwise, creating too large batches would slow down replicas.
            maxBatchSize = 128 * 1024
            (rs, rest) = -- ensure rs is not empty
                         (\p -> if null (fst p) then splitAt 1 (snd p) else p) $
                         (\(a, b) -> (map snd a, map snd b)) $
                         break ((> maxBatchSize) . fst) $
                         zip (scanl1 (+) $ map (BSL.length . encode) rs2) rs2
            (nps, other0) =
              partition ((Nullipotent ==) . requestHint . batcherMsgRequest) $
              map (\(a, e, r) -> BatcherMsg a e r) rs
            (rcfgs, other) =
              partition (isReconf . requestValue . batcherMsgRequest) other0
        nlogTrace logId "batcher: reconf"
        -- Submit the last configuration request in the batch.
        unless (null rcfgs) $ do
          usend ρ [last rcfgs]
          expect
        -- Submit the non-nullipotent requests.
        nlogTrace logId $ "batcher: non-nullipotent " ++ show (length other, length rest)
        unless (null other) $ do
          usend ρ other
          expect
        -- Send nullipotent requests after all other batched requests.
        nlogTrace logId "batcher: nullipotent"
        unless (null nps) $ do
          usend ρ nps
          expect
        nlogTrace logId "batcher: done"
        loop rest

    adjustForDrift :: Int -> Int
    adjustForDrift t = fromIntegral $
      -- Perform multiplication in Int64 arithmetic to reduce the chance
      -- of an overflow.
      fromIntegral t * numerator   driftSafetyFactor
      `div` denominator driftSafetyFactor

    -- Sets the timers to renew or request the lease and returns the time at
    -- which the lease is started.
    setLeaseTimer :: ProcessId -- ^ pid of the lease renewal timer process
                  -> ProcessId -- ^ pid of the lease timeout timer process
                  -> TimeSpec  -- ^ time at which the request was submitted
                  -> [NodeId]   -- ^ replicas
                  -> Process TimeSpec
    setLeaseTimer rtimerPid ttimerPid requestStart ρs = do
      -- If I'm the leader, the lease starts at the time
      -- the request was made. Otherwise, it starts now.
      here <- getSelfNode
      if [here] == take 1 ρs then
        setLeaseRenewTimer rtimerPid ttimerPid requestStart
      else do
        usend rtimerPid $ adjustForDrift leaseTimeout
        liftIO $ getTime Monotonic

    -- Sets the timer to renew the lease and returns the time at which the lease
    -- is started.
    setLeaseRenewTimer :: ProcessId -- ^ pid of the lease renewal timer process
                       -> ProcessId -- ^ pid of the lease deadline timer process
                       -> TimeSpec  -- ^ time at which the request was submitted
                       -> Process TimeSpec
    setLeaseRenewTimer rtimerPid ttimerPid requestStart = do
      now <- liftIO $ getTime Monotonic
      let timeSpecToMicro (TimeSpec s ns) = s * 1000000 + ns `div` 1000
          elapsed = fromIntegral (timeSpecToMicro $ now - requestStart)
          t = max 0 $ leaseTimeout - leaseRenewTimeout - elapsed
      usend rtimerPid t
      usend ttimerPid $ max 0 $ leaseTimeout - elapsed
      nlogTrace logId $ "set lease timer to " ++ show (leaseTimeout - elapsed)
      return requestStart

    -- The proposer process makes consensus proposals.
    -- Proposals are aborted when a reconfiguration occurs or when the
    -- watermark increases beyond the proposed decree.
    proposer ρ bpid !w !s αs =
      receiveWait
        [ match $ \r@(ProposerRequest d _ _
                                      (Request {requestValue = v :: Value a}))
                  -> {-# SCC "ProposerRequest" #-}
          cond (d < w) (usend ρ r >> proposer ρ bpid w s αs) $ do
            self <- getSelfPid
            -- The MVar stores the result of the proposal.
            -- With an MVar we can ensure that:
            --  * when we abort the proposal, the result is not communicated;
            --  * when the result is communicated, the proposal is not aborted.
            -- If both things could happen simultaneously, we would need to
            -- write the code to handle that case.
            mv <- liftIO newEmptyMVar
            pid <- spawnLocal $ do
                     nlogTrace logId $ "spawned proposal for " ++ show (d, αs)
                     link self
                     result <- runPropose'
                                 (prl_propose (sendAcceptor logId) αs d v) s
                     ok <- liftIO $ tryPutMVar mv result
                     nlogTrace logId $ "proposal passed? - " ++ show ok
                     when ok $ usend self ()
            let -- After this call the mailbox is guaranteed to be free of @()@
                -- notification from the worker.
                --
                -- Returns true if the worker's result was blocked.
                clearNotifications = do
                  nlogTrace logId $ "proposer: try to abort the proposal"
                  -- try to block the worker's result
                  blocked <- liftIO $ tryPutMVar mv undefined
                  when (not blocked) $ do
                    -- consume the stale @()@ notification from the worker
                    nlogTrace logId $ "proposer: consume stale notification"
                    expect
                  return blocked
            (αs', w', blocked) <- fix $ \loop -> receiveWait
                      [ match $ \() -> {-# SCC "p-finished" #-}
                          return (αs, w, False)
                      , match $ \αs' -> {-# SCC "reconf-a" #-}
                         do
                          nlogTrace logId $ "proposer: reconf-a"
                          -- reconfiguration of the proposer
                          (,,) αs' w <$> clearNotifications
                      , match $ \w' -> {-# SCC "reconf-w" #-}
                         do
                          nlogTrace logId $ "proposer: reconf-w"
                          if w' <= d then loop
                          else -- the watermark increased beyond the proposed
                               -- decree
                            (,,) αs w' <$> clearNotifications
                      ]
            nlogTrace logId $ "proposer: proposal passed? "
                                            ++ show (d, not blocked)
            if blocked then do
              exit pid "proposer reconfiguration"
              -- If the leader loses the lease, resending the request will cause
              -- the proposer to compete with replicas trying to acquire the
              -- lease.
              --
              -- TODO: Consider if there is a way to avoid competition of
              -- proposers here.
              if w' <= d then usend self r
                else usend ρ r
              proposer ρ bpid w' s αs'
            else do
              (v',s') <- liftIO $ takeMVar mv
              usend ρ (v', r)
              proposer ρ bpid w' s' αs'

        , match $ \αs' -> {-# SCC "update-a" #-} proposer ρ bpid w s αs'
        , match $ \w' -> {-# SCC "update-w" #-}
            proposer ρ bpid (max w w') s αs
        ]

    -- Makes a lease request. It takes the decree to use for consensus.
    proposeLeaseRequest :: ProcessId -> DecreeId -> [ProcessId] -> [NodeId]
                        -> Process ()
    proposeLeaseRequest ppid di senders replicas = do
      here <- getSelfNode
      let ρs' = here : filter (here /=) replicas
          req = Request
                  { requestSender   = senders
                  , requestValue    =
                      Reconf (succ (decreeLegislatureId di)) ρs' :: Value a
                  , requestHint     = None
                  }
      now <- liftIO $ getTime Monotonic
      usend ppid (ProposerRequest di False now req)


    -- The purpose of go is to check if the replica is delayed, and if so
    -- make a proposal to discover later decrees. This gives replicas the
    -- necessary initiative when the most up-to-date replicas are offline.
    go :: ReplicaState s ref a -> Process b
    go st@(ReplicaState {..}) =
      if stateWatermark < stateCurrentDecree
         && stateLastProposed /= Just stateWatermark then do
        mLeader <- getLeader stateLeaseStart stateReplicas
        if isNothing mLeader then do
          -- Only propose if there is no leader. This way we don't slow down
          -- an existing leader.
          proposeLeaseRequest stateProposerPid stateWatermark [] stateReplicas
          goNext st{ stateLastProposed = Just stateWatermark }
        else
          goNext st
      else
        goNext st

    goNext :: ReplicaState s ref a -> Process b
    goNext st@(ReplicaState ppid rtimerPid ttimerPid ph leaseStart ρs lastProposed d
                        cd mdumper
                        msref w0 w s epoch legD bpid rtimerRP ttimerRP sendPool
                        persistPool persistProcs
                        stLogRestore stLogDump stLogNextState
          ) =
     do
        self <- getSelfPid
        here <- getSelfNode
        log <- liftIO $ readIORef $ persistentLogCache ph
        let others = filter (/= here) ρs

            -- Updates the membership list of the proposer if it has changed.
            updateAcceptors ρs' = if ρs == ρs' then return ()
                                    else usend ppid ρs'
            -- Updates the watermark of the proposer if it has changed.
            updateWatermark w' = usend ppid w'

            -- Does a persistence operation asynchronously.
            doPersistenceOpAsync task = do
              mproc <- Bounded.submitTask persistPool task
              case mproc of
                Nothing   -> return ()
                Just proc -> void $ spawnLocal $ do
                  worker <- getSelfPid
                  let forceMaybe = maybe Nothing (Just $!)
                  ok <- liftIO $ atomicModifyIORef' persistProcs $ \mprocs ->
                    (forceMaybe $ Set.insert worker <$> mprocs, isJust mprocs)
                  when ok $
                    proc `finally`
                      liftIO (atomicModifyIORef' persistProcs $ \mprocs ->
                                 (forceMaybe $ Set.delete worker <$> mprocs, ())
                             )
        receiveWait $ cond (w == cd)
            [ -- The lease renewal timer ticked.
              matchChan rtimerRP $ \() -> do
                  mLeader <- getLeader leaseStart ρs
                  nlogTrace logId $ "LeaseRenewalTime: " ++ show (w, cd, mLeader)
                  (cd', lastProposed') <-
                    if Just here == mLeader || isNothing mLeader then do
                      proposeLeaseRequest ppid cd [] ρs
                      return (succ cd, Just cd)
                    else
                      return (cd, lastProposed)
                  usend rtimerPid leaseTimeout
                  go st{ stateCurrentDecree = cd'
                       , stateLastProposed  = lastProposed'
                       }
            ]
            [] ++
            [ -- The lease timeout timer ticked.
              matchChan ttimerRP $ \() -> do
                  mLeader <- getLeader leaseStart ρs
                  nlogTrace logId $ "Lease timeout timer tick: " ++
                                    show (w, cd, mLeader)
                  -- Kill the batcher if I'm not the leader.
                  when (mLeader /= Just here) $ exitAndWait bpid
                  go st

            , matchIf (\(Decree _ _ di _ :: Decree (Value a)) ->
                        -- Take the max of the watermark legislature and the
                        -- incoming legislature to deal with teleportation of
                        -- decrees. See Note [Teleportation].
                        di < max w w{decreeLegislatureId = decreeLegislatureId di}) $ {-# SCC "go/Decree/Value" #-}
                       \(Decree _ locale di _) -> do
                  -- We must already know this decree, or this decree is from an
                  -- old legislature, so skip it.
                  nlogTrace logId $ "Skipping decree: " ++ show (w, di, locale)

                  case locale of
                      -- Ack back to the batcher. It may be waiting on the
                      -- decree to be handled.
                      Local _ pids -> forM_ pids $ flip usend ()
                      _ -> return ()

                  -- Advertise our configuration to other replicas if we are
                  -- getting old decrees.
                  forM_ others $ \ρ ->
                    sendReplicaAsync sendPool logId ρ $
                      Max self legD d epoch ρs
                  go st

              -- Commit the decree to the log.
            , matchIf (\(Decree _ locale di _) ->
                        locale /= Stored && w <= di && decreeNumber di == decreeNumber w) $ {-# SCC "go/Decree/Commit" #-}
                       \(Decree requestStart locale di v) -> do
                  nlogTrace logId $ "Storing decree: " ++ show (w, di)
                  -- Write the log asynchronously
                  doPersistenceOpAsync $ do
                    liftIO $ insertInLog ph (decreeNumber di) (v :: Value a)
                    let usendAsync to m = do
                          let nid = processNodeId to
                          mproc <- Keyed.submitTask sendPool nid $ usend to m
                          case mproc of
                            Nothing -> return ()
                            Just proc -> void $ spawnLocal $
                              link self >> linkNode nid >> proc
                    case locale of
                      -- Ack back to the client.
                      Local κs pids -> do forM_ κs $ flip usendAsync True
                                          -- pids are local processes for now
                                          forM_ pids $ flip usend ()
                      _ -> return ()
                    usend self $ Decree requestStart Stored di v
                  go st

              -- Execute the decree
            , matchIf (\(Decree _ locale di _) ->
                        locale == Stored && w <= di && decreeNumber di == decreeNumber w) $ {-# SCC "go/Decree/Execute" #-}
                       \(Decree requestStart _ di v) -> do
                let maybeTakeSnapshot w' s' = do
                      let w0' = maybe w0 fst mdumper
                      takeSnapshot <- snapshotPolicy
                                        (decreeNumber w' - decreeNumber w0')
                      if takeSnapshot && isNothing mdumper then do
                        say $ "Log size when trimming: " ++ show (Map.size log)
                        -- dump the snapshot asynchronously
                        dumper <- spawnLocal $ do
                                    dumper <- getSelfPid
                                    sref' <- stLogDump w' s'
                                    usend self (w', sref', dumper)
                        return $ Just (w', dumper)
                      else
                        return mdumper
                st' <- case v of
                  Values xs -> {-# SCC "Execute/Values" #-} do
                      nlogTrace logId $
                        "Executing decree: " ++ show (w, di, d, cd)
                      s' <- foldM stLogNextState s xs
                      let d'  = max d w'
                          cd' = max cd w'
                          w'  = succ w
                      mdumper' <- maybeTakeSnapshot w' s'
                      updateWatermark w'
                      return st { stateUnconfirmedDecree = d'
                                , stateCurrentDecree     = cd'
                                , stateSnapshotDumper    = mdumper'
                                , stateWatermark         = w'
                                , stateLogState          = s'
                                }
                  Reconf leg' ρs'
                    -- Only execute a reconfiguration if we are on an earlier
                    -- configuration.
                    | decreeLegislatureId d < leg' -> {-# SCC "Execute/Reconf" #-} do
                      nlogTrace logId $ "Reconfiguring: " ++
                                 show (di, w, d, leg', cd, ρs')
                      let d' = w' { decreeNumber = max (decreeNumber d) (decreeNumber w') }
                          cd' = w' { decreeNumber = max (decreeNumber cd) (decreeNumber w') }
                          w' = succ w{decreeLegislatureId = leg'}

                      -- Update the list of acceptors of the proposer...
                      updateAcceptors ρs'

                      mdumper' <- maybeTakeSnapshot w' s

                      -- Tick.
                      usend self Status

                      let epoch' = if take 1 ρs' /= take 1 ρs
                                    then decreeLegislatureId d
                                    else epoch
                          legD' = DecreeId leg' $ decreeNumber di

                      mbpid <- whereis (batcherLabel logId)
                      -- Update the epoch and membership of the batcher if there
                      -- is any.
                      when (epoch /= epoch' || sort ρs /= sort ρs') $
                        forM_ mbpid $ flip usend (epoch', ρs')
                      mLeader <- getLeader requestStart ρs'
                      bpid' <- case mbpid of
                        Nothing | mLeader == Just here -> do
                          bpid' <- spawnLocal $ do
                            nlogTrace logId "respawned batcher"
                            link self >> reportTermination "batcher"
                              (batcher (sendBatch self) (epoch', ρs'))
                          register (batcherLabel logId) bpid'
                          return bpid'
                        Just bpid' -> return bpid'
                        Nothing -> return bpid

                      updateWatermark w'
                      return st { stateBatcher = bpid'
                                , stateReplicas = ρs'
                                , stateUnconfirmedDecree = d'
                                , stateCurrentDecree = cd'
                                , stateEpoch = epoch'
                                , stateReconfDecree = legD'
                                , stateSnapshotDumper = mdumper'
                                , stateWatermark = w'
                                }
                    | otherwise -> {-# SCC "Execute/otherwise" #-} do
                      let w' = succ w{decreeLegislatureId = succ (decreeLegislatureId w)}
                      say $ "Not executing " ++ show (di, w, d, leg', cd)
                      mdumper' <- maybeTakeSnapshot w' s
                      updateWatermark w'
                      return st { stateSnapshotDumper    = mdumper'
                                , stateWatermark = w'
                                }
                -- Restart the timer to compete for the lease.
                let requestStart' = max requestStart leaseStart
                mLeader <- getLeader requestStart' (stateReplicas st')
                leaseStart' <- if mLeader == Just here
                  then setLeaseRenewTimer rtimerPid ttimerPid requestStart'
                  else do
                    usend rtimerPid $ adjustForDrift leaseTimeout
                    liftIO $ getTime Monotonic
                go st' { stateLeaseStart = leaseStart' }

              -- Dumping a snapshot finished.
            , match $ \(w0', sref', dumper') -> do
                -- Only heed if the snapshot is newer than our last known
                -- snapshot.
                nlogTrace logId $ "Response from dumper " ++
                           show (w0', dumper', mdumper)
                if w0' > w0 then do
                  say "Trimming log."
                  liftIO $ trimTheLog ph (decreeNumber w0)
                  prl_releaseDecreesBelow (sendAcceptor logId) here w0
                  go st{ stateSnapshotDumper    =
                           if Just dumper' == fmap snd mdumper then Nothing
                             else mdumper
                       , stateSnapshotRef       = Just sref'
                       , stateSnapshotWatermark = w0'
                       }
                else
                  go st

              -- If we get here, it's because there's a gap in the decrees we
              -- have received so far.
              --
              -- XXX: We store the decree but do not notify the client. Some
              -- tests expect that notifying the client happens only when the
              -- replica is ready to execute the decree (in order to know that
              -- a quorum of replicas has reconfigured).
              --
              -- We don't query missing decrees here, or it would cause quering
              -- too often. Queries will happen when the replica receives a
              -- 'Max' message.
            , matchIf (\(Decree _ locale di _) ->
                        locale == Remote && w < di && not (Map.member (decreeNumber di) log)) $ {-# SCC "go/other" #-}
                       \(Decree requestStart locale di v) -> do
                  nlogTrace logId $
                    "Storing decree above watermark: " ++ show (w, di)
                  doPersistenceOpAsync $ do
                    liftIO $ insertInLog ph (decreeNumber di) v
                    --- XXX set cd to @max cd (succ di)@?
                    --
                    -- Probably not, because then the replica might never find the
                    -- values of decrees which are known to a quorum of acceptors
                    -- but unknown to all online replicas.
                    --
                    --- XXX set d to @min cd (succ di)@?
                    --
                    -- This Decree could have been teleported. So, we shouldn't
                    -- trust di, unless @decreeLegislatureId di < maxBound@.
                    --
                    -- XXX: Resending the decree may cause decrees to be stored
                    -- more than once, but this is necessary while it is
                    -- possible for this decree to be unreachable. We want it to
                    -- be overwritten by a decree in the right legislature when
                    -- the watermark reaches it.
                    --
                    -- TODO: are unreachable decrees currently possible? Every
                    -- decree inserted like this in the mailbox is rechecked
                    -- over an over whenever we execute 'receiveWait'.
                    --
                    usend self $ Decree requestStart locale di v
                  go st

              -- Message from the batcher
              --
              -- XXX The guard avoids proposing values for unreachable decrees.
            , matchIf (\_ -> cd == w) $ {-# SCC "go/batcher" #-} \(rs :: [BatcherMsg a]) -> do
                  mLeader <- getLeader leaseStart ρs
                  nlogTrace logId $ "replica: request from batcher "
                             ++ show (cd, mLeader, ρs)
                  (s', cd', lastProposed') <- case mLeader of
                     -- Drop the request and ask for the lease.
                     Nothing | elem here ρs -> do
                       proposeLeaseRequest ppid cd [] ρs
                       -- Kill the batcher.
                       exitAndWait bpid
                       return (s, succ cd, Just cd)

                     -- I'm the leader, so handle the request.
                     Just leader | here == leader -> do
                       let values (Values xs) = xs
                           values _           = []
                       if all
                            ((Nullipotent ==) . requestHint . batcherMsgRequest)
                            rs
                       then do
                         nlogTrace logId "replica: nullipotent requests"
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
                           flip usend True
                         return (s', cd, lastProposed)
                       else do
                         nlogTrace logId $
                           "replica: non-nullipotent requests. " ++ show (length rs)
                         let (rs', old) =
                               partition ((epoch <=) . batcherMsgEpoch) rs
                         -- Notify the ambassadors of old requests.
                         forM_ (map batcherMsgAmbassador old) $
                           flip usend (epoch, ρs)
                         case rs' of
                           -- Notify the batcher.
                           [] -> do
                             usend bpid ()
                             nlogTrace logId
                               "replica: no non-nullipotent requests."
                             return (s, cd, lastProposed)
                           BatcherMsg { batcherMsgRequest = r } : _ -> do
                             let updateLeg (Reconf _ ρs') =
                                  Reconf (succ $ decreeLegislatureId legD) ρs'
                                 updateLeg v = v
                             nlogTrace logId
                               "replica: Sending batch to proposer."
                             now <- liftIO $ getTime Monotonic
                             usend ppid $ ProposerRequest
                               { prDecree      = cd
                               , prFromBatcher = True
                               , prStart       = now
                               , prRequest     = if isReconf $ requestValue r
                                 then r { requestValue =
                                            updateLeg $ requestValue r
                                        }
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
                                   }
                               }
                             return (s, succ cd, Just cd)

                     -- Drop the request.
                     _ -> do
                       -- Notify the batcher.
                       usend bpid ()
                       -- Notify the ambassadors.
                       forM_ (map batcherMsgAmbassador rs) $
                         flip usend (epoch, ρs)
                       -- Kill the batcher.
                       exitAndWait bpid
                       return (s, cd, lastProposed)

                  go st{ stateLastProposed = lastProposed'
                       , stateCurrentDecree = cd'
                       , stateLogState = s'
                       }

              -- Message from the proposer process
              --
              -- The request is dropped if the decree was accepted with a
              -- different value already.
            , match $ {-# SCC "go/Proposer" #-}
                  \(vi, ProposerRequest di fromBatcher requestStart
                                        (Request κs (v :: Value a) _)) -> do
                  -- If the passed decree accepted other value than our
                  -- client's, don't treat it as local (ie. do not report back
                  -- to the client yet).
                  let passed = v == vi
                      pids = if fromBatcher then [bpid] else []
                      locale = if passed then Local κs pids else Remote
                  usend self $ Decree requestStart locale di vi
                  forM_ others $ \ρ -> do
                    sendReplicaAsync sendPool logId ρ $
                      Decree requestStart Remote di vi

                  nlogTrace logId $ "replica: proposal result " ++
                             show (di, passed, fromBatcher)
                  when (not passed && fromBatcher) $ do
                    -- Send rejection ack.
                    usend bpid ()
                    -- Notify the clients.
                    forM_ κs $ flip usend False

                  -- Avoid moving to unreachable decrees.
                  let d' = if d == cd then d else min cd (max d (succ di))
                  go st { stateUnconfirmedDecree = d' }

              -- Message from the proposer process
              --
              -- The proposer rejected or aborted the request.
            , match $ {-# SCC "go/ProposerRejected" #-}
                  \(ProposerRequest _ fromBatcher _ (Request senders (_ :: Value a) _)) ->
                do
                  when fromBatcher $ do
                    usend bpid ()
                    forM_ senders $ flip usend False
                  go st { stateLastProposed = Nothing }

              -- Try to service a query if the requested decree is not too old.
            , matchIf (\(Query _ n) -> fst (Map.findMin log) <= n) $ {-# SCC "go/Query" #-}
                       \(Query ρ n) -> do
                  case Map.lookup n log of
                            -- See Note [Teleportation].
                    Just v -> usend ρ $ Decree 0 Remote (DecreeId maxBound n) v
                    Nothing -> return ()
                  go st

              -- The decree of the query is old-enough.
            , match $  {-# SCC "go/Query2" #-} \(Query ρ n) -> do
                  case msref of
                    Just sref -> usend ρ $
                      SnapshotInfo ρs legD epoch sref w0 n
                    Nothing   -> return ()
                  go st

              -- Get the state from another replica if it is newer than ours
              -- and the original query has not been satisfied.
              --
              -- It does not quite eliminate the chance of multiple snapshots
              -- being read in cascade, but it makes it less likely.
            , match $ {-# SCC "go/SnapshotInfo" #-} \(SnapshotInfo ρs' legD' epoch' sref' w0' n) ->
                  if not (Map.member n log) && decreeNumber w <= n &&
                     decreeNumber w < decreeNumber w0' then do

                    let legD'' = max legD legD'
                        leg'' = decreeLegislatureId legD''
                        epoch'' = if legD < legD' then epoch' else epoch
                        ρs'' = if legD < legD' then ρs' else ρs

                    when (legD < legD') $
                      liftIO $ insertInLog ph (decreeNumber legD') $
                          Reconf (decreeLegislatureId legD') ρs'

                    -- Trimming here ensures that the log does not accumulate
                    -- decrees indefinitely if the state is oftenly restored
                    -- before saving a snapshot.
                    liftIO $ trimTheLog ph (decreeNumber w0)

                    when (legD < legD') $ updateAcceptors ρs'

                    -- TODO: get the snapshot asynchronously
                    st' <- restoreSnapshot (stLogRestore sref') >>= \case
                             Nothing -> return st
                             Just s' -> do
                               updateWatermark w0'
                               return st
                                         { stateSnapshotRef       = Just sref'
                                         , stateWatermark         = w0'
                                         , stateSnapshotWatermark = w0'
                                         , stateLogState          = s'
                                         }
                    now <- liftIO $ getTime Monotonic

                    let d'  = DecreeId leg'' (max (decreeNumber w0')
                                                  (decreeNumber d))
                        cd' = DecreeId leg'' (max (decreeNumber w0')
                                                  (decreeNumber cd))
                    go st' { stateLeaseStart        = now
                           , stateReplicas          = ρs''
                           , stateUnconfirmedDecree = d'
                           , stateCurrentDecree     = cd'
                           , stateEpoch             = epoch''
                           , stateReconfDecree      = legD''
                           }
                  else go st

              -- Upon getting the max decree of another replica, compute the
              -- gaps and query for those.
            , matchIf (\(Max _ d' _ _ _) -> decreeNumber d < decreeNumber d') $ {-# SCC "go/Max" #-}
                       \(Max ρ d' legD' epoch' ρs') -> do
                  say $ "Got Max " ++ show d'

                  when (legD < legD') $
                    doPersistenceOpAsync $
                      liftIO $ insertInLog ph (decreeNumber legD') $
                        Reconf (decreeLegislatureId legD') ρs'

                  queryMissingFrom sendPool logId (decreeNumber w)
                    [processNodeId ρ] $
                    Map.insert (decreeNumber d') undefined log

                  let legD'' = max legD legD'
                      leg'' = decreeLegislatureId legD''
                      epoch'' = if legD < legD' then epoch' else epoch
                      ρs'' = if legD < legD' then ρs' else ρs
                      d'' = DecreeId leg'' $ decreeNumber d'

                  when (legD < legD') $ updateAcceptors ρs'
                  now <- liftIO (getTime Monotonic)

                  let cd' = max d'' cd
                  go st
                    { stateLeaseStart = now
                    , stateUnconfirmedDecree = d''
                    , stateCurrentDecree = cd'
                    , stateReplicas = ρs''
                    , stateEpoch = epoch''
                    , stateReconfDecree = legD''
                    }

              -- Ignore max decree if it is lower than the current decree.
            , matchIf (\_ -> otherwise) $ \(_ :: Max) -> do
                  go st

              -- Replicas are going to join or leave the group.
              -- The leader needs to be up-to-date so the membership given to
              -- cpolicy is the last one.
            , matchIf (\(_, e, _) -> epoch <= e && cd == w) $ {-# SCC "go/Leave" #-}
                       \(μ, _, Helo π cpolicy) -> do

                  policy <- unClosure cpolicy
                  let ρs' = nub $ policy ρs
                      -- Place the proposer at the head of the list
                      -- of replicas to be considered as future leader.
                      ρs'' | elem here ρs' = here : filter (/= here) ρs'
                           | otherwise     = ρs'

                  mLeader <- getLeader leaseStart ρs
                  nlogTrace logId $ "replica: helo request from client " ++
                             show (π, mLeader)
                  case mLeader of
                    -- I'm the leader, so handle the request.
                    Just leader | here == leader -> do

                      -- Get self to propose reconfiguration...
                      usend bpid ( μ
                                 , epoch
                                 , Request
                                     { requestSender   = [π]
                                     , requestValue    =
                                         Reconf (succ (decreeLegislatureId d))
                                                ρs'' :: Value a
                                     , requestHint     = None
                                     }
                                 )

                      go st

                    -- Drop the request.
                    _ -> do
                      exitAndWait bpid
                      usend π False
                      when (elem here ρs) $ usend μ (epoch, ρs)
                      go st

            , matchIf (\(_, e, _) -> e < epoch) $
                      \(μ, e, Helo π _) -> do
                  nlogTrace logId $ "Rejecting helo request " ++ show (e, epoch)
                  usend π False
                  usend μ (epoch, ρs)
                  go st

              -- The group is trying to recover.
            , matchIf (\(_, e, _) -> epoch <= e) $ {-# SCC "go/Recover" #-}
                       \(μ, _, Recover π ρs') -> do
                  -- Place the proposer at the head of the list
                  -- of replicas to be considered as future leader.
                  let ρs'' | elem here ρs' = here : filter (/= here) ρs'
                           | otherwise     = ρs'

                  mLeader <- getLeader leaseStart ρs >>= \case
                    -- Accept the leader only if a quorum of the old membership
                    -- is a quorum of the new membership.
                    Just nid | elem nid ρs''
                             , let li = length (intersect ρs ρs'')
                             , li >= 1 + length ρs'' `div` 2
                             , li >= 1 + length ρs `div` 2
                      -> return $ Just nid
                    _ -> return Nothing

                  nlogTrace logId $ "replica: Recover request from client " ++
                             show (π, mLeader, ρs'')
                  case mLeader of
                    -- Ask for the lease using the proposed membership.
                    -- Thus reconfiguration is possible even when the group has
                    -- no leaders and there is no quorum to elect one.
                    --
                    -- We only recover if the replica is part of the new
                    -- group.
                    Nothing | elem here ρs' -> do
                      -- Synchronize acceptors acceptors.
                      --
                      -- 'callLocal' allows the task to be aborted if the
                      -- replica gets an asynchronous exception. Otherwise it
                      -- would be caught in the internal 'try'.
                      edvs <- callLocal $ try $ do
                        -- Stop if the connection to the client is lost.
                        link π
                        parentPid <- getSelfPid
                        -- Poll the client node for prompt detection of
                        -- connection failures.
                        _ <- spawnLocal $ do
                          link π >> link parentPid
                          forever $ do
                            -- TODO: Make this a configurable delay?
                            _ <- receiveTimeout 1000000 []
                            usend (nullProcessId (processNodeId π)) ()

                        prl_sync (sendAcceptor logId) ρs'
                        -- Update this replica
                        prl_query (sendAcceptor logId) ρs' w

                      case edvs :: Either SomeException [(DecreeId, Value a)] of
                        -- Caught up and no gaps in the result
                        Right dvs
                            | null dvs
                              || and (zipWith (==)
                                       (nub $ map (decreeNumber . fst) dvs)
                                       [decreeNumber w..]
                                     )
                            -> do
                          nlogTrace logId
                            "replica: recovery synchronized acceptors"
                          let trimUnreachable [] _ = []
                              trimUnreachable (p@(di, v) : ds) leg =
                                if decreeLegislatureId di < leg
                                then trimUnreachable ds leg
                                else (p :) $ trimUnreachable ds $
                                       (if isReconf v then succ else id)
                                       (decreeLegislatureId di)

                              dvs' = trimUnreachable dvs (decreeLegislatureId w)
                          forM_ dvs' $ \(di, vi :: Value a) ->
                            sendReplicaAsync sendPool logId here $
                              Decree 0 Remote di vi
                          -- Submit the reconfiguration request.
                          let d' = if null dvs' then d
                                   else max d $ succ $
                                    let (dm@(DecreeId dmleg dmn), v) = last dvs'
                                     in if isReconf v
                                        then DecreeId (succ dmleg) dmn
                                        else dm
                          proposeLeaseRequest ppid d' [π] ρs''

                          -- Update the list of acceptors of the proposer, so we
                          -- have a chance to succeed.
                          updateAcceptors ρs'

                          -- Get any missing decrees from the other replicas.
                          queryMissingFrom sendPool logId (decreeNumber w)
                            ρs' $
                            Map.insert (decreeNumber d') undefined $
                            foldr (\(di, vi) -> Map.insert (decreeNumber di) vi)
                                  log dvs'

                          go st { stateUnconfirmedDecree = d'
                                , stateCurrentDecree = max (succ d') cd
                                , stateLastProposed  = Just d'
                                }

                        -- Didn't catch up on time
                        _ -> do
                          nlogTrace logId $ "replica: recovery failed with " ++
                                     show (fmap (map fst) edvs)
                          go st

                    -- I'm the leader, so handle the request.
                    Just leader | here == leader -> do

                      -- Get self to propose reconfiguration...
                      usend bpid ( μ
                                 , epoch
                                 , Request
                                     { requestSender   = [π]
                                     , requestValue    =
                                         Reconf (succ (decreeLegislatureId d))
                                                ρs'' :: Value a
                                     , requestHint     = None
                                     }
                                 )

                      go st

                    -- Drop the request.
                    _ -> do
                      usend π False
                      when (elem here ρs) $ usend μ (epoch, ρs)
                      go st

            , matchIf (\(_, e, _) -> e < epoch) $
                      \(μ, _, Recover π ρs') -> do
                -- When recovering it doesn't help sending the old membership.
                -- Send instead the new membership, perhaps adjusted to use the
                -- current leader if it belongs to it.
                mLeader <- getLeader leaseStart ρs
                let ρs'' = case mLeader of
                      Just ρ | elem ρ ρs' -> ρ : filter (/= ρ) ρs'
                      _                   -> ρs'
                usend μ (epoch, ρs'')
                usend π False
                go st

              -- An ambassador wants to know who the leader is.
            , match $ \μ -> do
                  nlogTrace logId $
                    "replica: leader query: " ++ show (μ, epoch, ρs)
                  when (elem here ρs) $ usend μ (epoch, ρs)
                  go st

            , match $ {-# SCC "go/ConfigQuery" #-} \(ConfigQuery sender) -> do
                  liftIO (readGroupConfig $ persistentStore ph) >>= usend sender
                  go st

            , matchIf (\_ -> w == cd) $ \(μ, e, MembershipQuery sender) -> do
                mLeader <- getLeader leaseStart ρs
                if mLeader == Just here then
                  usend sender $ Just (legD, ρs)
                else do
                  usend sender (Nothing :: Maybe (DecreeId, [NodeId]))
                  exitAndWait bpid
                when (e < epoch || isJust mLeader) $
                  when (elem here ρs) $ usend μ (epoch, ρs)
                go st

            -- Clock tick - time to advertize. Can be sent by anyone to any
            -- replica to provoke status info.
            , match $ {-# SCC "go/Status" #-} \Status -> do
                  -- Forget about all previous ticks to avoid broadcast storm.
                  fix $ \loop ->
                    expectTimeout 0 >>= maybe (return ()) (\() -> loop)

                  nlogTrace logId $ "Status info:" ++
                      "\n\tunconfirmed decree: " ++ show d ++
                      "\n\tdecree:             " ++ show cd ++
                      "\n\twatermark:          " ++ show w ++
                      "\n\treplicas:           " ++ show ρs
                  forM_ others $ \ρ -> sendReplicaAsync sendPool logId ρ $
                    Max self d legD epoch ρs
                  go st
            ]

dictList :: SerializableDict a -> SerializableDict [a]
dictList SerializableDict = SerializableDict

dictNodeId :: SerializableDict NodeId
dictNodeId = SerializableDict

-- | The configuration data needed to operate a group
data GroupConfig a = GroupConfig
       (Static (Dict (Eq a)))
       (Static (SerializableDict a))
       (Closure Config)
       (Closure (Log a))
   deriving (Typeable, Generic)

instance Typeable a => Binary (GroupConfig a)

-- | A handle to a log created remotely. A 'RemoteHandle' can't be used to
-- access a log, but it can be cloned into a local handle.
data RemoteHandle a =
    RemoteHandle
       (Static (Dict (Eq a)))
       (Static (SerializableDict a))
       (Closure Config)
       (Closure (Log a))
       [NodeId]
    deriving (Typeable, Generic)

instance Typeable a => Binary (RemoteHandle a)

-- | Yields the path to the persisted state in the local node.
localLogPath :: LogId -> (NodeId -> FilePath) -> Process FilePath
localLogPath (LogId idstr) pDirectory = do
    here <- getSelfNode
    return $ pDirectory here </> "replicated-log" </> idstr

-- | @withLogIdLock k p@ spawns a process to execute @p@ and waits for it to
-- complete. The process is granted a lock for log id @k@.
--
-- Ensures that there is at most one process holding the lock for log id @k@.
--
withLogIdLock :: LogId -> Process a -> Process a
withLogIdLock (LogId idstr) action = callLocal go
  where
    lockLabel = "replicated-log/" ++ idstr ++ ".lock"
    go = do
      self <- getSelfPid
      join $ catch (do register lockLabel self
                       return action
                   ) $
        \(ProcessRegistrationException _ _) -> do
          mpid <- whereis lockLabel
          case mpid of
            Nothing -> return go
            Just pid -> bracket (monitor pid) unmonitor $ \r ->
              receiveWait
                [ matchIf (\(ProcessMonitorNotification r' _ _) -> r' == r)
                          (const $ return go)
                ]

-- | Runs the given action if there is no local replica.
ifNoLocalReplica :: LogId -> Process () -> Process ()
ifNoLocalReplica k action = do
    mpid <- whereis (replicaLabel k)
    when (isNothing mpid) action

type StoredGroupConfig = ( Static (Some SerializableDict)
                         , BSL.ByteString
                         , (DecreeId, [NodeId])
                         )

-- | Stores the configuration of a group.
storeConf :: (ProcessId, StoredGroupConfig) -> Process ()
storeConf (caller, (ssdict2, bs, membership)) = do
    r <- try $ do
      Some (SerializableDict :: SerializableDict a) <- unStatic ssdict2
      let GroupConfig _ _ cConfig _ = decode bs :: GroupConfig a
      config <- unClosure cConfig
      let k  = logId config
      path <- localLogPath k (persistDirectory config)

      withLogIdLock k $ ifNoLocalReplica k $
        withPersistentStore path $ \ps -> liftIO $ do
          km <- P.getMap ps $ fromString "config"
          mk' <- fmap (fmap decode) $ liftIO $ P.lookup km (0 :: Int)
          case mk' of
            Just k' | k /= k' -> error $
              "storeConf: distinct log identities: (stored, looked up) " ++
              show (k', k)
            Just _  -> return ()
            Nothing -> do
              P.atomically ps
                [ P.Insert km (0 :: Int) $ encode k
                , P.Insert km 1          $ encode ssdict2
                , P.Insert km 2            bs
                , P.Insert km 3          $ encode membership
                ]
    either (usend caller . show) (usend caller) (r :: Either SomeException ())

-- | Reads a GroupConfig from the local persisted state.
readGroupConfig :: PersistentStore -> IO StoredGroupConfig
readGroupConfig ps = do
      km <- P.getMap ps $ fromString "config"
      (,,) <$> (P.lookup km (1 :: Int) >>=
                 maybe (error "readGroupConfig: missing static dict")
                       (return . decode)
               )
           <*> (P.lookup km 2 >>=
                 maybe (error "readGroupConfig: missing config") return
               )

           <*> (P.lookup km 3 >>=
                 maybe (error "readGroupConfig: missing membership")
                       (return . decode)
               )

-- | Spawns a replica in the local node if it has not been spawned already.
--
-- Sends an answer to the given process: either @Right ()@ in case of success
-- or @Left error_message@.
--
spawnLocalReplica :: (LogId, ProcessId, TimeSpec)
                  -> (NodeId -> FilePath)
                  -> Process ()
spawnLocalReplica (k, caller, ts0) pDirectory = do
    r <- try $ withLogIdLock k $ ifNoLocalReplica k $ do
           path <- localLogPath k pDirectory
           exist <- liftIO $ doesDirectoryExist path
           if exist
              then withPersistentStore path $ \ps -> do
                (ssdict2, bs, m) <- liftIO $ readGroupConfig ps
                Some (SerializableDict :: SerializableDict a) <- unStatic ssdict2
                spawnR (decode bs :: GroupConfig a) m
              else do
                cwd <- liftIO getCurrentDirectory
                error $ "no persisted storage found (" ++ show (cwd, path) ++ ")"
    either (usend caller . ("spawnLocalReplica: " ++) . show)
           (usend caller)
           (r :: Either SomeException ())
  where
    spawnR :: Typeable a => GroupConfig a -> (DecreeId, [NodeId]) -> Process ()
    spawnR (GroupConfig sdict1 sdict2 cConfig cLog) (legD, nodes) = do
      dict1 <- unStatic sdict1
      dict2 <- unStatic sdict2
      config <- unClosure cConfig
      log <- unClosure cLog
      here <- getSelfNode

      localSpawnAndRegister (acceptorLabel $ logId config) $
        prl_acceptor (consensusProtocol config (dictValue dict2))
                     (sendAcceptor $ logId config)
                     legD
                     here

      localSpawnAndRegister (replicaLabel $ logId config) $
        replica dict1 dict2 config log ts0 initialDecreeId legD
                nodes

    dictValue :: SerializableDict a -> SerializableDict (Value a)
    dictValue SerializableDict = SerializableDict

-- | @localSpawnAndRegister label p@ spawns a process locally
-- which runs @p@ and registers the process with the given @label@.
--
-- If the process cannot be registered, the closure is not run.
--
localSpawnAndRegister :: String -> Process () -> Process ()
localSpawnAndRegister lbl p = do
    pid <- spawnLocal $ do
             () <- expect
             p
    r <- try $ register lbl pid
    either (\(ProcessRegistrationException _ _) ->
                  exit pid "localSpawnAndRegister"
           )
           (usend pid)
           r

mkSomeSDict :: SerializableDict a -> Some SerializableDict
mkSomeSDict = Some

persistDirectoryClosure :: () -> Config -> NodeId -> FilePath
persistDirectoryClosure () = persistDirectory

remotable [ 'dictList
          , 'dictNodeId
          , 'storeConf
          , 'spawnLocalReplica
          , 'mkSomeSDict
          , 'persistDirectoryClosure
          ]

listNodeIdClosure :: [NodeId] -> Closure [NodeId]
listNodeIdClosure xs =
    closure (staticDecode ($(mkStatic 'dictList) `staticApply` sdictNodeId))
            (encode xs)
 where _ = $(functionTDict 'storeConf) -- stops unused warning

-- | Serialization dictionary for 'NodeId'
sdictNodeId :: Static (SerializableDict NodeId)
sdictNodeId = $(mkStatic 'dictNodeId)

nodeIdClosure :: NodeId -> Closure NodeId
nodeIdClosure x = closure (staticDecode sdictNodeId) (encode x)

-- | Messages that must be delivered in order to the ambassador
data OrderedMessage a = OMRequest (Request a)
                      | OMHelo Helo
                      | OMRecover Recover

-- | Hide the 'ProcessId' of the ambassador to a log behind an opaque datatype
-- making it clear that the ambassador acts as a "handle" to the log - it does
-- not uniquely identify the log, since there can in general be multiple
-- ambassadors to the same log.
data Handle a =
    Handle (Static (Dict (Eq a)))
           (Static (SerializableDict a))
           (Closure Config)
           (Closure (Log a))
           (TChan (OrderedMessage a))
           ProcessId
    deriving (Typeable, Generic)

instance Eq (Handle a) where
    Handle _ _ _ _ _ μ == Handle _ _ _ _ _ μ' = μ == μ'

-- | State of the ambassadors
--
-- Ambassadors look if replicas have a batcher process to determine if they are
-- leaders. The batcher is then monitored and the 'MonitorRef' is stored in the
-- state.
--
-- When the leader is unknown, the ambassador polls the replicas periodically
-- asking for the latest membership and querying the registry for the batcher
-- process. A timer is used to throttle the rate of queries. The timer pid and
-- the channel for timer notifications are both stored in the state.
--
data AmbassadorState = AmbassadorState
    { asTimerPid :: ProcessId     -- Timer used for throtling membership queries
    , asTimerRP  :: ReceivePort () -- The channel for timer notifications
    , asEpoch    :: LegislatureId -- The epoch of the replicas
    , asLeader   :: Maybe (MonitorRef, ProcessId) -- The leader batcher if known
    , asReplicas :: [NodeId]      -- The last known membership (never empty)
    }

-- | The ambassador to a group is a local process that stands as a proxy to
-- the group. Its sole purpose is to provide a 'ProcessId' to stand for the
-- group and to forward all messages to it.
ambassador :: forall a. SerializableDict a
           -> Config
           -> TChan (OrderedMessage a)
           -> [NodeId]
           -> Process ()
ambassador _ _ _ [] = do
    say "ambassador: Set of replicas must be non-empty."
    die "ambassador: Set of replicas must be non-empty."
ambassador SerializableDict Config{logId, leaseTimeout} omchan replicas =
    do self <- getSelfPid
       (sp, rp) <- newChan
       timerPid <- spawnLocal $ link self >> timer sp
       forM_ replicas $ flip whereisRemoteAsync (batcherLabel logId)
       -- Set it to 1 sec initially, so that the cluster bootstrap does not
       -- depend on the leaseTimeout. Otherwise, the RC startup may be delayed
       -- on a big leaseTimeouts and the satellites won't be able to start
       -- during the bootstrap process. Especially, on multi-node-TS configs.
       usend timerPid (1000000 :: Int)
       go AmbassadorState
         { asTimerPid = timerPid
         , asTimerRP  = rp
         , asEpoch    = 0
         , asLeader   = Nothing
         , asReplicas = replicas
         }
      `finally` nlogTrace logId "ambassador: terminated"
  where
    go :: AmbassadorState -> Process b
    go st@(AmbassadorState timerPid rpt epoch mRefLeader ρs) = do
     let mLeader = fmap snd mRefLeader
         mRef    = fmap fst mRefLeader
     -- We want to read from channels and the mailbox fairly, so we first check
     -- channels and then the mailbox.
     _ <- receiveTimeout 0
       [ matchSTM (readTChan omchan) $ handleRequest epoch mLeader ]
     _ <- receiveTimeout 0
       [ matchChan rpt $ \() -> handleTimerTick timerPid ρs mLeader mRef ]
     receiveWait $
      (if schedulerIsEnabled
       then [match $ \() -> go st]
       else []
      ) ++
      [ match $ \(Clone δ) -> do
          usend δ ρs
          go st

      , match $ \Status -> do
          Foldable.forM_ (processNodeId <$> mLeader) $ \ρ ->
            sendReplica logId ρ Status
          go st

        -- The leader replica changed.
      , match $ \(epoch', ρs') -> do
          -- Only update the replicas if they are at the same or higher
          -- epoch.
          --
          -- TODO: use @epoch < epoch'@ here?
          --
          if epoch <= epoch' then do
            nlogTrace logId $ "ambassador: Old epoch changed "
                              ++ show (mLeader, ρs)
                              ++ ". The new membership is " ++ show ρs' ++ "."
            forM_ ρs' $ flip whereisRemoteAsync (batcherLabel logId)
            usend timerPid leaseTimeout
            go st { asEpoch    = epoch'
                  , asReplicas = ρs'
                  }
          else do
            when (isNothing mLeader) $
              -- Give some time to other replicas to elect a leader.
              usend timerPid leaseTimeout
            go st

      , match $ \pmn@(ProcessMonitorNotification ref' _ _) -> do
          nlogTrace logId $ "ambassador: Received " ++ show pmn
          if mRef == Just ref'
          then do
            nlogTrace logId $ "ambassador: Replica disconnected or died. "
                              ++ show (mLeader, ρs)
            -- Give some time to other replicas to elect a leader.
            usend timerPid leaseTimeout
            go st { asLeader = Nothing }
          else
            go st

        -- A node replied whether it has a batcher.
      , match $ \wr@(WhereIsReply _ mb) -> do
          nlogTrace logId $ "ambassador: Received " ++ show wr
          case mb of
            -- No batcher
            Nothing -> go st
            -- There is a batcher.
            Just b  -> do
              mapM_ unmonitor mRef
              ref <- monitor b
              let ρ = processNodeId b
              go st { asLeader = Just (ref, b)
                      -- Make sure the leader is in the membership.
                    , asReplicas = ρ : filter (/= ρ) ρs
                    }

        -- A new replica was added to the group.
      , match $ \ρ -> do
          go st { asReplicas = filter (/= ρ) ρs ++ [ρ] }

        -- A membership query
      , match $ \mq -> do
          self <- getSelfPid
          Foldable.forM_ (processNodeId <$> mLeader) $ \ρ ->
            sendReplica logId ρ (self, epoch, mq :: MembershipQuery)
          go st

        -- A configuration query
      , match $ \cq -> do
          Foldable.forM_ (processNodeId <$> mLeader) $ \ρ ->
            sendReplica logId ρ (cq :: ConfigQuery)
          go st

        -- A client wants to monitor the replicas
      , match $ \sp -> do
          nlogTrace logId $ "ambassador: a client wants to know the leader " ++
                            show (mLeader, sp)
          sendChan sp mLeader
          go st

        -- The timer expired.
      , matchChan rpt $ \() -> do
          handleTimerTick timerPid ρs mLeader mRef
          go st

      , matchSTM (readTChan omchan) $ \om -> do
          handleRequest epoch mLeader om
          go st
      ]

    handleTimerTick timerPid ρs mLeader mRef = do
      case mLeader of
        Nothing -> do
          mapM_ unmonitor  mRef
          nlogTrace logId $ "ambassador: Timer expired. " ++ show (ρs, leaseTimeout)
          forM_ ρs $ flip whereisRemoteAsync (batcherLabel logId)
          self <- getSelfPid
          forM_ ρs $ \ρ -> sendReplica logId ρ self
        Just b -> do
          -- Ping the leader node periodically to detect disconnections.
          nlogTrace logId $ "ambassador: ping leader. " ++ show b
          usend (nullProcessId (processNodeId b)) ()
      usend timerPid leaseTimeout

    handleRequest epoch mLeader = \case
      -- A request
      OMRequest a -> do
        self <- getSelfPid
        nlogTrace logId $ "ambassador: sending request to " ++ show mLeader
        case mLeader of
          Just b -> usend b (self, epoch, a :: Request a)
          Nothing     -> forM_ (requestSender a) $ flip usend False
      -- A reconfiguration request
      OMHelo m@(Helo sender _) -> do
        self <- getSelfPid
        nlogTrace logId $ "ambassador: sending helo request to " ++ show mLeader
        case mLeader of
          Just b  -> sendReplica logId (processNodeId b) (self, epoch, m)
          Nothing -> usend sender False
      -- A recovery request
      OMRecover m@(Recover _sender ρs') -> do
        self <- getSelfPid
        -- A recovery request does not need to go necessarily to the leader.
        -- The replicas might have lost quorum and could be unable to elect
        -- a new leader.
        let ρ  : _ = ρs'
            ρ' = case mLeader of
                   Just b | let r = processNodeId b
                          , elem r ρs' -> r
                   _ -> ρ
        nlogTrace logId $
          "ambassador: sending recover msg to " ++ show (ρ', mLeader, m)
        sendReplica logId ρ' (self, epoch, m)

    _ = $(functionTDict 'storeConf) -- stops unused warning

-- | Throws an error if the handle is remote. This is useful mostly to catch
-- mistakes in tests.
checkHandle :: String -> Handle a -> Process ()
checkHandle label (Handle _ _ _ _ _ μ) = do
    here <- getSelfNode
    when (here /= processNodeId μ) $ do
      let msg = label ++ ": the handle is not local (" ++ show μ ++ ")."
      say msg
      die msg

-- | Append an entry to the replicated log.
--
-- Returns @True@ on success. The client can retry it if it returns @False@.
--
append :: Serializable a => Handle a -> Hint -> a -> Process Bool
append h@(Handle _ _ cConfig _ omchan μ) hint x = getSelfPid >>= \caller ->
    callLocal $ do
    checkHandle "Log.append" h
    Config {..} <- unClosure cConfig
    nlogTrace logId $ "append: start " ++ show caller
    self <- getSelfPid
    liftIO $ atomically $ writeTChan omchan $ OMRequest $ Request
        { requestSender   = [self]
        , requestValue    = Values [x]
        , requestHint     = hint
        }
    nlogTrace logId $ "append: sending request to ambassador " ++ show μ
    when schedulerIsEnabled $ usend μ ()
    expect

-- Note [Log monitoring]
-- ~~~~~~~~~~~~~~~~~~~~~
--
-- The batcher process of replicas is observed to detect failures in requests.
--
-- The batcher is killed as soon as the replica realizes it is no longer the
-- leader replica. This means that after startup, only the leader replica has a
-- batcher.
--
-- Any requests in the batcher mailbox are discarded when the batcher is killed.
--
-- A monitor notification of the batcher means that likely the request has been
-- dropped; or that a connection failure to the node containing the leader
-- replica failed, in which case the acknowledgement will be lost.
--
-- The various api calls could still return a failure result (@False@ or
-- @Nothing@) even if there is not a monitor notification. This can happen when
-- the request is rejected for other causes, like having an old epoch.

-- | Monitors the log. When connectivity to the log is lost a process monitor
-- notification is sent to the caller. Lost connectivity could mean that there
-- was a connection failure or that a request was dropped for internal reasons.
monitorLog :: Handle a -> Process MonitorRef
monitorLog h@(Handle _ _ cConfig _ _ μ) = do
    checkHandle "Log.monitorLocal" h
    (sp, rp) <- newChan
    usend μ sp
    mb <- receiveChan rp
    cc <- unClosure cConfig
    nlogTrace (logId cc) $ "monitorLog: ambassador response " ++ show (μ, mb)
    maybe (fmap nullProcessId getSelfNode) return mb >>= monitor

-- | Monitors the local replica and sends a 'ProcessMonitorNotification' to the
-- caller when the local replica is not a leader anymore.
monitorLocalLeader :: Handle a -> Process MonitorRef
monitorLocalLeader (Handle _ _ _ _ _ μ) = do
    (sp, rp) <- newChan
    usend μ sp
    mb <- receiveChan rp
    here <- getSelfNode
    case mb of
      Just b | processNodeId b == here -> monitor b
      _ -> fmap nullProcessId getSelfNode >>= monitor

-- | Returns the 'NodeId' of the leader replica if known.
getLeaderReplica :: Handle a -> Process (Maybe NodeId)
getLeaderReplica (Handle _ _ cConfig _ _ μ) = do
    (sp, rp) <- newChan
    cc <- unClosure cConfig
    nlogTrace (logId cc) $ "getLeaderReplica: start " ++ show μ
    usend μ sp
    fmap processNodeId <$> receiveChan rp

-- | Make replicas advertize their status info.
status :: Serializable a => Handle a -> Process ()
status (Handle _ _ _ _ _ μ) = usend μ Status

-- | Updates the handle so it communicates with the given replica.
updateHandle :: Handle a -> NodeId -> Process ()
updateHandle (Handle _ _ _ _ _ α) = usend α

remoteHandle :: Handle a -> Process (RemoteHandle a)
remoteHandle h@(Handle sdict1 sdict2 config log _ α) = do
    checkHandle "remoteHandle" h
    self <- getSelfPid
    usend α $ Clone self
    RemoteHandle sdict1 sdict2 config log <$> expect

-- | Yields the latest known membership.
getMembership :: Handle a -> Process (Maybe [NodeId])
getMembership  (Handle _ _ _ _ _ α) = callLocal $ do
    self <- getSelfPid
    usend α $ MembershipQuery self
    fmap snd <$> (expect :: Process (Maybe (DecreeId, [NodeId])))

-- | Permanently associate a log identity to a given config, log and initial
-- membership.
--
-- Store that association at each node in the membership.
new :: Typeable a
    => Static (Dict (Eq a))
    -> Static (SerializableDict a)
    -> Closure Config
    -> Closure (Log a)
    -> [NodeId]
    -> Process ()
new sdict1 sdict2 config log nodes = callLocal $ do
    self <- getSelfPid
    forM_ nodes $ flip spawnAsync $
      $(mkClosure 'storeConf)
        ( self
        , ( $(mkStatic 'mkSomeSDict) `staticApply` sdict2
          , encode $ GroupConfig sdict1 sdict2 config log
          , (DecreeId 0 (-1), nodes)
          ) :: StoredGroupConfig
        )
    forM_ nodes $ const $
      receiveWait [ match logError, match (\() -> return ()) ]
  where
    logError s = do
      say $ "Control.Distributed.Log.new: " ++ s
      error s

-- | Spawns one replica process on each node in @nodes@ if it has not been
-- spawned already.
--
-- This operation fails with an exception if the node is not in a group created
-- with 'new'. The log id must be the one provided in the configuration when
-- creating the group.
--
-- The behaviour of each replica is determined by the @logClosure@ argument
-- given to 'new'.
spawnReplicas :: forall a. Typeable a
              => LogId                        -- ^ Id of the group
              -> Closure (NodeId -> FilePath) -- ^ Path to the persisted
                                              -- configuration
              -> [NodeId]                     -- ^ Nodes on which to start
                                              -- replicas
              -> Process (Handle a)
spawnReplicas k cPersisDirectory nodes = callLocal $ do
    self <- getSelfPid
    now <- liftIO $ getTime Monotonic
    forM_ nodes $ flip spawnAsync $
      $(mkClosure 'spawnLocalReplica) (k, self, now)
        `closureApply` cPersisDirectory

    forM_ nodes $ const $
      receiveWait [ match logError, match (\() -> return ()) ]

    case nodes of
      nid : _ -> do
        sendReplica k nid $ ConfigQuery self
        (_, bs, _) <- expect :: Process StoredGroupConfig
        let GroupConfig sdict1 sdict2 cConfig cLog =
              decode bs :: GroupConfig a
        clone $ RemoteHandle sdict1 sdict2 cConfig cLog nodes
      [] -> logError "empty list of nodes"
  where
    logError s = do
      say $ "Control.Distributed.Log.spawnReplicas: " ++ s
      error s

-- | Propose a reconfiguration according the given nomination policy. Note that
-- in general, it is only safe to remove replicas if they are /certainly/ dead.
--
-- Served only if the group has quorum.
--
-- Returns @True@ on success. The client can retry it if it returns @False@.
--
reconfigure :: Typeable a
            => Handle a
            -> Closure NominationPolicy
            -> Process Bool
reconfigure h@(Handle _ _ _ _ omchan μ) cpolicy = callLocal $ do
    checkHandle "Log.reconfigure" h
    self <- getSelfPid
    liftIO $ atomically $ writeTChan omchan $ OMHelo $ Helo self cpolicy
    when schedulerIsEnabled $ usend μ ()
    expect

-- ^ @recover h newMembership@
--
-- Makes the given membership the current one. Completes only if all replicas
-- are online.
--
-- Recovering is safe only if at least half of the replicas of the old
-- membership take part in the new membership (recovered replicas count as
-- replicas in the old membership).
--
-- Returns @True@ on success. The client can retry it if it returns @False@.
--
recover :: Handle a -> [NodeId] -> Process Bool
recover h@(Handle _ _ cConfig _ omchan μ) ρs = callLocal $ do
    checkHandle "Log.recover" h
    self <- getSelfPid
    Config {..} <- unClosure cConfig
    nlogTrace logId $ "recover: sending request to ambassador " ++ show μ
    liftIO $ atomically $ writeTChan omchan $ OMRecover $ Recover self ρs
    when schedulerIsEnabled $ usend μ ()
    expect

-- | Start a new replica on the given node, adding it to the group pointed to by
-- the provided handle. Example usage:
--
-- > addReplica h nid leaseRenewalMargin
--
-- Note that the new replica will block until it gets a Max broadcast by one of
-- the existing replicas. In this way, the replica will not service any client
-- requests until it has indeed been accepted into the group.
--
-- Returns @True@ on success. The client can retry it if it returns @False@.
--
addReplica :: Typeable a
           => Handle a
           -> NodeId
           -> Process Bool
addReplica h@(Handle _ _ cConfig _ _ α) nid = callLocal $ do
    -- Get the group configuration
    self <- getSelfPid
    usend α $ ConfigQuery self
    usend α $ MembershipQuery self
    (ssdict, gcbs, _)  <- expect :: Process StoredGroupConfig
    mship <- fix $ \loop ->
      (expect :: Process (Maybe (DecreeId, [NodeId])))
       >>= maybe loop return

    -- Store the configuration in the remote node.
    _ <- spawnAsync nid $ $(mkClosure 'storeConf)
           (self, (ssdict, gcbs, mship) :: StoredGroupConfig)
    receiveWait [ match logError, match (\() -> return ()) ]

    -- Spawn the replica.
    --
    -- There is no danger that the replica will serve requests before the group
    -- accepts it. It has to be leader in order to serve requests, and it cannot
    -- be leader because it can only ask the lease or reconfigure the group
    -- after it learns of a reconfiguration decree that joins it.
    now <- liftIO $ getTime Monotonic
    config <- unClosure cConfig
    void $ spawnAsync nid $
      $(mkClosure 'spawnLocalReplica) (logId config, self, now)
        `closureApply`
          ($(mkClosure 'persistDirectoryClosure) () `closureApply` cConfig)
    receiveWait [ match logError, match (\() -> return ()) ]

    -- Add the node to the group
    reconfigure h $ $(mkStaticClosure 'Policy.orpn)
        `closureApply` nodeIdClosure nid
  where
    logError s = do
      say $ "Control.Distributed.Log.addReplica: " ++ s
      error s

-- | Kill the replica and acceptor.
killReplica :: Typeable a
              => Handle a
              -> NodeId
              -> Process ()
killReplica (Handle _ _ config _ _ _) nid = callLocal $ do
    conf <- unClosure config
    whereisRemoteAsync nid (acceptorLabel $ logId conf)
    whereisRemoteAsync nid (replicaLabel $ logId conf)
    replicateM_ 2 $ receiveWait
      [ matchIf (\(WhereIsReply l _) -> elem l [ acceptorLabel $ logId conf
                                               , replicaLabel $ logId conf
                                               ]
                ) $
                 \(WhereIsReply _ mpid) -> case mpid of
                    Nothing -> return ()
                    Just p  -> exitAndWait p
      ]

-- | Kill the replica and acceptor and remove it from the group.
--
-- Returns @True@ on success. The client can retry it if it returns @False@.
--
removeReplica :: Typeable a
              => Handle a
              -> NodeId
              -> Process Bool
removeReplica h nid = do
    killReplica h nid
    reconfigure h $ staticClosure $(mkStatic 'Policy.notThem)
        `closureApply` listNodeIdClosure [nid]

clone :: Typeable a => RemoteHandle a -> Process (Handle a)
clone (RemoteHandle sdict1 sdict2 cConfig log nodes) = do
    dict2 <- unStatic sdict2
    config <- unClosure cConfig
    omchan <- liftIO newTChanIO
    Handle sdict1 sdict2 cConfig log omchan <$>
      spawnLocal (ambassador dict2 config omchan nodes)
