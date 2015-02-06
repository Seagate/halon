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
    , removeReplica
      -- * Remote Tables
    , Control.Distributed.Log.Internal.__remoteTable
    , Control.Distributed.Log.Internal.__remoteTableDecl
    , ambassador__tdict -- XXX unused, exported to guard against warning.
      -- * Other
    ) where

import Control.Distributed.Log.Messages
import Control.Distributed.Log.Policy (NominationPolicy)
import Control.Distributed.Log.Policy as Policy (notThem, notThem__static)
import Control.Distributed.Process.Consensus hiding (Value)

import Control.Distributed.Process hiding (send)
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Scheduler (schedulerIsEnabled)
import Control.Distributed.Process.Internal.Types (LocalProcessId(..))
import Control.Distributed.Static
    (closureApply, staticApply, staticClosure)

-- Imports necessary for acid-state.
import Data.Acid as Acid
import Data.SafeCopy
import Data.Binary (decode)
import Control.Monad.State (get, put)
import Control.Monad.Reader (ask)

import Control.Applicative ((<$>))
import Control.Concurrent (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Exception (SomeException, throwIO, assert)
import Control.Monad
import Data.Constraint (Dict(..))
import Data.Int (Int64)
import Data.List (find, intersect, maximumBy)
import Data.Foldable (Foldable)
import qualified Data.Foldable as Foldable
import Data.Function (on)
import Data.Binary (Binary, encode)
import Data.Maybe
import Data.Monoid (Monoid(..))
import qualified Data.Map as Map
import Data.Ratio (Ratio, numerator, denominator)
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Prelude hiding (init, log)
import Network.Transport (EndPointAddress(..))
import System.Clock
import System.Directory (removeDirectoryRecursive)
import System.FilePath ((</>))

deriving instance Typeable Eq

-- | An auxiliary type for hiding parameters of type constructors
data Some f = forall a. Some (f a) deriving (Typeable)

-- | An internal type used only by 'callLocal'.
data Done = Done
  deriving (Typeable,Generic)

instance Binary Done

-- XXX pending inclusion upstream.
callLocal :: Process a -> Process a
callLocal p = do
  mv <-liftIO $ newEmptyMVar
  self <- getSelfPid
  _ <- spawnLocal $ link self >> try p >>= liftIO . putMVar mv
                      >> when schedulerIsEnabled (usend self Done)
  when schedulerIsEnabled $ do Done <- expect; return ()
  liftIO $ takeMVar mv
    >>= either (throwIO :: SomeException -> IO a) return

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
      -- Each reference is accompanied with the next log index to execute.
      --
      -- On each node this function could return different results.
      --
    , logGetAvailableSnapshots :: Process [(Int, ref)]

      -- | Yields the snapshot identified by ref.
      --
      -- If the snapshot cannot be retrieved an exception is thrown.
      --
      -- After a succesful call, the snapshot returned or a newer snapshot must
      -- appear listed by @logGetAvailableSnapshots@.
      --
    , logRestore :: ref -> Process s

      -- | Writes a snapshot together with its next log index.
      --
      -- Returns a reference which any replica can use to get the snapshot
      -- with 'logRestore'.
      --
      -- After a succesful call, the dumped snapshot or a newer snapshot must
      -- appear listed in @logGetAvailableSnapshots@.
      --
    , logDump :: Int -> s -> Process ref

      -- | State transition callback.
    , logNextState      :: s -> a -> Process s
    } deriving (Typeable)

data Config = Config
    { -- | The consensus protocol to use.
      consensusProtocol :: forall a. SerializableDict a -> Protocol NodeId a

      -- | For any given node, the directory in which to store persistent state.
    , persistDirectory  :: NodeId -> FilePath

      -- | The length of time before leases time out, in microseconds.
    , leaseTimeout      :: Int64

      -- | The length of time before a leader should seek lease renewal, in
      -- microseconds. To avoid leader churn, you should ensure that
      -- @leaseRenewTimeout <= leaseTimeout@.
    , leaseRenewTimeout :: Int64

      -- | Scale the lease by this factor in non-leaders to protect against
      -- clock drift. This value /must/ be greater than 1.
    , driftSafetyFactor :: Ratio Int64

      -- | Takes the amount of executed entries since last snapshot.
      -- Returns true whenever a snapshot of the state should be saved.
    , snapshotPolicy :: Int -> Process Bool
    } deriving (Typeable)

-- | The type of decree values. Some decrees are control decrees, that
-- reconfigure the group. Note that stopping a group completely can be done by
-- reconfiguring to the null membership list. And reconfiguring with the same
-- membership list encodes a no-op.
data Value a
      -- | Batch of values.
    = Values [a]
      -- | Lease start time, list of acceptors and list of replicas.
    | Reconf TimeSpec [ProcessId] [ProcessId]
    deriving (Eq, Generic, Typeable)

