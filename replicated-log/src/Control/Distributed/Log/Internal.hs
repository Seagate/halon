-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Replicate state machines and their logs. This module is intended to be
-- imported qualified.

{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Control.Distributed.Log
    ( -- * Operations on handles
      Handle
    , updateHandle
    , remoteHandle
    , RemoteHandle
    , clone
      -- * Creating new log instances and operations
    , Hint(..)
    , Log(..)
    , new
    , append
    , status
    , reconfigure
    , addReplica
    , removeReplica
    -- * Dictionaries
    , sdictValue
      -- * Remote Tables
    , Control.Distributed.Log.__remoteTable
    , Control.Distributed.Log.__remoteTableDecl
    , ambassador__tdict
    ) where

import Control.Distributed.Log.Messages
import Control.Distributed.Log.Policy (NominationPolicy)
import Control.Distributed.Log.Policy as Policy (notThem, notThem__static)
import Control.Distributed.Process.Consensus hiding (Value)

import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Scheduler (schedulerIsEnabled)
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
import Data.List (find, intersect)
import Data.Foldable (Foldable)
import qualified Data.Foldable as Foldable
import Data.Function (on)
import Data.Binary (Binary, encode)
import Data.Maybe
import Data.Monoid (Monoid(..))
import qualified Data.Map as Map
import Data.Ratio (Ratio, (%), numerator, denominator)
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Prelude hiding (init, log)
import System.Clock

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
                      >> when schedulerIsEnabled (send self Done)
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

data Log a = forall s. Typeable s => Log
    { -- | Initialization callback.
      logInitialization :: Process s

      -- | State transition callback.
    , logNextState      :: s -> a -> Process s
    } deriving (Typeable)

-- | The type of decree values. Some decrees are control decrees, that
-- reconfigure the group. Note that stopping a group completely can be done by
-- reconfiguring to the null membership list. And reconfiguring with the same
-- membership list encodes a no-op.
data Value a
      -- | Batch of values.
    = Values [a]
      -- | Request start time, lease period, list of acceptors and list of
      -- replicas (i.e. proposers).
    | Reconf TimeSpec Int64 [ProcessId] [ProcessId]
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

queryMissing :: [ProcessId] -> Map.Map Int (Value a) -> Process ()
queryMissing replicas log = do
    let ns = concat $ gaps $ (-1:) $ Map.keys $ log
    self <- getSelfPid
    forM_ ns $ \n -> do
        forM_ replicas $ \ρ -> do
            send ρ $ Query self n

newtype Memory a = Memory (Map.Map Int a)
                 deriving Typeable

$(deriveSafeCopy 0 'base ''Memory)

memoryInsert :: Int -> a -> Update (Memory a) ()
memoryInsert n v = do
    Memory log <- get
    put $ Memory (Map.insert n v log)

memoryGet :: Acid.Query (Memory a) (Map.Map Int a)
memoryGet = do
    Memory log <- ask
    return $ log

$(makeAcidic ''Memory ['memoryInsert, 'memoryGet])

-- | This is an adjustment to the lease period so non-leaders think it is
-- slightly longer to account for possible clock drifts during the lease period.
driftSafetyFactor :: Ratio Int64
driftSafetyFactor = 11 % 10

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
        -> (NodeId -> FilePath)
        -> Protocol NodeId (Value a)
        -> Log a
        -> TimeSpec
        -> Int64
        -> Int64
        -> DecreeId
        -> [ProcessId]
        -> [ProcessId]
        -> Process ()
replica Dict
        SerializableDict
        file
        Protocol{prl_propose}
        Log{..}
        leaseStart0
        leaseRenewalMargin
        leasePeriod0
        decree
        acceptors
        replicas = do
    say $ "New replica started in " ++ show (decreeLegislatureId decree)

    self <- getSelfPid
    acid <- liftIO $ openLocalStateFrom (file (processNodeId self)) (Memory Map.empty)
    s <- logInitialization

    -- Replay backlog if any.
    log <- liftIO $ Acid.query acid MemoryGet

    -- Teleport all decrees to the highest possible legislature, since all
    -- recorded decrees must be replayed. This has no effect on the current
    -- decree number and the watermark. See Note [Teleportation].
    forM_ (Map.toList log) $ \(n,v) -> do
        send self $ Decree Stored (DecreeId maxBound n) v

    forM_ (acceptors ++ replicas) $ monitor

    let d = if Map.null log
            then decree
            else decree{ decreeNumber =
                             max (decreeNumber decree) (succ $ fst $ Map.findMax log) }
        w = DecreeId 0 0
    let others = filter (/= self) replicas
    queryMissing others $ Map.insert (decreeNumber d) undefined log

    ppid <- spawnLocal $ link self >> proposer self Bottom acceptors
    timerPid <- spawnLocal $ link self >> timer
    -- If I'm the leader, the first lease starts at the time the request to
    -- spawn the replica was sent. Otherwise, it starts now.
    leaseStart0' <- if [self] == take 1 replicas
                    then return leaseStart0
                    else liftIO $ getTime Monotonic
    go ppid timerPid acid leaseStart0' leasePeriod0 acceptors replicas d d w s
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
          expectTimeout t >>= maybe (send sender msg >> timer) wait

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
                     runPropose' (prl_propose αs d v) s >>= liftIO . putMVar mv
                     send self ()
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
              send self (d,request)
              proposer ρ s αs'
            else do
              (v',s') <- liftIO $ takeMVar mv
              send ρ (d,v',request)
              proposer ρ s' αs'

        , match $ proposer ρ s
        ]

    -- > go pid_of_proposer
    -- >    pid_of_timer
    -- >    acid_handle
    -- >    leaseStart
    -- >    leasePeriod
    -- >    acceptors
    -- >    replicas
    -- >    current_unconfirmed_decree
    -- >    current_decree
    -- >    watermark
    -- >    state
    --
    -- The @acid_handle@ is used to persist the log.
    --
    -- The @leaseStart@ indicates the time at which the last lease started.
    --
    -- The @leasePeriod@ is the period to be used in lease requests.
    -- The @leaseRenewalMargin@ parameter of @replica@ indicates with how much
    -- anticipation the leader must renew the lease before expiration of the
    -- current lease.
    --
    -- The @acceptors@ are the list of pids of the consensus acceptors.
    --
    -- The @replicas@ are the list of pids of the replicas in the group,
    -- including the self pid.
    --
    -- The @current_unconfirmed_decree@ is the decree identifier of the next
    -- proposal to confirm. All previous decrees are known to have passed
    -- consensus.
    --
    -- The @current_decree@ is the decree identifier of the next proposal to do.
    -- For now, it must never be an unreachable decree (i.e. a decree beyond the
    -- reconfiguration decree that changes to a new legislature) or any
    -- proposal using the decree identifier will never be acknowledged or
    -- executed. Invariant: @current_unconfirmed_decree <= current_decree@
    --
    -- The @watermark@ is the identifier of the next decree to execute.
    --
    -- The @state@ is the state yielded by the last executed decree.
    --
    go ppid timerPid acid leaseStart leasePeriod αs ρs d cd w s = do
        self <- getSelfPid
        log <- liftIO $ Acid.query acid MemoryGet
        let others = filter (/= self) ρs
            go' = go ppid timerPid acid

            -- Returns the leader if the lease has not expired.
            getLeader :: IO (Maybe ProcessId)
            getLeader = do
              now <- getTime Monotonic
              -- Adjust the period to account for some clock drift, so
              -- non-leaders think the lease is slightly longer.
              let adjustedPeriod = if self == head ρs
                    then leasePeriod
                    else leasePeriod * numerator   driftSafetyFactor
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
                , requestValue    = Reconf now leasePeriod αs ρs' :: Value a
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
                      send ppid (cd, leaseRequest)
                      return $ succ cd
                    _ ->  return cd
                  go' leaseStart leasePeriod αs ρs d cd' w s

            , matchIf (\(Decree _ dᵢ _ :: Decree (Value a)) ->
                        -- Take the max of the watermark legislature and the
                        -- incoming legislature to deal with teleportation of
                        -- decrees. See Note [Teleportation].
                        dᵢ < max w w{decreeLegislatureId = decreeLegislatureId dᵢ}) $
                       \_ -> do
                  -- We must already know this decree, or this decree is from an
                  -- old legislature, so skip it.
                  go' leaseStart leasePeriod αs ρs d cd w s

              -- Commit the decree to the log.
            , matchIf (\(Decree locale dᵢ _) ->
                        locale /= Stored && w <= dᵢ && decreeNumber dᵢ == decreeNumber w) $
                       \(Decree locale dᵢ v) -> do
                  _ <- liftIO $ Acid.update acid $
                           MemoryInsert (decreeNumber dᵢ) (v :: Value a)
                  case locale of
                      -- Ack back to the client, but only if it is not us asking
                      -- the lease (no other replica uses locale Local).
                      Local κ | κ /= self -> send κ ()
                      _ -> return ()
                  send self $ Decree Stored dᵢ v
                  go' leaseStart leasePeriod αs ρs d cd w s

              -- Execute the decree
            , matchIf (\(Decree locale dᵢ _) ->
                        locale == Stored && w <= dᵢ && decreeNumber dᵢ == decreeNumber w) $
                       \(Decree _ dᵢ v) -> case v of
                  Values xs -> do
                      s' <- foldM logNextState s xs
                      let d'  = max d w'
                          cd' = max cd w'
                          w'  = succ w
                      go' leaseStart leasePeriod αs ρs d' cd' w' s'
                  Reconf requestStart leasePeriod' αs' ρs'
                    -- Only execute reconfiguration decree if decree is from
                    -- current legislature. Otherwise we would be going back to
                    -- an old configuration.
                    | ((==) `on` decreeLegislatureId) d dᵢ -> do
                      let d' = d{ decreeLegislatureId = succ (decreeLegislatureId d)
                                , decreeNumber = max (decreeNumber d) (decreeNumber w') }
                          cd' = cd{ decreeLegislatureId = succ (decreeLegislatureId cd)
                                  , decreeNumber = max (decreeNumber cd) (decreeNumber w') }
                          w' = succ w{decreeLegislatureId = succ (decreeLegislatureId w)}

                      -- This can cause multiple monitors to be set for existing
                      -- processes, but that's ok, and it saves the hassle of
                      -- having to maintain a list of monitor references
                      -- ourselves.
                      forM_ (αs' ++ ρs') $ monitor

                      -- Update the list of acceptors of the proposer...
                      send ppid αs'

                      -- Tick.
                      send self Status

                      -- If I'm the leader, the lease starts at the time
                      -- the request was made. Otherwise, it starts now.
                      now <- liftIO $ getTime Monotonic
                      leaseStart' <-
                          if [self] == take 1 ρs'
                          then do
                            send timerPid
                                 ( self
                                 , max 0 (TimeSpec 0 ((leasePeriod' -
                                                       leaseRenewalMargin) * 1000) -
                                           (now - requestStart))
                                 , LeaseRenewalTime
                                 )
                            return requestStart
                          else return now
                      go' leaseStart' leasePeriod' αs' ρs' d' cd' w' s
                    | otherwise -> do
                      let w' = succ w{decreeLegislatureId = succ (decreeLegislatureId w)}
                      say $ "Not executing " ++ show dᵢ
                      go' leaseStart leasePeriod αs ρs d cd w' s

              -- If we get here, it's because there's a gap in the decrees we
              -- have received so far. Compute the gaps and ask the other
              -- replicas about how to fill them up.
            , matchIf (\(Decree locale dᵢ _) ->
                        locale == Remote && w < dᵢ && not (Map.member (decreeNumber dᵢ) log)) $
                       \(Decree locale dᵢ v) -> do
                  _ <- liftIO $ Acid.update acid $ MemoryInsert (decreeNumber dᵢ) v
                  log' <- liftIO $ Acid.query acid $ MemoryGet
                  queryMissing others log'
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
                  send self $ Decree locale dᵢ v
                  go' leaseStart leasePeriod αs ρs d cd w s

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
                      send ppid (cd, request)
                      return $ succ cd
                  go' leaseStart leasePeriod αs ρs d cd' w s

              -- Client requests.
            , matchIf (\_ -> cd == w) $  -- XXX temp fix to avoid proposing
                                         -- values for unreachable decrees.
                       \(request :: Request a) -> do
                  mLeader <- liftIO getLeader
                  (s', cd') <- case mLeader of
                           Nothing -> do
                             leaseRequest <- mkLeaseRequest $
                                               decreeLegislatureId d
                             send ppid (cd, leaseRequest)
                             -- Save the current request for later.
                             send self request
                             return (s, succ cd)

                           -- Forward the request to the leader.
                           Just leader | self /= leader -> do
                             send leader request
                             return (s, cd)

                           -- I'm the leader, so handle the request.
                           _ -> case (requestHint request, requestValue request) of
                             -- Serve nullipotent requests from the local state.
                             (Nullipotent, Values xs) -> do
                                 s' <- foldM logNextState s xs
                                 send (requestSender request) ()
                                 return (s', cd)
                             -- Send the other requests to the proposer.
                             _ -> do
                               send ppid (cd, request)
                               return (s, succ cd)
                  go' leaseStart leasePeriod αs ρs d cd' w s'

              -- Message from the proposer process
            , match $ \(dᵢ,vᵢ,request@(Request κ (v :: Value a) _ rLease)) -> do
                  -- If the passed decree accepted other value than our
                  -- client's, don't treat it as local (ie. do not report back
                  -- to the client yet).
                  let locale = if v == vᵢ then Local κ else Remote
                  send self $ Decree locale dᵢ vᵢ
                  forM_ others $ \ρ -> do
                      send ρ $ Decree Remote dᵢ vᵢ

                  when (v /= vᵢ && isNothing rLease) $
                      -- Decree already has different value, so repost to
                      -- hopefully get it accepted as a future decree number.
                      -- But repost only if it is not a lease request.
                      send self request
                  let d' = max d (succ dᵢ)
                  go' leaseStart leasePeriod αs ρs d' cd w s

              -- If a query can be serviced, do it.
            , matchIf (\(Query _ n) -> Map.member n log) $ \(Query ρ n) -> do
                  -- See Note [Teleportation].
                  send ρ $ Decree Remote (DecreeId maxBound n) (log Map.! n)
                  go' leaseStart leasePeriod αs ρs d cd w s

              -- Upon getting the max decree of another replica, compute the
              -- gaps and query for those.
            , matchIf (\(Max _ _ dᵢ _ _) -> decreeNumber d < decreeNumber dᵢ) $
                       \(Max ρ _ dᵢ _ _) -> do
                  say $ "Got Max " ++ show dᵢ
                  queryMissing [ρ] $ Map.insert (decreeNumber dᵢ) undefined log
                  let d'  = d{decreeNumber = decreeNumber dᵢ}
                      cd' = max d' cd
                  go' leaseStart leasePeriod αs ρs d' cd' w s

              -- Ignore max decree if it is lower than the current decree.
            , matchIf (\_ -> otherwise) $ \(_ :: Max) -> do
                  go' leaseStart leasePeriod αs ρs d cd w s

              -- A replica is trying to join the group.
            , match $ \m@(Helo π cpolicy) -> do

                  mLeader <- liftIO $ getLeader
                  case mLeader of
                    Nothing -> do
                      mkLeaseRequest (decreeLegislatureId d) >>= send self
                      -- Save the current request for later.
                      send self m

                    -- Forward the request to the leader.
                    Just leader | self /= leader -> do
                      send leader m

                    -- I'm the leader, so handle the request.
                    _ -> do
                      policy <- unClosure cpolicy
                      let (αs', ρs') = policy (αs, ρs)
                          -- Place the proposer at the head of the list
                          -- of replicas to be considered as future leader.
                          ρs'' = self : filter (/= self) ρs'
                      requestStart <- liftIO $ getTime Monotonic
                      -- Get self to propose reconfiguration...
                      send self $ Request
                        { requestSender   = π
                        , requestValue    =
                            Reconf requestStart leasePeriod αs' ρs'' :: Value a
                        , requestHint     = None
                        , requestForLease = Nothing
                        }

                      -- Update the list of acceptors of the proposer...
                      send ppid (intersect αs αs')

                      -- ... filtering out invalidated nodes for quorum.
                      go' leaseStart leasePeriod (intersect αs αs') ρs d cd w s

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
                  forM_ others $ \ρ -> send ρ $
                    Max self leasePeriod d αs ρs
                  go' leaseStart leasePeriod αs ρs d cd w s

            , match $ \(ProcessMonitorNotification _ π _) -> do
                  reconnect π
                  -- XXX: uncomment the monitor call below but figure out first
                  -- a way to avoid entering a tight loop when a replica
                  -- dissappears.
                  -- _ <- liftProcess $ monitor π
                  when (π `elem` replicas) $
                    send π $ Max self leasePeriod d αs ρs
                  go' leaseStart leasePeriod αs ρs d cd w s
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
        send ρ $ Request
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
            Foldable.forM_ inFlight $ \req -> send (requestSender req) ()
            unless (Seq.null collected) $ sendBatch collected
            go Seq.empty collected
      , match $ \request -> do
            assert (isValues $ requestValue request) $ return ()
            case requestHint request of
                -- Forward read requests immediately, as they can be answered
                -- by the leader without consensus.
                Nullipotent -> do
                    send ρ request
                    go collected inFlight
                _ -> if Seq.null inFlight
                     then do
                         assert (Seq.null collected) $ return ()
                         let inFlight' = Seq.singleton request
                         sendBatch inFlight'
                         go Seq.empty inFlight'
                     else go (collected |> request) inFlight
      -- Forward every relevant other request
      , match $ \(request :: Helo)   -> send ρ request >> go collected inFlight
      , match $ \(request :: Status) -> send ρ request >> go collected inFlight
      ]

dictValue :: SerializableDict a -> SerializableDict (Value a)
dictValue SerializableDict = SerializableDict

dictList :: SerializableDict a -> SerializableDict [a]
dictList SerializableDict = SerializableDict

dictNodeId :: SerializableDict NodeId
dictNodeId = SerializableDict

dictMax :: SerializableDict Max
dictMax = SerializableDict

-- | @delay them p@ is a process that waits for a signal (a message of type @()@)
-- from 'them' (origin is not verified) before proceeding as @p@. In order to
-- avoid waiting forever, @delay them p@ monitors 'them'. If it receives a
-- monitor message instead it simply terminates.
delay :: SerializableDict a -> ProcessId -> (a -> Process ()) -> Process ()
delay SerializableDict them f = do
  ref <- monitor them
  let sameRef (ProcessMonitorNotification ref' _ _) = ref == ref'
  receiveWait
      [ match           $ \x -> unmonitor ref >> f x
      , matchIf sameRef $ const $ return () ]

-- | Like 'uncurry', but extract arguments from a 'Max' message rather than
-- a pair.
unMax :: (Int64 -> DecreeId -> [ProcessId] -> [ProcessId] -> a) -> Max -> a
unMax f (Max _ leasePeriod d αs ρs) =
  f leasePeriod d αs ρs

int64Id ::Int64 -> Int64
int64Id = id

timeSpecId :: TimeSpec -> TimeSpec
timeSpecId = id

remotable [ 'replica
          , 'delay
          , 'unMax
          , 'dictValue
          , 'dictList
          , 'dictNodeId
          , 'dictMax
          , 'int64Id
          , 'timeSpecId
          , 'batcher
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

unMaxCP :: (Typeable a)
        => Closure (   Int64
                    -> DecreeId
                    -> [ProcessId]
                    -> [ProcessId]
                    -> Process a)
        -> CP Max a
unMaxCP f = staticClosure $(mkStatic 'unMax) `closureApply` f

-- | Spawn a group of processes, feeding the set of all ProcessId's to each.
spawnRec :: [NodeId] -> Closure ([ProcessId] -> Process ()) -> Process [ProcessId]
spawnRec nodes f = do
    self <- getSelfPid
    ρs <- forM nodes $ \nid -> spawn nid $
              delayClosure ($(mkStatic 'dictList) `staticApply` sdictProcessId) self f
    forM_ ρs $ \ρ -> send ρ ρs
    return ρs

replicaClosure :: Typeable a
               => Static (Dict (Eq a))
               -> Static (SerializableDict a)
               -> Closure (NodeId -> FilePath)
               -> Closure (Protocol NodeId (Value a))
               -> Closure (Log a)
               -> Closure TimeSpec
               -> Closure Int64
               -> Closure (   Int64
                           -> DecreeId
                           -> [ProcessId]
                           -> [ProcessId]
                           -> Process ())
replicaClosure sdict1 sdict2 file protocol log leaseStart leaseRenewalMargin =
    staticClosure $(mkStatic 'replica)
      `closureApply` staticClosure sdict1
      `closureApply` staticClosure sdict2
      `closureApply` file
      `closureApply` protocol
      `closureApply` log
      `closureApply` leaseStart
      `closureApply` leaseRenewalMargin

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
           (Closure (NodeId -> FilePath))
           (Closure (Protocol NodeId (Value a)))
           (Closure (Log a))
           ProcessId
    deriving (Typeable, Generic)

instance Eq (Handle a) where
    Handle _ _ _ _ _ μ == Handle _ _ _ _ _ μ' = μ == μ'

-- | A handle to a log created remotely. A 'RemoteHandle' can't be used to
-- access a log, but it can be cloned into a local handle.
data RemoteHandle a =
    RemoteHandle (Static (Dict (Eq a)))
                 (Static (SerializableDict a))
                 (Closure (NodeId -> FilePath))
                 (Closure (Protocol NodeId (Value a)))
                 (Closure (Log a))
                 (Closure (Process ()))
   deriving (Typeable, Generic)

instance Typeable a => Binary (RemoteHandle a)

matchA :: forall a . SerializableDict a -> ProcessId -> Process () -> Match ()
matchA SerializableDict ρ cont =
  match $ \a -> do
    send ρ (a :: Request a)
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
                          send δ $ $(mkClosure 'ambassador) (ssdict,replicas)
                          go d ρ
                    , match $ \m@(Helo _ _) -> send ρ m >> go d ρ
                    , match $ \Status -> do
                          send ρ Status
                          go d ρ
                    , match $ \ρ' -> go d ρ'
                    , matchA sdict ρ $ go d ρ
                    ]

        mkSomeSDict :: SerializableDict a -> Some SerializableDict
        mkSomeSDict = Some

    |] ]

-- | Append an entry to the replicated log.
append :: Serializable a => Handle a -> Hint -> a -> Process ()
append (Handle _ _ _ _ _ μ) hint x = callLocal $ do
    self <- getSelfPid
    send μ $ Request
      { requestSender   = self
      , requestValue    = Values [x]
      , requestHint     = hint
      , requestForLease = Nothing
      }
    expect

-- | Make replicas advertize their status info.
status :: Serializable a => Handle a -> Process ()
status (Handle _ _ _ _ _ μ) = send μ Status

-- | Updates the handle so it communicates with the given replica.
updateHandle :: Handle a -> ProcessId -> Process ()
updateHandle (Handle _ _ _ _ _ α) ρ = send α ρ

remoteHandle :: Handle a -> Process (RemoteHandle a)
remoteHandle (Handle sdict1 sdict2 fp protocol log α) = do
    self <- getSelfPid
    send α $ Clone self
    RemoteHandle sdict1 sdict2 fp protocol log <$> expect

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
-- > new eqDict
-- >     serializableDict
-- >     fileClosure
-- >     consensusProtocol
-- >     logClosure
-- >     leasePeriod
-- >     leaseRenewalMargin
-- >     nodes
--
-- spawns one replica process on each node in @nodes@. The behaviour of the
-- replica upon receipt of a message is determined by the @logClosure@ argument
-- which provides a callback for initilizing the state and another
-- callback for making transitions.
--
-- The argument @fileClosure@ indicates for each node a path on disk where to
-- persist the log.
--
-- The argument @consensusProtocol@ indicates the consensus
-- implementation to use.
--
-- The argument @leasePeriod@ indicates the length of the lease period
-- in microseconds. The lease period indicates how long the leader is guaranteed
-- to have no competition from other replicas when serving requests
-- as measured since the lease was requested.
--
-- The argument @leaseRenewalMargin@ indicates in microsencods with how much
-- anticipation the leader must renew the lease before the lease period
-- is over. A precondition is that @2 * leaseRenewalMargin < leasePeriod@.
--
-- The returned 'Handle' identifies the group.
new :: Typeable a
    => Static (Dict (Eq a))
    -> Static (SerializableDict a)
    -> Closure (NodeId -> FilePath)
    -> Closure (Protocol NodeId (Value a))
    -> Closure (Log a)
    -> Int64
    -> Int64
    -> [NodeId]
    -> Process (Handle a)
new sdict1 sdict2 file protocol log leasePeriod leaseRenewalMargin nodes = do
    acceptors <- forM nodes $ \nid -> spawn nid $
                     acceptorClosure $(mkStatic 'dictNodeId) protocol nid
    now <- liftIO $ getTime Monotonic
    -- See Note [spawnRec]
    replicas <- spawnRec nodes $
                    replicaClosure sdict1 sdict2 file protocol log
                        ($(mkClosure 'timeSpecId) now)
                        ($(mkClosure 'int64Id) leaseRenewalMargin)
                        `closureApply` $(mkClosure 'int64Id) leasePeriod
                        `closureApply` staticClosure initialDecreeIdStatic
                        `closureApply` listProcessIdClosure acceptors
    batchers <- forM replicas $ \ρ -> spawn (processNodeId ρ) $ batcherClosure sdict2 ρ
    -- Create a new local proxy for the cgroup.
    Handle sdict1 sdict2 file protocol log <$> spawnLocal (ambassador (staticApply $(mkStatic 'mkSomeSDict) sdict2, batchers))

-- | Propose a reconfiguration according the given nomination policy. Note that
-- in general, it is only safe to remove replicas if they are /certainly/ dead.
reconfigure :: Typeable a
            => Handle a
            -> Closure NominationPolicy
            -> Process ()
reconfigure (Handle _ _ _ _ _ μ) cpolicy = callLocal $ do
    self <- getSelfPid
    send μ $ Helo self cpolicy
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
           -> Int64
           -> Process ProcessId
addReplica h@(Handle sdict1 sdict2 file protocol log _)
           cpolicy nid leaseRenewalMargin               = do
    self <- getSelfPid
    now <- liftIO $ getTime Monotonic
    α <- spawn nid $ acceptorClosure $(mkStatic 'dictNodeId) protocol nid
    -- See comment about effect of 'delayClosure' in docstring above.
    ρ <- spawn nid $ delayClosure sdictMax self $
             unMaxCP $ replicaClosure sdict1 sdict2 file protocol log
                                      ($(mkClosure 'timeSpecId) now)
                                      ($(mkClosure 'int64Id) leaseRenewalMargin)
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
removeReplica h@(Handle _sdict1 _sdict2 _ _protocol _log _) α ρ β = do
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
clone (RemoteHandle sdict1 sdict2 fp protocol log f) =
    Handle sdict1 sdict2 fp protocol log <$> (spawnLocal =<< unClosure f)
