-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Interface for replicated logs. This module is intended to be imported
-- qualified.

{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
module Control.Distributed.Log
       ( -- * Reified dictionaries
         EqDict(..)
       , TypeableDict(..)
       , sdictValue
         -- * Operations on handles
       , Handle
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
         -- * Remote Tables
       , Control.Distributed.Log.__remoteTable
       , Control.Distributed.Log.__remoteTableDecl ) where

import Control.Distributed.Log.Messages
import Control.Distributed.Log.Policy (NominationPolicy)
import Control.Distributed.Log.Policy as Policy (notThem, notThem__static)
import Control.Distributed.Process.Consensus hiding (Value)
import Data.Some

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
import Control.Exception (SomeException, throwIO)
import Control.Monad
import Data.List (find, intersect)
import Data.Function (on)
import Data.Binary (Binary, encode)
import Data.Monoid (Monoid(..))
import qualified Data.Map as Map
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Prelude hiding (init, log)


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

data EqDict a where
    EqDict :: Eq a => EqDict a
    deriving (Typeable)

data TypeableDict a where
    TypeableDict :: Typeable a => TypeableDict a
    deriving (Typeable)

-- | Information about a log entry.
data Hint = None           -- ^ Assume nothing, be pessimistic.
          | Idempotent     -- ^ Executing the command has effect on replicated
                           -- state, but executing multiple times has same
                           -- effect as executing once.
          | Nullipotent    -- ^ Executing the command has no effect on
                           -- replicated state, i.e. executing multiple times
                           -- has same effect as executing zero or more times.
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
data Value a = Value a
               -- | List of acceptors and list of replicas (i.e. proposers).
             | Reconf [ProcessId] [ProcessId]
               deriving (Eq, Generic, Typeable)

instance Binary a => Binary (Value a)

instance Serializable a => SafeCopy (Value a) where
    getCopy = contain $ fmap decode $ safeGet
    putCopy = contain . safePut . encode

queryMissing :: [ProcessId] -> Map.Map Int (Value a) -> Process ()
queryMissing replicas log = do
    let ns = concat $ gaps $ (-1:) $ Map.keys $ log
    self <- getSelfPid
    forM_ ns $ \n -> do
        forM_ replicas $ \ρ -> do
            send ρ $ Query self n

clockInterval :: Int
clockInterval = 1000000

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
replica :: forall a. EqDict a
        -> SerializableDict a
        -> (NodeId -> FilePath)
        -> Protocol NodeId (Value a)
        -> Log a
        -> DecreeId
        -> [ProcessId]
        -> [ProcessId]
        -> Process ()
replica EqDict SerializableDict file Protocol{prl_propose} Log{..} decree acceptors replicas = do
    say $ "New replica started in " ++ show (decreeLegislatureId decree)

    self <- getSelfPid
    acid <- liftIO $ openLocalStateFrom (file (processNodeId self)) (Memory Map.empty)
    s <- logInitialization

    -- Replay backlog if any.
    log <- liftIO $ Acid.query acid MemoryGet
    -- Note [Teleportation]
    -- ~~~~~~~~~~~~~~~~~~~~
    -- Teleport all decrees to the highest possible legislature, since all
    -- recorded decrees must be replayed. This has no effect on the current
    -- decree number and the watermark.
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
    go ppid acid acceptors replicas d w s
  where

    -- The proposer process makes consensus proposals.
    -- Proposals are aborted when a reconfiguration occurs.
    proposer ρ s αs =
      receiveWait
        [ match $ \(d,request@(_ :: ProcessId,v :: Value a,_ :: Hint)) -> do
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

    -- @go pid_of_proposer acid_handle acceptors replicas current_decree watermark state@
    --
    -- The @acid_handle@ is used to persist the log.
    --
    -- The @acceptors@ are the list of pids of the consensus acceptors.
    --
    -- The @replicas@ are the list of pids of the replicas in the group,
    -- including the self pid.
    --
    -- The @current_decree@ is the decree identifier of the next proposal.
    -- For now, it must never be an unreachable decree (i.e. a decree beyond the
    -- reconfiguration decree that changes to a new legislature) or any
    -- proposal using the decree identifier will never be acknowledged or
    -- executed.
    --
    -- The @watermark@ is the identifier of the next decree to execute.
    --
    -- The @state@ is the state yielded by the last executed decree.
    --
    go ppid acid αs ρs d w s = do
        self <- getSelfPid
        log <- liftIO $ Acid.query acid MemoryGet
        let others = filter (/= self) ρs
        receiveWait
            [ matchIf (\(Decree _ dᵢ _ :: Decree (Value a)) ->
                        -- Take the max of the watermark legislature and the
                        -- incoming legislature to deal with teleportation of
                        -- decrees. See Note [Teleportation].
                        dᵢ < max w w{decreeLegislatureId = decreeLegislatureId dᵢ}) $
                       \_ -> do
                  -- We must already know this decree, or this decree is from an
                  -- old legislature, so skip it.
                  go ppid acid αs ρs d w s

              -- Commit the decree to the log.
            , matchIf (\(Decree locale dᵢ _) ->
                        locale /= Stored && w <= dᵢ && decreeNumber dᵢ == decreeNumber w) $
                       \(Decree locale dᵢ v) -> do
                  _ <- liftIO $ Acid.update acid $
                           MemoryInsert (decreeNumber dᵢ) (v :: Value a)
                  case locale of
                      Local κ -> send κ () -- Ack back to the client.
                      _ -> return ()
                  send self $ Decree Stored dᵢ v
                  go ppid acid αs ρs d w s

              -- Execute the decree
            , matchIf (\(Decree locale dᵢ _) ->
                        locale == Stored && w <= dᵢ && decreeNumber dᵢ == decreeNumber w) $
                       \(Decree _ dᵢ v) -> case v of
                  Value x -> do
                      s' <- logNextState s x
                      let d' = max d w'
                          w' = succ w
                      go ppid acid αs ρs d' w' s'
                  Reconf αs' ρs'
                    -- Only execute reconfiguration decree if decree is from
                    -- current legislature. Otherwise we would be going back to
                    -- an old configuration.
                    | ((==) `on` decreeLegislatureId) d dᵢ -> do
                      let d' = d{ decreeLegislatureId = succ (decreeLegislatureId d)
                                , decreeNumber = max (decreeNumber d) (decreeNumber w') }
                          w' = succ w{decreeLegislatureId = succ (decreeLegislatureId w)}

                      -- This can cause multiple monitors to be set for existing
                      -- processes, but that's ok, and it saves the hassle of
                      -- having to maintain a list of monitor references
                      -- ourselves.
                      forM_ (αs' ++ ρs') $ monitor

                      -- Update the list of acceptors of the proposer...
                      send ppid αs'

                      -- Tick.
                      send self ()

                      go ppid acid αs' ρs' d' w' s
                    | otherwise -> do
                      let w' = succ w{decreeLegislatureId = succ (decreeLegislatureId w)}
                      say $ "Not executing " ++ show dᵢ
                      go ppid acid αs ρs d w' s

              -- If we get here, it's because there's a gap in the decrees we
              -- have received so far. Compute the gaps and ask the other
              -- replicas about how to fill them up.
            , matchIf (\(Decree locale dᵢ _) ->
                        locale == Remote && w < dᵢ && not (Map.member (decreeNumber dᵢ) log)) $
                       \(Decree locale dᵢ v) -> do
                  _ <- liftIO $ Acid.update acid $ MemoryInsert (decreeNumber dᵢ) v
                  log' <- liftIO $ Acid.query acid $ MemoryGet
                  queryMissing others log'
                  --- XXX set d to dᵢ?
                  send self $ Decree locale dᵢ v
                  go ppid acid αs ρs d w s

              -- Client requests.
            , matchIf (\_ -> d == w) $  -- XXX temp fix to avoid proposing
                                        -- values for unreachable decrees.
                       \request@(_ :: ProcessId, _ :: Value a, _ :: Hint) -> do
                  send ppid (d,request)
                  go ppid acid αs ρs d w s

              -- Message from the proposer process
            , match $ \(dᵢ,vᵢ,request@(κ, v :: Value a, _ :: Hint)) -> do
                  send self $ Decree (Local κ) dᵢ vᵢ
                  forM_ others $ \ρ -> do
                      send ρ $ Decree Remote dᵢ vᵢ

                  when (v /= vᵢ) $
                      -- Decree already has different value, so repost to
                      -- hopefully get it accepted as a future decree number.
                      send self request
                  let d' = max d (succ dᵢ)
                  go ppid acid αs ρs d' w s

              -- If a query can be serviced, do it.
            , matchIf (\(Query _ n) -> Map.member n log) $ \(Query ρ n) -> do
                  -- See Note [Teleportation].
                  send ρ $ Decree Remote (DecreeId maxBound n) (log Map.! n)
                  go ppid acid αs ρs d w s

              -- Upon getting the max decree of another replica, compute the
              -- gaps and query for those.
            , matchIf (\(Max _ dᵢ _ _) -> decreeNumber d < decreeNumber dᵢ) $
                       \(Max ρ dᵢ _ _) -> do
                  say $ "Got Max " ++ show dᵢ
                  queryMissing [ρ] $ Map.insert (decreeNumber dᵢ) undefined log
                  let d' = d{decreeNumber = decreeNumber dᵢ}
                  go ppid acid αs ρs d' w s

              -- Ignore max decree if it is lower than the current decree.
            , matchIf (\_ -> otherwise) $ \(_ :: Max) -> do
                  go ppid acid αs ρs d w s

              -- A replica is trying to join the group.
            , match $ \(Helo π cpolicy) -> do
                  policy <- unClosure cpolicy
                  let (αs', ρs') = policy (αs, ρs)
                  -- Get self to propose reconfiguration...
                  send self (π, Reconf αs' ρs' :: Value a, None)

                  -- Update the list of acceptors of the proposer...
                  send ppid (intersect αs αs')

                  -- ... filtering out invalidated nodes for quorum.
                  go ppid acid (intersect αs αs') ρs d w s

            -- Clock tick - time to advertize. Can be sent by anyone to any
            -- replica to provoke status info.
            , match $ \() -> do
                  -- Forget about all previous ticks to avoid broadcast storm.
                  let loop = expectTimeout 0 >>= maybe (return ()) (\() -> loop)
                  loop

                  say $ "Status info:" ++
                      "\n\tdecree:    " ++ show d ++
                      "\n\twatermark: " ++ show w ++
                      "\n\tacceptors: " ++ show αs ++
                      "\n\treplicas:  " ++ show ρs
                  forM_ others $ \ρ -> send ρ $ Max self d αs ρs
                  go ppid acid αs ρs d w s

            , match $ \(ProcessMonitorNotification _ π _) -> do
                  reconnect π
                  -- XXX: uncomment the monitor call below but figure out first
                  -- a way to avoid entering a tight loop when a replica
                  -- dissappears.
                  -- _ <- liftProcess $ monitor π
                  when (π `elem` replicas) $
                      send π $ Max self d αs ρs
                  go ppid acid αs ρs d w s
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
unMax :: (DecreeId -> [ProcessId] -> [ProcessId] -> a) -> Max -> a
unMax f (Max _ d αs ρs) = f d αs ρs

remotable [ 'replica, 'delay, 'unMax, 'dictValue, 'dictList, 'dictNodeId, 'dictMax ]

sdictValue :: Typeable a
           => Static (SerializableDict a)
           -> Static (SerializableDict (Value a))
sdictValue sdict = $(mkStatic 'dictValue) `staticApply` sdict

sdictList :: Typeable a
          => Static (SerializableDict a)
          -> Static (SerializableDict [a])
sdictList sdict = $(mkStatic 'dictList) `staticApply` sdict

sdictMax :: Static (SerializableDict Max)
sdictMax = $(mkStatic 'dictMax)

listProcessIdClosure :: [ProcessId] -> Closure [ProcessId]
listProcessIdClosure xs =
    closure (staticDecode ($(mkStatic 'dictList) `staticApply` sdictProcessId))
            (encode xs)

processIdClosure :: ProcessId -> Closure ProcessId
processIdClosure x =
    closure (staticDecode sdictProcessId) (encode x)

nodeIdClosure :: NodeId -> Closure NodeId
nodeIdClosure nid =
    closure (staticDecode $(mkStatic 'dictNodeId)) (encode nid)

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
        => Closure (DecreeId -> [ProcessId] -> [ProcessId] -> Process a) -> CP Max a
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
               => Static (EqDict a)
               -> Static (SerializableDict a)
               -> Closure (NodeId -> FilePath)
               -> Closure (Protocol NodeId (Value a))
               -> Closure (Log a)
               -> Closure (DecreeId -> [ProcessId] -> [ProcessId] -> Process ())
replicaClosure sdict1 sdict2 file protocol log =
    staticClosure $(mkStatic 'replica)
      `closureApply` staticClosure sdict1
      `closureApply` staticClosure sdict2
      `closureApply` file
      `closureApply` protocol
      `closureApply` log

-- | Hide the 'ProcessId' of the ambassador to a log behind an opaque datatype
-- making it clear that the ambassador acts as a "handle" to the log - it does
-- not uniquely identify the log, since there can in general be multiple
-- ambassadors to the same log.
data Handle a =
    Handle (Static (EqDict a))
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
    RemoteHandle (Static (EqDict a))
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
    send ρ (a :: (ProcessId,Value a,Hint))
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
                    , match $ \() -> do
                          send ρ ()
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
    send μ (self, Value x, hint)
    expect

-- | Make replicas advertize their status info.
status :: Serializable a => Handle a -> Process ()
status (Handle _ _ _ _ _ μ) = send μ ()

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

-- | Create a group of replicated processes. @new f nodes@ spawns one
-- replica process on each node in @nodes@. The behaviour of the replica upon
-- receipt of a message is determined by the @f@ callback, which will
-- typically be a state update function. The returned 'ProcessId' identifies
-- the group.
new :: Typeable a
    => Static (EqDict a)
    -> Static (SerializableDict a)
    -> Closure (NodeId -> FilePath)
    -> Closure (Protocol NodeId (Value a))
    -> Closure (Log a)
    -> [NodeId]
    -> Process (Handle a)
new sdict1 sdict2 file protocol log nodes = do
    acceptors <- forM nodes $ \nid -> spawn nid $
                     acceptorClosure $(mkStatic 'dictNodeId) protocol nid
    -- See Note [spawnRec]
    replicas <- spawnRec nodes $
                    replicaClosure sdict1 sdict2 file protocol log
                        `closureApply` staticClosure initialDecreeIdStatic
                        `closureApply` listProcessIdClosure acceptors
    -- Create a new local proxy for the cgroup.
    Handle sdict1 sdict2 file protocol log <$> spawnLocal (ambassador (staticApply $(mkStatic 'mkSomeSDict) sdict2, replicas))

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
-- the provided handle. The first argument is a function producing a nomination
-- policy provided an acceptor and a replica process. Example usage:
--
-- > addReplica $(mkClosure 'Policy.orpn) nid h
--
-- Note that the new replica will block until it gets a Max broadcast by one of
-- the existing replicas. In this way, the replica will not service any client
-- requests until it has indeed been accepted into the group.
addReplica :: Typeable a
           => Handle a
           -> Closure (ProcessId -> ProcessId -> NominationPolicy)
           -> NodeId
           -> Process ProcessId
addReplica h@(Handle sdict1 sdict2 file protocol log _) cpolicy nid = do
    self <- getSelfPid
    α <- spawn nid $ acceptorClosure $(mkStatic 'dictNodeId) protocol nid
    ρ <- spawn nid $ delayClosure sdictMax self $
             unMaxCP $ replicaClosure sdict1 sdict2 file protocol log
    reconfigure h $ cpolicy
        `closureApply` processIdClosure α
        `closureApply` processIdClosure ρ
    return ρ

-- | Kill the replica and acceptor and remove it from the group.
removeReplica :: Typeable a
              => Handle a
              -> ProcessId
              -> ProcessId
              -> Process ()
removeReplica h@(Handle sdict1 sdict2 _ protocol log _) α ρ = do
    ref2 <- monitor α
    ref1 <- monitor ρ
    exit α "Remove acceptor from group."
    exit ρ "Remove replica from group."
    forM_ [ref1, ref2] $ \ref -> receiveWait
        [ matchIf (\(ProcessMonitorNotification ref' _ _) -> ref == ref') $
                  \_ -> return () ]
    reconfigure h $ staticClosure $(mkStatic 'Policy.notThem)
        `closureApply` listProcessIdClosure [α]
        `closureApply` listProcessIdClosure [ρ]

clone :: Typeable a => RemoteHandle a -> Process (Handle a)
clone (RemoteHandle sdict1 sdict2 fp protocol log f) =
    Handle sdict1 sdict2 fp protocol log <$> (spawnLocal =<< unClosure f)