instance Binary a => Binary (Value a)

concatValues :: Foldable f => f (Value a) -> Value a
concatValues vs = case Foldable.toList vs of
    [] -> error "concatValues: empty list"
    xs -> Values $ concat $ map valueToList xs

valueToList :: Value a -> [a]
valueToList (Values as) = as
valueToList _ = error "valueToList: not a Values"

isValues :: Value a -> Bool
isValues (Values _) = True
isValues _ = False

instance Serializable a => SafeCopy (Value a) where
    getCopy = contain $ fmap decode $ safeGet
    putCopy = contain . safePut . encode

-- | A type for internal requests.
data Request a = Request
    { requestSender   :: ProcessId
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

-- | Ask a replica to print status and send Max messages.
data Status = Status deriving (Typeable, Generic)
instance Binary Status

instance Binary TimeSpec

data TimerMessage = LeaseRenewalTime
  deriving (Generic, Typeable)

instance Binary TimerMessage

queryMissingFrom :: Int         -- ^ next decree to execute
                 -> [ProcessId] -- ^ replicas to query
                 -> Map.Map Int (Value a) -- ^ log
                 -> Process ()
queryMissingFrom w replicas log = do
    let pw = pred w
        ns = concat $ gaps $ (pw:) $ Map.keys $ snd $ Map.split pw log
    self <- getSelfPid
    forM_ ns $ \n -> do
        forM_ replicas $ \ρ -> do
            usend ρ $ Query self n

-- | Stores acceptors, replicas and the log.
--
-- At all times the latest membership of the log can be recovered by
-- executing the reconfiguration decrees in modern history. See Note
-- [Trimming the log].
data Memory a = Memory [ProcessId] [ProcessId] (Map.Map Int a)
  deriving Typeable

$(deriveSafeCopy 0 'base ''Memory)
$(deriveSafeCopy 0 'base ''ProcessId)
$(deriveSafeCopy 0 'base ''NodeId)
$(deriveSafeCopy 0 'base ''LocalProcessId)
$(deriveSafeCopy 0 'base ''EndPointAddress)

memoryInsert :: Int -> a -> Update (Memory a) ()
memoryInsert n v = do
    Memory acceptors replicas log <- get
    put $ Memory acceptors replicas (Map.insert n v log)

memoryGet :: Acid.Query (Memory a) ([ProcessId], [ProcessId], Map.Map Int a)
memoryGet = do
    Memory acceptors replicas log <- ask
    return (acceptors, replicas, log)

-- | Removes all entries below the given watermark from the log.
memoryTrim :: [ProcessId] -> [ProcessId] -> Int -> Update (Memory a) ()
memoryTrim acceptors replicas w = do
    Memory _ _ log <- get
    put $ Memory acceptors replicas $ snd $ Map.split (pred w) log

$(makeAcidic ''Memory ['memoryInsert, 'memoryGet, 'memoryTrim])

-- | Removes all entries below the given index from the log.
--
-- See note [Trimming the log]
trimTheLog :: Serializable a
           => AcidState (Memory (Value a))
           -> FilePath     -- ^ Directory for persistence
           -> [ProcessId]  -- ^ Acceptors
           -> [ProcessId]  -- ^ Replicas
           -> Int          -- ^ Log index
           -> IO ()
trimTheLog acid persistDir αs ρs w0 = do
    update acid $ MemoryTrim αs ρs w0
    createCheckpoint acid
    -- This call collects all acid data needed to reconstruct states prior to
    -- the last checkpoint.
    Acid.createArchive acid
    -- And this call removes the collected state.
    removeDirectoryRecursive $ persistDir </> "Archive"

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
    -- | The list of pids of the consensus acceptors.
  , stateAcceptors         :: [ProcessId]
    -- | The list of pids of the replicas.
  , stateReplicas          :: [ProcessId]
    -- | This is the decree identifier of the next proposal to confirm. All
    -- previous decrees are known to have passed consensus.
  , stateUnconfirmedDecree :: DecreeId
    -- | This is the decree identifier of the next proposal to do.
    --
    -- For now, it must never be an unreachable decree (i.e. a decree beyond the
    -- reconfiguration decree that changes to a new legislature) or any
    -- proposal using the decree identifier will never be acknowledged or
    -- executed. Invariant: @stateUnconfirmedDecree <= stateCurrentDecree@
  , stateCurrentDecree     :: DecreeId
    -- | The reference to the last snapshot saved.
  , stateSnapshotRef       :: Maybe ref
    -- | The watermark of the lastest snapshot
    --
    -- See note [Trimming the log].
  , stateSnapshotWatermark :: Int
    -- | The identifier of the next decree to execute.
  , stateWatermark         :: DecreeId
    -- | The state yielded by the last executed decree.
  , stateLogState          :: s

  -- from Log {..}
  , stateLogRestore        :: ref -> Process s
  , stateLogDump           :: Int -> s -> Process ref
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
        -> [ProcessId]
        -> [ProcessId]
        -> Process ()
replica Dict
        SerializableDict
        (unpackConfigProtocol -> (Config{..}, Protocol{prl_propose}))
        (Log {..})
        leaseStart0
        decree
        acceptors0
        replicas0 = do
    say $ "New replica started in " ++ show (decreeLegislatureId decree)

    self <- getSelfPid
    acid <- liftIO $ openLocalStateFrom (persistDirectory (processNodeId self))
                                        (Memory acceptors0 replicas0 Map.empty)
    sns <- logGetAvailableSnapshots
    (w0, s) <- if null sns then (0,) <$> logInitialize
                 else let (w0, ref) = maximumBy (compare `on` fst) sns
                       in (w0,) <$> logRestore ref

    -- Replay backlog if any.
    (acceptors, replicas, log) <- liftIO $ Acid.query acid MemoryGet
    say $ "Log size of replica: " ++ show (Map.size log)

    -- Teleport all decrees to the highest possible legislature, since all
    -- recorded decrees must be replayed. This has no effect on the current
    -- decree number and the watermark. See Note [Teleportation].
    forM_ (Map.toList log) $ \(n,v) -> do
        usend self $ Decree Stored (DecreeId maxBound n) v

    let d = decree{ decreeNumber = max (decreeNumber decree) $
                                       if Map.null log
                                          then w0
                                          else succ $ fst $ Map.findMax log
                  }
        w = DecreeId 0 w0
        others = filter (/= self) replicas
    queryMissingFrom (decreeNumber w) others $
        Map.insert (decreeNumber d) undefined log

    ppid <- spawnLocal $ link self >> proposer self Bottom acceptors
    timerPid <- spawnLocal $ link self >> timer
    -- If I'm the leader, the first lease starts at the time the request to
    -- spawn the replica was sent. Otherwise, it starts now.
    leaseStart0' <- if [self] == take 1 replicas
                    then return leaseStart0
                    else liftIO $ getTime Monotonic
    go ReplicaState
         { stateProposerPid = ppid
         , stateTimerPid = timerPid
         , stateAcidHandle = acid
         , stateLeaseStart = leaseStart0'
         , stateAcceptors = acceptors
         , stateReplicas = replicas
         , stateUnconfirmedDecree = d
         , stateCurrentDecree = d
         , stateSnapshotRef   = Nothing
         , stateSnapshotWatermark = w0
         , stateWatermark = w
         , stateLogState = s
         , stateLogRestore = logRestore
         , stateLogDump = logDump
         , stateLogNextState = logNextState
         }
  where
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
    proposer ρ s αs =
      receiveWait
        [ match $ \(d,request@(Request {requestValue = v :: Value a})) -> do
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
                     result <- runPropose' (prl_propose αs d v) s
                     liftIO $ putMVar mv result
                     usend self ()
            (αs',blocked) <- receiveWait
                      [ match $ \() -> return (αs,False)
                      , match $ \αs' -> do
                         -- block proposal
                         blocked <- liftIO $ tryPutMVar mv undefined
                         -- consume the final () if not blocked
                         when (not blocked) expect
                         return (αs',blocked)
                      ]
            if blocked then do
              exit pid "proposer reconfiguration"
              -- If the leader loses the lease, resending the request will cause
              -- the proposer to compete with proposals from the new leader.
              --
              -- TODO: Consider if there is a simple way to avoid competition of
              -- proposers here.
              usend self (d,request)
              proposer ρ s αs'
            else do
              (v',s') <- liftIO $ takeMVar mv
              usend ρ (d,v',request)
              proposer ρ s' αs'

        , match $ proposer ρ s
        ]

    go :: ReplicaState s ref a -> Process b
    go st@(ReplicaState ppid timerPid acid leaseStart αs ρs d cd msref w0 w s
                        stLogRestore stLogDump stLogNextState
          ) =
     do
        self <- getSelfPid
        (_, _, log) <- liftIO $ Acid.query acid MemoryGet
        let others = filter (/= self) ρs

            -- Returns the leader if the lease has not expired.
            getLeader :: IO (Maybe ProcessId)
            getLeader = do
              now <- getTime Monotonic
              -- Adjust the period to account for some clock drift, so
              -- non-leaders think the lease is slightly longer.
              let adjustedPeriod = if self == head ρs
                    then leaseTimeout
                    else leaseTimeout * numerator   driftSafetyFactor
                                 `div` denominator driftSafetyFactor
              if not (null ρs) &&
                 now - leaseStart < TimeSpec 0 (adjustedPeriod * 1000)
              then return $ Just $ head ρs
              else return Nothing

            -- | Makes a lease request. It takes the legislature on which the
            -- request is valid.
            mkLeaseRequest :: LegislatureId -> Process (Request a)
            mkLeaseRequest l = do
              now <- liftIO $ getTime Monotonic
              let ρs' = self : others
              return Request
                { requestSender   = self
                , requestValue    = Reconf now αs ρs' :: Value a
                , requestHint     = None
                , requestForLease = Just l
                }

        receiveWait
            [ -- The lease is about to expire, so try to renew it.
              matchIf (\_ -> w == cd) $ -- The log is up-to-date and fully
                                        -- executed.
                       \LeaseRenewalTime -> do
                  mLeader <- liftIO $ getLeader
                  cd' <- case mLeader of
                    Just leader | self == leader -> do
                      leaseRequest <- mkLeaseRequest $ decreeLegislatureId d
                      usend ppid (cd, leaseRequest)
                      return $ succ cd
                    _ ->  return cd
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
                      -- Ack back to the client, but only if it is not us asking
                      -- the lease (no other replica uses locale Local).
                      Local κ | κ /= self -> usend κ ()
                      _ -> return ()
                  usend self $ Decree Stored dᵢ v
                  go st

              -- Execute the decree
            , matchIf (\(Decree locale dᵢ _) ->
                        locale == Stored && w <= dᵢ && decreeNumber dᵢ == decreeNumber w) $
                       \(Decree _ dᵢ v) -> do
                let maybeTakeSnapshot w' s' = do
                      takeSnapshot <- snapshotPolicy (decreeNumber w' - w0)
                      if takeSnapshot then do
                        say $ "Log size when trimming: " ++ show (Map.size log)
                        -- First trim the log and only then save the snapshot.
                        -- This guarantees that if later operation fails the
                        -- latest membership can still be recovered from disk.
                        liftIO $ trimTheLog
                          acid (persistDirectory (processNodeId self)) αs ρs w0
                        sref' <- stLogDump (decreeNumber w') s'
                        return (decreeNumber w', Just sref')
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
                  Reconf requestStart αs' ρs'
                    -- Only execute reconfiguration decree if decree is from
                    -- current legislature. Otherwise we would be going back to
                    -- an old configuration.
                    | ((==) `on` decreeLegislatureId) d dᵢ -> do
                      let d' = d{ decreeLegislatureId = succ (decreeLegislatureId d)
                                , decreeNumber = max (decreeNumber d) (decreeNumber w') }
                          cd' = cd{ decreeLegislatureId = succ (decreeLegislatureId cd)
                                  , decreeNumber = max (decreeNumber cd) (decreeNumber w') }
                          w' = succ w{decreeLegislatureId = succ (decreeLegislatureId w)}

                      -- Update the list of acceptors of the proposer...
                      usend ppid αs'

                      (w0', msref') <- maybeTakeSnapshot w' s

                      -- Tick.
                      usend self Status

                      -- If I'm the leader, the lease starts at the time
                      -- the request was made. Otherwise, it starts now.
                      now <- liftIO $ getTime Monotonic
                      leaseStart' <-
                          if [self] == take 1 ρs'
                          then do
                            usend timerPid
                                 ( self
                                 , max 0 (TimeSpec 0 ((leaseTimeout -
                                                       leaseRenewTimeout) * 1000) -
                                           (now - requestStart))
                                 , LeaseRenewalTime
                                 )
                            return requestStart
                          else return now
                      go st{ stateLeaseStart = leaseStart'
                           , stateAcceptors = αs'
                           , stateReplicas = ρs'
                           , stateUnconfirmedDecree = d'
                           , stateCurrentDecree = cd'
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
                  (_, _, log') <- liftIO $ Acid.query acid $ MemoryGet
                  queryMissingFrom (decreeNumber w) others log'
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
              --
              -- XXX The guard avoids proposing values for unreachable decrees.
              -- It also ensures that nullipotent requests can be handled in
              -- this handler (i.e. they get an up-to-date state).
            , matchIf (\_ -> cd == w) $
                       \(request :: Request a) -> do
                  mLeader <- liftIO getLeader
                  (s', cd') <- case mLeader of
                           Nothing -> do
                             leaseRequest <- mkLeaseRequest $
                                               decreeLegislatureId d
                             usend ppid (cd, leaseRequest)
                             -- Save the current request for later.
                             usend self request
                             return (s, succ cd)

                           -- Forward the request to the leader.
                           Just leader | self /= leader -> do
                             usend leader request
                             return (s, cd)

                           -- I'm the leader, so handle the request.
                           _ -> case (requestHint request, requestValue request) of
                             -- Serve nullipotent requests from the local state.
                             (Nullipotent, Values xs) -> do
                                 s' <- foldM stLogNextState s xs
                                 usend (requestSender request) ()
                                 return (s', cd)
                             -- Send the other requests to the proposer.
                             _ -> do
                               usend ppid (cd, request)
                               return (s, succ cd)
                  go st{ stateCurrentDecree = cd', stateLogState = s' }

              -- Message from the proposer process
            , match $ \(dᵢ,vᵢ,request@(Request κ (v :: Value a) _ rLease)) -> do
                  -- If the passed decree accepted other value than our
                  -- client's, don't treat it as local (ie. do not report back
                  -- to the client yet).
                  let locale = if v == vᵢ then Local κ else Remote
                  usend self $ Decree locale dᵢ vᵢ
                  forM_ others $ \ρ -> do
                      usend ρ $ Decree Remote dᵢ vᵢ

                  when (v /= vᵢ && isNothing rLease) $
                      -- Decree already has different value, so repost to
                      -- hopefully get it accepted as a future decree number.
                      -- But repost only if it is not a lease request.
                      usend self request
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
                      SnapshotInfo αs ρs sref w0 n
                    Nothing   -> return ()
                  go st

              -- Get the state from another replica if it is newer than ours
              -- and the original query has not been satisfied.
              --
              -- It does not quite eliminate the chance of multiple snapshots
              -- being read in cascade, but it makes it less likely.
            , match $ \(SnapshotInfo αs' ρs' sref' w0' n) ->
                  if not (Map.member n log) && decreeNumber w <= n &&
                     decreeNumber w < w0' then do
                    -- TODO: get the snapshot asynchronously
                    -- TODO: maybe use an uninterruptible mask
                    mask_ (try $ stLogRestore sref') >>= \case
                     Left (_ :: SomeException) -> go st
                     Right s' -> do
                      -- Trimming here ensures that the log does not accumulate
                      -- decrees indefinitely if the state is oftenly restored
                      -- before saving a snapshot.
                      liftIO $ trimTheLog
                        acid (persistDirectory (processNodeId self)) αs' ρs' w0'

                      let d'  = d { decreeNumber = max w0' (decreeNumber d) }
                          cd' = cd { decreeNumber = max w0' (decreeNumber cd) }
                          w'  = w { decreeNumber = w0' }
                      go st { stateAcceptors         = αs'
                            , stateReplicas          = ρs'
                            , stateUnconfirmedDecree = d'
                            , stateCurrentDecree     = cd'
                            , stateSnapshotRef       = Just sref'
                            , stateSnapshotWatermark = w0'
                            , stateWatermark         = w'
                            , stateLogState          = s'
                            }
                  else go st

              -- Upon getting the max decree of another replica, compute the
              -- gaps and query for those.
            , matchIf (\(Max _ dᵢ _ _) -> decreeNumber d < decreeNumber dᵢ) $
                       \(Max ρ dᵢ _ _) -> do
                  say $ "Got Max " ++ show dᵢ
                  queryMissingFrom (decreeNumber w) [ρ] $
                    Map.insert (decreeNumber dᵢ) undefined log
                  let d'  = d{decreeNumber = decreeNumber dᵢ}
                      cd' = max d' cd
                  go st{ stateUnconfirmedDecree = d', stateCurrentDecree = cd' }

              -- Ignore max decree if it is lower than the current decree.
            , matchIf (\_ -> otherwise) $ \(_ :: Max) -> do
                  go st

              -- A replica is trying to join the group.
            , match $ \m@(Helo π cpolicy) -> do

                  mLeader <- liftIO $ getLeader
                  case mLeader of
                    Nothing -> do
                      mkLeaseRequest (decreeLegislatureId d) >>= usend self
                      -- Save the current request for later.
                      usend self m
                      go st

                    -- Forward the request to the leader.
                    Just leader | self /= leader -> do
                      usend leader m
                      go st

                    -- I'm the leader, so handle the request.
                    _ -> do
                      policy <- unClosure cpolicy
                      let (αs', ρs') = policy (αs, ρs)
                          -- Place the proposer at the head of the list
                          -- of replicas to be considered as future leader.
                          ρs'' = self : filter (/= self) ρs'
                      requestStart <- liftIO $ getTime Monotonic
                      -- Get self to propose reconfiguration...
                      usend self $ Request
                        { requestSender   = π
                        , requestValue    =
                            Reconf requestStart αs' ρs'' :: Value a
                        , requestHint     = None
                        , requestForLease = Nothing
                        }

                      -- Update the list of acceptors of the proposer...
                      usend ppid (intersect αs αs')

                      -- ... filtering out invalidated nodes for quorum.
                      go st{ stateAcceptors = intersect αs αs' }

            -- Clock tick - time to advertize. Can be sent by anyone to any
            -- replica to provoke status info.
            , match $ \Status -> do
                  -- Forget about all previous ticks to avoid broadcast storm.
                  let loop = expectTimeout 0 >>= maybe (return ()) (\() -> loop)
                  loop

                  say $ "Status info:" ++
                      "\n\tunconfirmed decree: " ++ show d ++
                      "\n\tdecree:             " ++ show cd ++
                      "\n\twatermark:          " ++ show w ++
                      "\n\tacceptors:          " ++ show αs ++
                      "\n\treplicas:           " ++ show ρs
                  forM_ others $ \ρ -> usend ρ $
                    Max self d αs ρs
                  go st
            ]

batcher :: forall a. SerializableDict a
        -> ProcessId
        -> Process ()
batcher SerializableDict ρ = do
    link ρ
    go Seq.empty Seq.empty
  where
    sendBatch :: Seq (Request a) -> Process ()
    sendBatch requests = do
        self <- getSelfPid
        usend ρ $ Request
          { requestSender   = self
          , requestValue    = concatValues $ fmap requestValue requests
          , requestHint     = None
          , requestForLease = Nothing }

    -- collected: requests not yet submitted for consensus
    --
    -- inFlight: last batch of request submitted for consensus and waiting for
    --   confirmation; or empty if no batch in-flight
    go :: Seq (Request a) -> Seq (Request a) -> Process r
    go collected inFlight = receiveWait
      [ match $ \() -> do
            -- Replica acknowledges the last submitted batch (it was accepted by
            -- consensus and committed to log).
            assert (not $ Seq.null inFlight) $ return ()
            Foldable.forM_ inFlight $ \req ->
              usend (requestSender req) ()
            unless (Seq.null collected) $ sendBatch collected
            go Seq.empty collected
      , match $ \request -> do
            assert (isValues $ requestValue request) $ return ()
            case requestHint request of
                -- Forward read requests immediately, as they can be answered
                -- by the leader without consensus.
                Nullipotent -> do
                    usend ρ request
                    go collected inFlight
                _ -> if Seq.null inFlight
                     then do
                         assert (Seq.null collected) $ return ()
                         let inFlight' = Seq.singleton request
                         sendBatch inFlight'
                         go Seq.empty inFlight'
                     else go (collected |> request) inFlight
      -- Forward every relevant other request
      , match $ \(request :: Helo)   -> usend ρ request >> go collected inFlight
      , match $ \(request :: Status) -> usend ρ request >> go collected inFlight
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

-- | @delay them f@ is a process that waits for a signal (a message of type @x@)
-- from 'them' (origin is not verified) before proceeding as @f x@. Sends a
-- notification @Done@ to @them@ just before executing @f x@. In order to
-- avoid waiting forever, @delay them p@ monitors 'them'. If it receives a
-- monitor message instead it simply terminates.
--
-- The exchange of the @Done@ message helps ensuring @them@ does not terminate
-- before @delay@ unblocks, otherwise @delay@ could avoid execution of @f x@.
-- See https://cloud-haskell.atlassian.net/browse/DP-99.
--
delay :: SerializableDict a -> ProcessId -> (a -> Process ()) -> Process ()
delay SerializableDict them f = do
  ref <- monitor them
  let sameRef (ProcessMonitorNotification ref' _ _) = ref == ref'
  receiveWait
      [ match           $ \x -> unmonitor ref >> usend them Done >> f x
      , matchIf sameRef $ const $ return () ]

-- | Like 'uncurry', but extract arguments from a 'Max' message rather than
-- a pair.
unMax :: (DecreeId -> [ProcessId] -> [ProcessId] -> a) -> Max -> a
unMax f (Max _ d αs ρs) =
  f d αs ρs

remotable [ 'replica
          , 'delay
          , 'unMax
          , 'dictValue
          , 'dictList
          , 'dictNodeId
          , 'dictMax
          , 'dictTimeSpec
          , 'batcher
          , 'consensusProtocol
          ]

sdictValue :: Typeable a
           => Static (SerializableDict a)
           -> Static (SerializableDict (Value a))
sdictValue sdict = $(mkStatic 'dictValue) `staticApply` sdict

sdictMax :: Static (SerializableDict Max)
sdictMax = $(mkStatic 'dictMax)

listProcessIdClosure :: [ProcessId] -> Closure [ProcessId]
listProcessIdClosure xs =
    closure (staticDecode ($(mkStatic 'dictList) `staticApply` sdictProcessId))
            (encode xs)

processIdClosure :: ProcessId -> Closure ProcessId
processIdClosure x =
    closure (staticDecode sdictProcessId) (encode x)

timeSpecClosure :: TimeSpec -> Closure TimeSpec
timeSpecClosure ts =
    closure (staticDecode $(mkStatic 'dictTimeSpec)) (encode ts)

delayClosure :: Typeable a
             => Static (SerializableDict a)
             -> ProcessId
             -> CP a ()
             -> Closure (Process ())
delayClosure sdict them f =
    staticClosure $(mkStatic 'delay)
      `closureApply` staticClosure sdict
      `closureApply` processIdClosure them
      `closureApply` f

unMaxCP :: Typeable a
        => Closure (DecreeId -> [ProcessId] -> [ProcessId] -> Process a)
        -> CP Max a
unMaxCP f = staticClosure $(mkStatic 'unMax) `closureApply` f

-- | Spawn a group of processes, feeding the set of all ProcessId's to each.
spawnRec :: [NodeId] -> Closure ([ProcessId] -> Process ()) -> Process [ProcessId]
spawnRec nodes f = callLocal $ do -- use callLocal to discard monitor
                                  -- notifications
    self <- getSelfPid
    ρs <- forM nodes $ \nid -> spawn nid $
              delayClosure ($(mkStatic 'dictList) `staticApply` sdictProcessId) self f
    mapM_ monitor ρs
    forM_ ρs $ \ρ -> usend ρ ρs
    forM_ ρs $ const $ receiveWait
      [ match $ \(ProcessMonitorNotification _ _ _) -> return ()
      , match $ \Done -> return ()
      ]
    return ρs

replicaClosure :: Typeable a
               => Static (Dict (Eq a))
               -> Static (SerializableDict a)
               -> Closure Config
               -> Closure (Log a)
               -> Closure (TimeSpec -> DecreeId -> [ProcessId] -> [ProcessId] -> Process ())
replicaClosure sdict1 sdict2 config log =
    staticClosure $(mkStatic 'replica)
      `closureApply` staticClosure sdict1
      `closureApply` staticClosure sdict2
      `closureApply` config
      `closureApply` log

batcherClosure :: Typeable a
               => Static (SerializableDict a)
               -> ProcessId
               -> Closure (Process ())
batcherClosure sdict ρ =
    staticClosure $(mkStatic 'batcher)
      `closureApply` staticClosure sdict
      `closureApply` processIdClosure ρ

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

matchA :: forall a . SerializableDict a -> ProcessId -> Process () -> Match ()
matchA SerializableDict ρ cont =
  match $ \a -> do
    usend ρ (a :: Request a)
    cont

remotableDecl [
    [d| -- | The ambassador to a cgroup is a local process that stands as a proxy to
        -- the cgroup. Its sole purpose is to provide a 'ProcessId' to stand for the
        -- cgroup and to forward all messages to the cgroup.
        ambassador :: (Static (Some SerializableDict),[ProcessId]) -> Process ()
        ambassador (_,[]) = die "ambassador: Set of replicas must be non-empty."
        ambassador (ssdict,replicas) = do
            nid <- getSelfNode
            somesdict <- unStatic ssdict
            go somesdict $ choose nid
          where
            -- If there is a local replica, then always use that one. Otherwise
            -- try all of them round robin.
            choose nid
                | Just ρ <- find ((nid ==) . processNodeId) replicas = ρ
                | null replicas = error "ambassador: empty list of replicas"
                | otherwise = head replicas
            go d@(Some sdict) ρ = do
                receiveWait
                    [ match $ \(Clone δ) -> do
                          usend δ $ $(mkClosure 'ambassador) (ssdict,replicas)
                          go d ρ
                    , match $ \m@(Helo _ _) -> usend ρ m >> go d ρ
                    , match $ \Status -> do
                          usend ρ Status
                          go d ρ
                    , match $ \ρ' -> go d ρ'
                    , matchA sdict ρ $ go d ρ
                    ]

        mkSomeSDict :: SerializableDict a -> Some SerializableDict
        mkSomeSDict = Some
    |] ]

-- | Append an entry to the replicated log.
append :: Serializable a => Handle a -> Hint -> a -> Process ()
append (Handle _ _ _ _ μ) hint x = callLocal $ do
    self <- getSelfPid
    usend μ $ Request
      { requestSender   = self
      , requestValue    = Values [x]
      , requestHint     = hint
      , requestForLease = Nothing
      }
    expect

-- | Make replicas advertize their status info.
status :: Serializable a => Handle a -> Process ()
status (Handle _ _ _ _ μ) = usend μ Status

-- | Updates the handle so it communicates with the given replica.
updateHandle :: Handle a -> ProcessId -> Process ()
updateHandle (Handle _ _ _ _ α) ρ = usend α ρ

remoteHandle :: Handle a -> Process (RemoteHandle a)
remoteHandle (Handle sdict1 sdict2 config log α) = do
    self <- getSelfPid
    usend α $ Clone self
    RemoteHandle sdict1 sdict2 config log <$> expect

-- Note [spawnRec]
-- ~~~~~~~~~~~~~~~
-- Each replica takes the set of all replicas as an argument. But the set of
-- all replicas is not known until all replicas are spawned! So we use
-- 'spawnRec' to spawn suspended replicas, then once all suspended replicas
-- are spawned, spawnRec forces them all.
--
-- In general, there is a bootstrapping problem concerning the initial
-- configuration. Replicas cannot pass by decree the initial configuration,
-- because that presupposes knowing the initial configuration. Using an empty
-- set of acceptors for this initial decree is dangerous, because one then needs
-- to protect against replicas missing the decree and staying perpetually in
-- a state where they can pass any decree independently of any other replicas,
-- including client requests.

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
    let protocol = staticClosure $(mkStatic 'consensusProtocol)
                     `closureApply` config
                     `closureApply` staticClosure (sdictValue sdict2)
    acceptors <-
        forM nodes $ \nid -> spawn nid $
            acceptorClosure $(mkStatic 'dictNodeId)
                            protocol
                            nid
    now <- liftIO $ getTime Monotonic
    -- See Note [spawnRec]
    replicas <- spawnRec nodes $
                    replicaClosure sdict1 sdict2 config log
                        `closureApply` timeSpecClosure now
                        `closureApply` staticClosure initialDecreeIdStatic
                        `closureApply` listProcessIdClosure acceptors
    batchers <- forM replicas $ \ρ -> spawn (processNodeId ρ) $ batcherClosure sdict2 ρ
    -- Create a new local proxy for the cgroup.
    Handle sdict1 sdict2 config log <$> spawnLocal (ambassador (staticApply $(mkStatic 'mkSomeSDict) sdict2, batchers))

-- | Propose a reconfiguration according the given nomination policy. Note that
-- in general, it is only safe to remove replicas if they are /certainly/ dead.
reconfigure :: Typeable a
            => Handle a
            -> Closure NominationPolicy
            -> Process ()
reconfigure (Handle _ _ _ _ μ) cpolicy = callLocal $ do
    self <- getSelfPid
    usend μ $ Helo self cpolicy
    expect

-- | Start a new replica on the given node, adding it to the group pointed to by
-- the provided handle. The second argument is a function producing a nomination
-- policy provided an acceptor and a replica process. Example usage:
--
-- > addReplica h $(mkClosure 'Policy.orpn) nid leaseRenewalMargin
--
-- Note that the new replica will block until it gets a Max broadcast by one of
-- the existing replicas. In this way, the replica will not service any client
-- requests until it has indeed been accepted into the group.
addReplica :: Typeable a
           => Handle a
           -> Closure (ProcessId -> ProcessId -> NominationPolicy)
           -> NodeId
           -> Process ProcessId
addReplica h@(Handle sdict1 sdict2 config log _) cpolicy nid = do
    now <- liftIO $ getTime Monotonic
    let protocol = staticClosure $(mkStatic 'consensusProtocol)
                     `closureApply` config
                     `closureApply` staticClosure (sdictValue sdict2)
    α <- spawn nid $
             acceptorClosure $(mkStatic 'dictNodeId)
                             protocol
                             nid
    -- See comment about effect of 'cpExpect' in docstring above.
    ρ <- spawn nid $ bindCP (cpExpect sdictMax) $
             unMaxCP $ replicaClosure sdict1 sdict2 config log
               `closureApply` timeSpecClosure now
    β <- spawn nid $ batcherClosure sdict2 ρ
    reconfigure h $ cpolicy
        `closureApply` processIdClosure α
        `closureApply` processIdClosure ρ
    return β

-- | Kill the replica and acceptor and remove it from the group.
removeReplica :: Typeable a
              => Handle a
              -> ProcessId
              -> ProcessId
              -> ProcessId
              -> Process ()
removeReplica h α ρ β = do
    ref1 <- monitor β
    ref2 <- monitor ρ
    ref3 <- monitor α
    exit β "Remove batcher from group."
    exit ρ "Remove replica from group."
    exit α "Remove acceptor from group."
    forM_ [ref1, ref2, ref3] $ \ref -> receiveWait
        [ matchIf (\(ProcessMonitorNotification ref' _ _) -> ref == ref') $
                  \_ -> return () ]
    reconfigure h $ staticClosure $(mkStatic 'Policy.notThem)
        `closureApply` listProcessIdClosure [α]
        `closureApply` listProcessIdClosure [ρ]

clone :: Typeable a => RemoteHandle a -> Process (Handle a)
clone (RemoteHandle sdict1 sdict2 config log f) =
    Handle sdict1 sdict2 config log <$> (spawnLocal =<< unClosure f)
