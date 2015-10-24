-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module Control.Distributed.Process.Scheduler.Internal
  (
  -- * Initialization
    schedulerIsEnabled
  , startScheduler
  , stopScheduler
  , withScheduler
  , __remoteTable
  , __remoteTableDecl
  , spawnWrapClosure__tdict
  -- * distributed-process replacements
  , Match
  , usend
  , say
  , nsend
  , nsendRemote
  , sendChan
  , uforward
  , match
  , matchIf
  , matchChan
  , matchSTM
  , matchAny
  , expect
  , receiveChan
  , receiveWait
  , receiveTimeout
  , monitor
  , unmonitor
  , monitorNode
  , link
  , linkNode
  , unlink
  , exit
  , kill
  , spawnLocal
  , spawn
  , spawnAsync
  , spawnChannelLocal
  , callLocal
  , whereis
  , register
  , reregister
  , whereisRemoteAsync
  , registerRemoteAsync
  -- * distributed-process-trans replacements
  , MatchT
  , matchT
  , matchIfT
  , receiveWaitT
  -- * failures
  , addFailures
  , removeFailures
  -- * Internal communication with the scheduler
  , yield
  , getScheduler
  , AbsentScheduler(..)
  , SchedulerMsg(..)
  , SchedulerResponse(..)
  , uninterruptiblyMaskKnownExceptions_
  ) where

import Prelude hiding ( (<$>) )
import Control.Applicative ( (<$>) )
import Control.Arrow (second)
import Control.Concurrent.STM
import "distributed-process" Control.Distributed.Process
    ( Closure, NodeId, Process, ProcessId, ReceivePort, SendPort )
import qualified "distributed-process" Control.Distributed.Process as DP
import qualified "distributed-process" Control.Distributed.Process.Internal.Types as DP
import Control.Distributed.Process.Closure
import "distributed-process" Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable ( Serializable )
import Control.Distributed.Process.Internal.StrictMVar ( withMVar )
import "distributed-process-trans" Control.Distributed.Process.Trans ( MonadProcess(..) )
import qualified "distributed-process-trans" Control.Distributed.Process.Trans as DPT
import qualified Control.Distributed.Process.Internal.WeakTQueue as DP
import Control.Distributed.Process.Internal.Types (LocalProcess(..))

import Control.Concurrent (myThreadId)
import Control.Concurrent.MVar hiding (withMVar)
import Control.Exception
  ( SomeException
  , throwIO
  , bracket
  , Exception
  , throwTo
  , throw
  )
import Control.Monad
import Control.Monad.Reader ( ask )
import Data.Accessor ((^.))
import Data.Binary ( Binary(..), decode )
import Data.Function (on)
import Data.Int
import Data.IORef ( newIORef, writeIORef, readIORef, IORef )
import Data.List (delete, union, sortBy, partition)
import Data.Map ( Map )
import qualified Data.Map as Map
import Data.Set ( Set )
import qualified Data.Set as Set
import Data.Typeable ( Typeable )
import GHC.Generics ( Generic )
import Network.Transport (Transport)
import System.Posix.Env ( getEnv )
import System.IO.Unsafe ( unsafePerformIO )
import System.Mem.Weak (deRefWeak)
import System.Random
import Unsafe.Coerce


-- | @True@ iff the package "distributed-process-scheduler" should be
-- used (iff DP_SCHEDULER_ENABLED environment variable is 1, to be
-- replaced with HFlags in the future).
{-# NOINLINE schedulerIsEnabled #-}
schedulerIsEnabled :: Bool
schedulerIsEnabled = unsafePerformIO $ (== Just "1") <$> getEnv "DP_SCHEDULER_ENABLED"

-- | Tells if there is a scheduler running.
{-# NOINLINE schedulerLock #-}
schedulerLock :: MVar Bool
schedulerLock = unsafePerformIO $ newMVar False

-- | Holds the scheduler pid if there is a scheduler running.
{-# NOINLINE schedulerVar #-}
schedulerVar :: MVar LocalProcess
schedulerVar = unsafePerformIO newEmptyMVar

-- | A message that the scheduler can deliver.
data SystemMsg = MailboxMsg ProcessId DP.Message
               | ChannelMsg DP.SendPortId DP.Message
               | LinkExceptionMsg DP.Identifier ProcessId DP.DiedReason
               | ExitMsg ProcessId ProcessId DP.Message
               | KillMsg ProcessId ProcessId String
  deriving (Typeable, Generic, Show)

instance Binary SystemMsg

-- | Messages that the tested application sends to the scheduler.
data SchedulerMsg
    = Send ProcessId ProcessId SystemMsg
      -- ^ @Send source dest message@: send the @message@ from @source@ to
      -- @dest@.
    | NSend ProcessId NodeId String DP.Message
      -- ^ @NSend source destNode label message@: send the @message@ from
      -- @source@ to @label@ in @destNode@.
    | Block ProcessId (Maybe Int) -- ^ @Block pid timeout@: process @pid@ has no
                                  -- messages to process and is blocked with the
                                  -- given timeout in microseconds.
    | Yield ProcessId    -- ^ @Yield pid@: process @pid@ is ready to continue.
    | SpawnedProcess ProcessId ProcessId
        -- ^ @SpawnedProcess child p@: a new process exists send ack to @p@.
    | Monitor ProcessId DP.Identifier Bool
        -- ^ @Monitor who whom isLink@: the process @who@ will monitor @whom@.
        -- @isLink@ is @True@ when linking is intended.
    | Unmonitor DP.MonitorRef
    | Unlink ProcessId DP.Identifier -- ^ @Unlink who whom@
    | GetTime ProcessId -- ^ A process wants to know the time.
    | AddFailures [((NodeId, NodeId), Double)]
    | RemoveFailures [(NodeId, NodeId)]
  deriving (Generic, Typeable, Show)

-- | Messages that the scheduler sends to the tested application.
data SchedulerResponse
    = Continue     -- ^ Pick a message from your mailbox.
    | Timeout      -- ^ Unblock by timing out.
    | SpawnAck     -- ^ Spawned process
  deriving (Generic, Typeable, Show)

-- | Transitions that the scheduler can choose to perform when all
-- processes block.
data TransitionRequest
    = PutMsg ProcessId SystemMsg
                  -- ^ Deliver this message to mailbox, channel or as exception.
    | PutNSendMsg NodeId String DP.Message
                    -- ^ Put this nsend'ed message in the mailbox of the target.
    | ContinueMsg ProcessId  -- ^ Have a process continue.
    | TimeoutMsg ProcessId  -- ^ Have a blocked process timeout.
  deriving Show

-- | Exit reason sent to stop the scheduler.
data StopScheduler = StopScheduler
  deriving (Generic, Typeable, Show)

-- | Ack of 'StopScheduler'
data SchedulerTerminated = SchedulerTerminated
  deriving (Generic, Typeable)

instance Binary SchedulerMsg
instance Binary SchedulerResponse
instance Binary StopScheduler
instance Binary SchedulerTerminated

type ProcessMessages = Map ProcessId (Map ProcessId [SystemMsg])
type NSendMessages = Map (NodeId, String) (Map ProcessId [DP.Message])
type Time = Int

-- | Internal scheduler state
data SchedulerState = SchedulerState
    { -- | random number generator
      stateSeed     :: StdGen
    , -- | set of tested processes
      stateAlive    :: Set ProcessId
      -- | state of processes (blocked | has_a_message)
    , stateProcs    :: Map ProcessId Bool
      -- | Messages targeted to each process
    , stateMessages :: ProcessMessages
      -- | Messages targeted with a label
    , stateNSend    :: NSendMessages
      -- | The monitors of each process
    , stateMonitors :: Map DP.Identifier [(DP.MonitorRef, Bool)]
      -- | The counter for producing monitor references
    , stateMonitorCounter :: Int32
      -- | The clock of the simulation is used to decide when
      -- timeouts are expired.
    , stateClock :: Time
      -- | The expired timeouts
    , stateExpiredTimeouts :: Set ProcessId
      -- | A map with the pending timeouts
      --
      -- Invariants:
      --
      -- > null $ Map.keys stateTimeouts `intersect`
      -- >        Set.toList stateExpiredTimeouts
      --
      -- > all (not . (`Map.!` stateProcs)) $ concat $ Map.elems stateTimeouts
      --
    , stateTimeouts :: Map Time [ProcessId]
      -- | Indicates the timeout of a process.
      --
      -- Invariant:
      --
      -- > Map.keys stateTimeouts == sort (Map.elems stateReverseTimeouts)
      --
     , stateReverseTimeouts :: Map ProcessId Time
       -- | For each pair of nodes, indicate the probability of dropping a
       -- message. Missing pairs means 0 probability.
     , stateFailures :: Map (NodeId, NodeId) Double
    }

data ProcessKillException =
    ProcessKillException !ProcessId !String
  deriving (Typeable)

instance Exception ProcessKillException
instance Show ProcessKillException where
  show (ProcessKillException pid reason) =
    "killed-by=" ++ show pid ++ ",reason=" ++ reason

throwException :: Exception e => ProcessId -> e -> Process ()
throwException pid e = do
  proc <- ask
  DP.liftIO $ withLocalProc (DP.processNode proc) pid $ \p ->
    void $ throwTo (DP.processThread p) e

withLocalProc :: DP.LocalNode
              -> ProcessId
              -> (DP.LocalProcess -> IO ())
              -> IO ()
withLocalProc node pid p =
  let lpid = DP.processLocalId pid in do
  DP.withValidLocalState node $ \vst ->
    forM_ (vst ^. DP.localProcessWithId lpid) p

remotableDecl [ [d|

 forwardSystemMsg :: SystemMsg -> Process ()
 forwardSystemMsg smsg =
    case smsg of
      MailboxMsg pid msg -> DP.forward msg pid
      ChannelMsg spId msg -> do
        here <- DP.getSelfNode
        let pid = DP.sendPortProcessId spId
            nid = DP.processNodeId pid
        if nid == here then
          -- The local path is more than an optimization.
          -- It is needed to ensure that forwarded messages and
          -- those sent with DP.send arrive in order in the local case.
          --
          -- The natural way to do this is to do:
          --
          -- > DP.sendCtrlMsg Nothing $ DP.LocalPortSend spId msg
          --
          -- Unfortunately, this doesn't work because 'ncEffectLocalPortSend'
          -- in C.D.P.Node can't handle encoded messages. Thus we provide our
          -- own version of the function.
          ncEffectLocalPortSend' spId msg
        else
          remoteForward nid smsg
      LinkExceptionMsg source pid reason -> do
        here <- DP.getSelfNode
        if DP.processNodeId pid == here then
          case source of
            DP.ProcessIdentifier spid ->
              throwException pid $ DP.ProcessLinkException spid reason
            DP.NodeIdentifier snid ->
              throwException pid $ DP.NodeLinkException snid reason
            _ -> error "scheduler.forward: unimplemented case"
        else
          remoteForward (DP.processNodeId pid) smsg
      ExitMsg source pid reason -> do
        here <- DP.getSelfNode
        if DP.processNodeId pid == here then
          throwException pid $ DP.ProcessExitException source reason
        else
          remoteForward (DP.processNodeId pid) smsg
      KillMsg source pid reason -> do
        here <- DP.getSelfNode
        if DP.processNodeId pid == here then
          throwException pid $ ProcessKillException source reason
        else
          remoteForward (DP.processNodeId pid) smsg
  where
    remoteForward :: NodeId -> SystemMsg -> Process ()
    remoteForward nid msg = do
      DP.spawnAsync nid $ $(mkClosure 'forwardSystemMsg) msg
      DP.DidSpawn _ pid <- DP.expect
      ref <- DP.monitor pid
      DP.receiveWait
        [ DP.matchIf (\(DP.ProcessMonitorNotification ref' _ _) -> ref == ref')
                     (\_ -> return ())
        ]

    ncEffectLocalPortSend' :: DP.SendPortId -> DP.Message -> Process ()
    ncEffectLocalPortSend' from msg = do
      lproc <- ask
      let pid = DP.sendPortProcessId from
          cid = DP.sendPortLocalId   from
      DP.liftIO $ withLocalProc (DP.processNode lproc) pid $ \proc -> do
        mChan <- withMVar (DP.processState proc) $
          return . (^. DP.typedChannelWithId cid)
        case mChan of
          Nothing -> return ()
          Just (DP.TypedChannel chan') -> do
            ch <- deRefWeak chan'
            forM_ ch $ \chan -> deliverChan msg chan

    deliverChan :: forall a . Serializable a
                => DP.Message -> DP.TQueue a -> IO ()
    deliverChan (DP.UnencodedMessage _ raw) chan' =
      atomically $ DP.writeTQueue chan' ((unsafeCoerce raw) :: a)
    deliverChan (DP.EncodedMessage   _ bs) chan' =
      -- This is the main difference with 'C.D.P.Node.ncEffectLocalPortSend'
      atomically $ DP.writeTQueue chan' $! (decode bs :: a)

    _ = $(functionTDict 'forwardSystemMsg)
 |]]

-- | Starts the scheduler.
--
-- The function returns the created nodes in lexicographical order of 'NodeId's.
-- Creating nodes by other means, or giving special treatment to nodes with
-- particular attributes may spoil the test. See the limitation in the README
-- file.
--
-- Warning: This call sets the value of the global random generator to that of
-- the provided seed.
--
startScheduler :: Int -- ^ seed
               -> Int -- ^ microseconds to increase the clock in every
                      -- transition
               -> Int -- ^ Nodes to create
               -> Transport -- ^ Transport to use for the nodes.
               -> DP.RemoteTable -- ^ RemoteTable to use for the nodes.
               -> IO [LocalNode]
startScheduler seed0 clockDelta numNodes transport rtable = do
    -- Setting the global random generator will make deterministic the behavior
    -- of any library which depends on it. In the case of d-p this is necessary
    -- to have ProcessIds generated with the same uniques.
    setStdGen $ mkStdGen seed0
    modifyMVar schedulerLock
      $ \initialized -> do
        if initialized
         then error "startScheduler: scheduler already started."
         else do
           lnodes <- replicateM numNodes $ newLocalNode transport rtable
           case sortBy (compare `on` localNodeId) lnodes of
             [] -> error "startScheduler: no nodes"
             sortedLNodes@(n : _) -> do
               void $ forkProcess n $ do
                 lproc <- ask
                 DP.liftIO $ putMVar schedulerVar lproc
                 ((go SchedulerState
                        { stateSeed     = mkStdGen seed0
                        , stateAlive    = Set.empty
                        , stateProcs    = Map.empty
                        , stateMessages = Map.empty
                        , stateNSend    = Map.empty
                        , stateMonitors = Map.empty
                        , stateMonitorCounter = 0
                        , stateClock           = 0
                        , stateExpiredTimeouts = Set.empty
                        , stateTimeouts        = Map.empty
                        , stateReverseTimeouts = Map.empty
                        , stateFailures        = Map.empty
                        }
                   `DP.finally` do
                      DP.liftIO $ modifyMVar_ schedulerLock $
                          const $ return False
                  )
                  `DP.catchExit`
                    (\pid StopScheduler -> DP.send pid SchedulerTerminated))
                  `DP.catch` (\e -> do
                     DP.liftIO $ do
                       putStrLn $ "scheduler died: " ++ show e
                       throwIO (e :: SomeException)
                   )
               void $ DP.liftIO $ readMVar schedulerVar
               return (True, sortedLNodes)
  where
    go :: SchedulerState -> Process a
    go st@(SchedulerState _ alive procs msgs nsMsgs _ _ _ expired timeouts _ _)
        -- Enter this equation if all processes are waiting for a transition
      | Set.size alive == Map.size procs && not (Set.null alive) = do
        -- complain if no process has a message and there are no messages to
        -- put in a mailbox
        let systemStuck =
                 Map.null (Map.filter id procs)
              && Map.null msgs
              && Map.null nsMsgs
              && Set.null expired
        when (systemStuck && Map.null timeouts) $
          error $ "startScheduler: All processes (" ++ show (Set.size alive) ++
                  ") are blocked."
        -- pick next transition
        let (r , st') = pickNextTransition $
                          if systemStuck then jumpToNextTimeout st else st
        case r of
          PutMsg pid msg | isExceptionMsg msg -> do
             forwardSystemMsg msg
             go st' { stateProcs = Map.delete pid (stateProcs st') }
          PutMsg pid msg -> do
             forwardSystemMsg msg
             -- if the process was blocked let's ask it to check again if it
             -- has a message.
             procs'' <- if isBlocked pid procs
               then do DP.send pid Continue
                       return $ Map.delete pid (stateProcs st')
               else return $ stateProcs st'
             go st' { stateProcs = procs'' }
          PutNSendMsg nid label msg -> do
             DP.whereisRemoteAsync nid label
             DP.WhereIsReply _ mpid <- DP.expect
             case mpid of
               Nothing -> do
                 go st'
               Just pid -> do
                 forwardSystemMsg (MailboxMsg pid msg)
                 -- if the process was blocked let's ask it to check again if it
                 -- has a message.
                 procs'' <- if isBlocked pid procs
                   then do DP.send pid Continue
                           return $ Map.delete pid (stateProcs st')
                   else return $ stateProcs st'
                 go st' { stateProcs = procs'' }
          ContinueMsg pid -> do
             DP.send pid Continue
             go st'
          TimeoutMsg pid -> do
             DP.send pid Timeout
             go st'

    -- enter the next equation if some process is still active
    go st@(SchedulerState _ alive procs _ _ monitors mcounter clock
                          expired timeouts revTimeouts failures
          ) = do
      when (Set.size alive > 1 + Map.size procs) $
        error $ "startScheduler: More than one process is alive: "
                ++ show (alive, procs)
      DP.receiveWait
        [ DP.match $ \m -> case m of
        GetTime pid -> DP.send pid clock >> go st
        -- a process is sending a message
        Send source pid msg ->
          handleSend st (source, pid, msg) >>= go
        NSend source nid label msg ->
          handleNSend st (source, nid, label, msg) >>= go
        -- a process has a message and is ready to process it
        Yield pid -> do
            when (not $ Set.member pid alive) $
              error $ "startScheduler invalid Yield: " ++ show (m, alive)
            let (mt, revTimeouts') =
                   Map.updateLookupWithKey (\_ _ -> Nothing) pid revTimeouts
            go st { stateProcs = Map.insert pid True procs
                  , stateExpiredTimeouts = Set.delete pid expired
                  , stateTimeouts =
                      maybe timeouts (\t -> multimapDelete t pid timeouts) mt
                  , stateReverseTimeouts = revTimeouts'
                  }
        -- a process has no messages and will block
        Block pid Nothing -> do
            when (not $ Set.member pid alive) $
              error $ "startScheduler invalid Block: " ++ show (m, alive)
            go st { stateProcs = Map.insert pid False procs }
        Block pid (Just ts) -> do
            when (not $ Set.member pid alive) $
              error $ "startScheduler invalid Block: " ++ show (m, alive)
            let mts = (\t -> multimapDelete t pid timeouts) <$>
                        Map.lookup pid revTimeouts
            go st { stateProcs = Map.insert pid False procs
                  , stateTimeouts =
                      Map.insertWith union (clock + ts) [pid]
                        $ maybe timeouts id mts
                  , stateReverseTimeouts =
                      Map.insert pid (clock + ts) revTimeouts
                  }
        -- a new process will be created
        SpawnedProcess child p -> do
            _ <- DP.monitor child
            DP.send p SpawnAck
            go st { stateAlive = Set.insert child alive
                  , stateProcs = Map.insert child True procs
                  }
        -- the process who is monitoring whom
        Monitor who whom@(DP.ProcessIdentifier whomPid) isLink -> do
            let ref = DP.MonitorRef (DP.ProcessIdentifier who) mcounter
            if Set.member whomPid alive then do
              DP.send who ref
              go st { stateMonitors =
                        Map.insertWith (++) whom [(ref, isLink)] monitors
                    , stateMonitorCounter = mcounter + 1
                    }
            else do
              send who $
                DP.ProcessMonitorNotification ref whomPid DP.DiedUnknownId
              DP.send who ref
              go st { stateMonitorCounter = mcounter + 1 }
        -- monitoring a node
        Monitor who whom isLink -> do
            let ref = DP.MonitorRef (DP.ProcessIdentifier who) mcounter
            DP.send who ref
            go st { stateMonitors =
                      Map.insertWith (++) whom [(ref, isLink)] monitors
                  , stateMonitorCounter = mcounter + 1
                  }
        Unmonitor ref -> do
            go st { stateMonitors = Map.filter (not . null)
                                  $ Map.map (filter ((ref /=) . fst)) monitors
                  }
        Unlink who whom -> do
            let upd xs =
                  case [ x | x@( DP.MonitorRef (DP.ProcessIdentifier who') _
                               , True
                               ) <- xs
                           , who == who'
                       ] of
                    []  -> Nothing
                    xs' -> Just xs'
            go st { stateMonitors = Map.update upd whom monitors }
        AddFailures fls ->
            go st { stateFailures = foldr (uncurry Map.insert) failures fls }
        RemoveFailures fls ->
            go st { stateFailures = foldr Map.delete failures fls }

        -- a process has terminated
        , DP.match $ \(DP.ProcessMonitorNotification _ pid reason) -> do
            st' <- notifyMonitors st (const True) (DP.processNodeId pid)
                                  (DP.ProcessIdentifier pid) reason
            let (mt, revTimeouts') =
                  Map.updateLookupWithKey (\_ _ -> Nothing)
                                          pid (stateReverseTimeouts st')
            go st' { stateAlive    = Set.delete pid (stateAlive st')
                   , stateProcs    = Map.delete pid (stateProcs st')
                   , stateMessages = Map.delete pid (stateMessages st')
                   , stateExpiredTimeouts =
                       Set.delete pid (stateExpiredTimeouts st')
                   , stateTimeouts =
                       maybe timeouts
                             (\t -> multimapDelete t pid $ stateTimeouts st') mt
                   , stateReverseTimeouts = revTimeouts'
                   }
         ]

    handleSend :: SchedulerState
               -> (ProcessId, ProcessId, SystemMsg)
                  -- ^ (sender, destination, message)
               -> Process SchedulerState
    handleSend st (source, pid, msg) | Set.member pid (stateAlive st) = do
      let mp = Map.lookup (DP.processNodeId source, DP.processNodeId pid)
                          (stateFailures st)
      case mp of
        -- drop message
        Just p | (v, seed') <- randomR (0.0, 1.0) (stateSeed st), v <= p -> do
          let srcNid = DP.processNodeId source
          notifyMonitors (st { stateSeed = seed' }) (== srcNid)
                         srcNid
                         (DP.ProcessIdentifier pid)
                         DP.DiedDisconnect
        -- deliver message
        _ -> return st
               { stateMessages =
                   Map.insertWith
                     (const $ Map.insertWith (flip (++)) source [msg])
                     pid (Map.singleton source [msg]) (stateMessages st)
               }
    handleSend st (_, _, msg) = do
      -- If the target is not known to the scheduler we assume it doesn't
      -- matter in which order messages are delivered to it.
      forwardSystemMsg msg
      return st

    handleNSend :: SchedulerState
                -> (ProcessId, NodeId, String, DP.Message)
                -> Process SchedulerState
    handleNSend st (source, nid, label, msg) = do
      case Map.lookup (DP.processNodeId source, nid) (stateFailures st) of
        -- drop message
        Just p | (v, seed') <- randomR (0.0, 1.0) (stateSeed st), v <= p -> do
          let srcNid = DP.processNodeId source
          notifyMonitors (st { stateSeed = seed' }) (== srcNid)
                         srcNid
                         (DP.NodeIdentifier nid)
                         DP.DiedDisconnect
        -- deliver message
        _ ->
          return st
            { stateNSend =
                Map.insertWith (const $ Map.insertWith (flip (++)) source [msg])
                               (nid, label)
                               (Map.singleton source [msg])
                               (stateNSend st)
            }

    notifyMonitors :: SchedulerState
                   -> (NodeId -> Bool)  -- ^ Whether monitors residing on a
                                        -- particular node should be notified.
                   -> NodeId -- ^ Id of the node where the notification
                             -- originated. For disconnected monitored
                             -- processes, this is the node detecting the
                             -- disconnection. For dead processes, this is the
                             -- node where the dead process resided.
                   -> DP.Identifier -- ^ Id of the process which was monitored.
                   -> DP.DiedReason
                   -> Process SchedulerState
    notifyMonitors st shouldNotify srcNid dpId@(DP.ProcessIdentifier pid) reason
      =
      case Map.lookup (DP.ProcessIdentifier pid) (stateMonitors st) of
        Just mons -> do
          let (shouldMons, otherMons) =
                partition (\(DP.MonitorRef src _, _) ->
                             shouldNotify $ DP.nodeOf src
                          )
                          mons
              sends = flip map shouldMons $
                \(ref@(DP.MonitorRef (DP.ProcessIdentifier p) _)
                 , isLink
                 ) ->
                  if isLink
                  then ( DP.nullProcessId srcNid, p, LinkExceptionMsg dpId p reason)
                  else ( DP.nullProcessId srcNid
                       , p
                       , MailboxMsg p $
                           DP.createUnencodedMessage $
                           DP.ProcessMonitorNotification ref pid reason
                       )
          let st' = st { stateMonitors =
                           if null otherMons then
                             Map.delete (DP.ProcessIdentifier pid)
                                        (stateMonitors st)
                           else Map.insert (DP.ProcessIdentifier pid)
                                           otherMons
                                           (stateMonitors st)
                       }
          foldM handleSend st' sends
        Nothing ->
          return st
    notifyMonitors st shouldNotify srcNid (DP.NodeIdentifier nid) reason = do
      let impliesDeathOf (DP.NodeIdentifier nid') = nid == nid'
          impliesDeathOf (DP.ProcessIdentifier p) = nid == DP.processNodeId p
          impliesDeathOf _                        = False
          (mons, remainingMons) =
            Map.partitionWithKey (const . impliesDeathOf) (stateMonitors st)
          mkMsg dpId ((DP.MonitorRef (DP.ProcessIdentifier p) _), True) =
            (DP.nullProcessId srcNid, p, LinkExceptionMsg dpId p reason)
          mkMsg (DP.ProcessIdentifier pid)
                (ref@(DP.MonitorRef (DP.ProcessIdentifier p) _), False) =
            ( DP.nullProcessId srcNid
            , p
            , MailboxMsg p $ DP.createUnencodedMessage $
                               DP.ProcessMonitorNotification ref pid reason
            )
          mkMsg (DP.NodeIdentifier _)
                (ref@(DP.MonitorRef (DP.ProcessIdentifier p) _), False) =
            ( DP.nullProcessId srcNid
            , p
            , MailboxMsg p $ DP.createUnencodedMessage $
                               DP.NodeMonitorNotification ref nid reason
            )
          mkMsg _ _ = error "scheduler.notifyMonitors.mkMsg: unimplemented case"
          (shouldMons, otherMons) =
            let splitMons = partition (\(DP.MonitorRef dpId _, _) ->
                                         shouldNotify $ DP.nodeOf dpId
                                      )
                              <$> mons
             in (fst <$> splitMons, snd <$> splitMons)

          st' = st { stateMonitors =
                       Map.union (Map.filter (not . null) otherMons)
                                 remainingMons
                   }
      foldM handleSend st' [ mkMsg k x | (k, xs) <- Map.toList shouldMons
                                       , x <- xs
                           ]
    notifyMonitors _ _ _ _ _ =
      error "scheduler.notifyMonitors: unimplemented case"

    multimapDelete :: (Ord k, Eq a) => k -> a -> Map k [a] -> Map k [a]
    multimapDelete k x = flip Map.update k $ \xs ->
      case delete x xs of
        []  -> Nothing
        xs' -> Just xs'

    -- is the given process waiting for a new message?
    isBlocked pid procs =
      maybe (error $ "startScheduler.isBlocked: missing pid " ++ show pid) not
        $ Map.lookup pid procs

    isExceptionMsg (LinkExceptionMsg _ _ _) = True
    isExceptionMsg (ExitMsg _ _ _) = True
    isExceptionMsg (KillMsg _ _ _) = True
    isExceptionMsg _ = False

    -- | @chooseUniformly [(n_0, f_0),...,(n_k, f_k)] g@
    -- Chooses a value from the range @(0, sum n_i)@ and then applies the
    -- function @f_i@ corresponding to the subrange of the selected value.
    chooseUniformly :: (Num i, Ord i, Random i, RandomGen g)
                    => g -> [(i, i -> g -> a)] -> a
    chooseUniformly seed ranges =
      let (i, seed') = randomR (0, sum (map fst ranges) - 1) seed
          pick xs n = case xs of
            [] -> error "Scheduler.chooseUniformly: used with empty list."
            (k, f) : xs' | n < k     -> f n seed'
                         | otherwise -> pick xs' (n - k)
       in pick ranges i

    -- Picks the next transition.
    pickNextTransition :: SchedulerState
                       -> ( TransitionRequest
                          , SchedulerState
                          )
    pickNextTransition st@(SchedulerState seed _ procs msgs nsMsgs _ _ _
                                          expired _ _ _
                          ) =
      second tickClock $ chooseUniformly seed $
        [ let has_a_message = Map.filter id procs
           in (Map.size has_a_message, \i seed' ->
                 let (pid, _) = Map.elemAt i has_a_message
                  in ( ContinueMsg pid
                     , st { stateSeed  = seed'
                            -- the process is active again
                          , stateProcs = Map.delete pid procs
                          }
                     )
              )
        ] ++
        [ (Map.size pidMsgs, \i seed' ->
             let (sender, m : ms) = Map.elemAt i pidMsgs
              in ( PutMsg pid m
                 , st { stateSeed = seed'
                      , stateMessages =
                          if null ms -- make sure to delete all empty containers
                          then if 1 == Map.size pidMsgs then Map.delete pid msgs
                               else Map.adjust (Map.delete sender) pid msgs
                          else Map.adjust (Map.adjust tail sender) pid msgs
                      }
                 )
          )
        | (pid, pidMsgs) <- Map.toList msgs
        ] ++
        [ (Map.size nidlMsgs, \i seed' ->
             let (sender, m : ms) = Map.elemAt i nidlMsgs
              in ( PutNSendMsg nid label m
                 , st { stateSeed = seed'
                      , stateNSend =
                          if null ms -- make sure to delete all empty containers
                          then if 1 == Map.size nidlMsgs
                               then Map.delete (nid, label) nsMsgs
                               else Map.adjust (Map.delete sender) (nid, label)
                                               nsMsgs
                          else Map.adjust (Map.adjust tail sender) (nid, label)
                                          nsMsgs
                      }
                 )

          )
        | ((nid, label), nidlMsgs) <- Map.toList nsMsgs
        ] ++
        [ (Set.size expired, \i seed' ->
            let pid = Set.elemAt i expired
             in ( TimeoutMsg pid
                , st { stateSeed = seed'
                     , stateExpiredTimeouts = Set.deleteAt i expired
                       -- the process is active again
                     , stateProcs = Map.delete pid procs
                     }
                )
          )
        ]

    -- Moves the clock to the next timeout.
    jumpToNextTimeout :: SchedulerState -> SchedulerState
    jumpToNextTimeout st =
      tickClock st { stateClock = fst $ Map.findMin (stateTimeouts st) }

    tickClock :: SchedulerState -> SchedulerState
    tickClock st =
      let clock' = stateClock st + clockDelta
          (newExpired, mtpid, trest) =
            Map.splitLookup (clock' + 1) (stateTimeouts st)
          expired' = Set.unions $
            stateExpiredTimeouts st : map Set.fromList (Map.elems newExpired)
       in st { stateClock = clock'
               -- add the newly expired timeouts
             , stateExpiredTimeouts = expired'
               -- remove the newly expired timeouts
             , stateTimeouts = maybe id (Map.insert (clock' + 1)) mtpid trest
             , stateReverseTimeouts =
                 foldr Map.delete (stateReverseTimeouts st) $ concat $
                   Map.elems newExpired
             }

-- | Stops the scheduler.
--
-- It is ok to close the nodes returned by 'startScheduler' afterwards.
stopScheduler :: IO ()
stopScheduler = do
    msproc <- tryTakeMVar schedulerVar
    running <- modifyMVar schedulerLock $ \running -> do
      return (False,running)
    forM_ msproc $ \sproc ->
      when running $ runProcess (processNode sproc) $ do
        DP.exit (processId sproc) StopScheduler
        SchedulerTerminated <- DP.expect
        return ()

-- | Wraps a 'Process' computation with calls to 'startScheduler' and
-- 'stopScheduler'.
withScheduler :: Int       -- ^ seed
              -> Int       -- ^ clock speed (microseconds/transition)
              -> Int       -- ^ amount of nodes to create
              -> Transport -- ^ transport to use for the nodes
              -> DP.RemoteTable -- ^ remote table to use for the nodes
              -> ([LocalNode] -> Process ())
                   -- ^ Computation to wrap
                   --
                   -- The list of nodes does not include the local node in which
                   -- the computation runs.
              -> IO ()
withScheduler s clockDelta numNodes transport rtable p =
    bracket (startScheduler s clockDelta numNodes transport rtable)
            (mapM_ closeLocalNode) $ \(n : ns) -> do
      tid <- myThreadId
      mv <- newEmptyMVar
      _ <- forkProcess n $ do
        do spid <- processId <$> DP.liftIO getScheduler
           DP.link spid
           self <- DP.getSelfPid
           DP.send spid $ SpawnedProcess self self
           SpawnAck <- DP.expect
           Continue <- DP.expect
           p ns
           DP.unlink spid
          `DP.finally` DP.liftIO stopScheduler
        DP.liftIO $ putMVar mv ()
       `DP.catch` \e -> DP.liftIO $ do
         throwTo tid (e :: SomeException)
         throwIO e
      takeMVar mv

-- | Yields control to some other process.
yield :: Process ()
yield = do DP.getSelfPid >>= sendS . Yield
           Continue <- DP.expect
           return ()

-- | Thrown by wrapped primitives when the scheduler was meant to be enabled
-- but it is not running.
data AbsentScheduler = AbsentScheduler
  deriving Show

instance Exception AbsentScheduler

-- | Yields the local process of the scheduler.
getScheduler :: IO LocalProcess
getScheduler =
    tryReadMVar schedulerVar >>=
      maybe (throwIO AbsentScheduler) return

-- | Have messages between pairs of nodes drop with some probability.
--
-- @((n0, n1), p)@ indicates that messages from @n0@ to @n1@ should be
-- dropped with probability @p@.
addFailures :: [((NodeId, NodeId), Double)] -> Process ()
addFailures = sendS . AddFailures

-- | Have messages between pairs of nodes never drop.
--
-- @(n0, n1)@ means that messages from @n0@ to @n1@ shouldn't be dropped
-- anymore.
removeFailures :: [(NodeId, NodeId)] -> Process ()
removeFailures = sendS . RemoveFailures

-- TODO: Implementing 'send' correctly when testing failures requires
-- remembering the failed connections. Right now it is treated as 'usend'.

-- | Sends a transition request of type (1) to the scheduler.
-- The scheduler will take care of placing the message in the mailbox of the
-- target process. Returns immediately.
send :: Serializable a => ProcessId -> a -> Process ()
send pid msg = do
  self <- DP.getSelfPid
  sendS $ Send self pid $ MailboxMsg
    pid
    (DP.createUnencodedMessage msg)

usend :: Serializable a => ProcessId -> a -> Process ()
usend = send

-- | Log a string
say :: String -> Process ()
say string = do
    self <- DP.getSelfPid
    sendS $ GetTime self
    now <- DP.expect
    nsend "logger" (show (now :: Int), self, string)

nsendRemote :: Serializable a => NodeId -> String -> a -> Process ()
nsendRemote nid label msg = do
    self <- DP.getSelfPid
    sendS $ NSend self nid label $ DP.createMessage msg

nsend :: Serializable a => String -> a -> Process ()
nsend label a = DP.whereis label >>= maybe (return ()) (flip usend a)

-- TODO sendChan has the semantics of usend regarding reconnections.

sendChan :: Serializable a => SendPort a -> a -> Process ()
sendChan sendPort msg = do
    self <- DP.getSelfPid
    let spId = DP.sendPortId sendPort
    sendS $ Send self (DP.sendPortProcessId spId) $ ChannelMsg
      spId
      (DP.createUnencodedMessage msg)

-- | Forward a raw 'Message' to the given 'ProcessId'.
uforward :: DP.Message -> ProcessId -> Process ()
uforward msg pid = do
    self <- DP.getSelfPid
    sendS $ Send self pid $ MailboxMsg pid msg

-- | Sends a message to the scheduler.
sendS :: Serializable a => a -> Process ()
sendS a = DP.liftIO getScheduler >>= flip DP.send a . processId

-- The receiveWait and receiveWaitT functions are marked NOINLINE,
-- because this way the "if" statement only has to be evaluated once
-- and not at every call site.  After the first evaluation, these
-- top-level functions are simply a jump to the appropriate function.

{-# NOINLINE receiveWait #-}
receiveWait :: [ Match b ] -> Process b
receiveWait ms =
    if schedulerIsEnabled
    then do Just b <- receiveTimeoutM Nothing ms
            return b
    else DP.receiveWait $ map (flip unMatch Nothing) ms

{-# NOINLINE receiveTimeout #-}
receiveTimeout :: Int -> [ Match b ] -> Process (Maybe b)
receiveTimeout us =
    if schedulerIsEnabled
    then receiveTimeoutM (Just us)
    else DP.receiveTimeout us . map (flip unMatch Nothing)

-- | Submits a transition request of type (2) to the scheduler.
-- Blocks until the transition is allowed and any of the match clauses
-- is performed.
receiveTimeoutM :: Maybe Int -> [ Match b ] -> Process (Maybe b)
receiveTimeoutM mus ms = do
    r <- DP.liftIO $ newIORef False
    go r mus $ map (flip unMatch $ Just r) ms
  where
    go r mts ms' = do
      self <- DP.getSelfPid
      void $ DP.receiveTimeout 0 ms'
      hasMsg <- DP.liftIO $ readIORef r
      if hasMsg || mus == Just 0 then do
        sendS (Yield self)
        Continue <- DP.expect
        DP.receiveTimeout 0 $ map (flip unMatch Nothing) ms
      else do
        sendS (Block self mts)
        command <- DP.expect
        case command of
          Continue -> go r Nothing ms'
          Timeout  -> return Nothing
          SpawnAck -> do
            DP.say "receiveTimeoutM: unexpected SpawnAck"
            error "receiveTimeoutM: unexpected SpawnAck"

-- | Shorthand for @receiveWait [ match return ]@
expect :: Serializable a => Process a
expect = receiveWait [ match return ]

-- | Wait for a message on a typed channel.
receiveChan :: Serializable a => ReceivePort a -> Process a
receiveChan rPort = receiveWait [ matchChan rPort return ]

-- | Opaque type used by 'receiveWait'.
newtype Match a = Match { unMatch :: Maybe (IORef Bool) -> DP.Match a }

-- | Match against any message of the right type.
match :: Serializable a => (a -> Process b) -> Match b
match = matchIf (const True)

-- | Match against any message of the right type but only if the predicate is
-- satisfied.
matchIf :: Serializable a => (a -> Bool) -> (a -> Process b) -> Match b
matchIf p h = Match $ \mr -> case mr of
    Nothing -> DP.matchIf p h
    Just r  -> DP.matchIf (\a -> p a && seq (unsafeWriteIORef r True a) False) h

unsafeWriteIORef :: IORef a -> a -> b -> b
unsafeWriteIORef r a b = unsafePerformIO $ do
    writeIORef r a
    return b

-- | Match against an arbitrary message. 'matchAny' removes the first available
-- message from the process mailbox.
matchAny :: (DP.Message -> Process b) -> Match b
matchAny h = Match $ \mr -> case mr of
    Nothing -> DP.matchAny h
    Just r  -> fmap undefined $
      DP.matchMessageIf (\a -> seq (unsafeWriteIORef r True a) False) return

-- | Match on arbitrary STM action.
--
-- This is the basic building block for 'matchChan'.
matchSTM :: STM a -> (a -> Process b) -> Match b
matchSTM sa h = Match $ \mr -> case mr of
                  Nothing -> DP.matchSTM sa h
                  Just r  -> DP.matchSTM (sa >> setAndRetry r) h
  where
    setAndRetry r = unsafePerformIO (writeIORef r True) `seq` retry

-- | Match on a typed channel.
matchChan :: ReceivePort a -> (a -> Process b) -> Match b
matchChan = matchSTM . DP.receiveSTM

-- | Monitors a process, sending to the caller a @ProcessMonitorNotification@
-- when the process dies.
monitor :: ProcessId -> Process DP.MonitorRef
monitor pid = do self <- DP.getSelfPid
                 sendS $ Monitor self (DP.ProcessIdentifier pid) False
                 DP.expect

-- | Stops monitoring a process.
unmonitor :: DP.MonitorRef -> Process ()
unmonitor = sendS . Unmonitor

-- | Monitors a process, sending to the caller a @NodeMonitorNotification@
-- when the node is disconnected.
monitorNode :: NodeId -> Process DP.MonitorRef
monitorNode nid = do
    self <- DP.getSelfPid
    sendS $ Monitor self (DP.NodeIdentifier nid) False
    DP.expect

-- | Links a process, throwing to the caller a @ProcessLinkException@
-- when the process dies.
link :: ProcessId -> Process ()
link pid = do self <- DP.getSelfPid
              sendS $ Monitor self (DP.ProcessIdentifier pid) True
              _ <- DP.expect :: Process DP.MonitorRef
              return ()

unlink :: ProcessId -> Process ()
unlink pid = do self <- DP.getSelfPid
                sendS $ Unlink self $ DP.ProcessIdentifier pid

-- | Links a process, throwing to the caller a @ProcessLinkException@
-- when the process dies.
linkNode :: NodeId -> Process ()
linkNode nid = do
    self <- DP.getSelfPid
    sendS $ Monitor self (DP.NodeIdentifier nid) True
    _ <- DP.expect :: Process DP.MonitorRef
    return ()

-- | Throws a 'ProcessExitException' to the given process.
exit :: Serializable a => ProcessId -> a -> Process ()
exit pid reason = do
  self <- DP.getSelfPid
  sendS $ Send self pid $ ExitMsg self pid $ DP.createMessage reason

-- | Forceful request to kill a process.
kill :: ProcessId -> String -> Process ()
kill pid reason = do
  self <- DP.getSelfPid
  sendS $ Send self pid $ KillMsg self pid reason

-- | Notifies the scheduler of a new process. When acknowledged, starts the new
-- process and notifies again the scheduler when the process terminates. Returns
-- immediately.
spawnLocal :: Process () -> Process ProcessId
spawnLocal p = do
    child <- DP.spawnLocal $ do Continue <- DP.expect
                                p
    DP.getSelfPid >>= sendS . SpawnedProcess child
    SpawnAck <- DP.expect
    return child

spawnWrapClosure :: Closure (Process ()) -> Process ()
spawnWrapClosure p = do
    Continue <- DP.expect
    join $ DP.unClosure p

remotable [ 'spawnWrapClosure ]

-- | Notifies the scheduler of a new process. When acknowledged, starts the new
-- process and notifies again the scheduler when the process terminates. Returns
-- immediately.
spawnAsync :: NodeId -> Closure (Process ()) -> Process DP.SpawnRef
spawnAsync nid cp = do
    self <- DP.getSelfPid
    ref <- DP.spawnAsync nid $ $(mkClosure 'spawnWrapClosure) cp
    child <- DP.receiveWait
               [ DP.matchIf (\(DP.DidSpawn ref' _) -> ref' == ref) $
                             \(DP.DidSpawn _ pid) -> return pid
               ]
    DP.getSelfPid >>= sendS . SpawnedProcess child
    SpawnAck <- DP.expect
    usend self (DP.DidSpawn ref child)
    return ref

-- | Notifies the scheduler of a new process. When acknowledged, starts the new
-- process and notifies again the scheduler when the process terminates. Returns
-- immediately.
spawn :: NodeId -> Closure (Process ()) -> Process ProcessId
spawn nid cp = do
    ref <- spawnAsync nid cp
    receiveWait [ matchIf (\(DP.DidSpawn ref' _) -> ref' == ref) $
                           \(DP.DidSpawn _ pid) -> return pid
                ]

-- | Create a new typed channel, spawn a process on the local node, passing it
-- the receive port, and return the send port
spawnChannelLocal :: Serializable a
                  => (ReceivePort a -> Process ())
                  -> Process (SendPort a)
spawnChannelLocal proc = do
    mvar <- DP.liftIO newEmptyMVar
    -- This is spawnChannelLocal from d-p, with the addition of a c-h channel to
    -- signal to the scheduler that the mvar is filled.
    (sp, rp) <- DP.newChan
    _ <- spawnLocal $ do
      -- It is important that we allocate the new channel in the new process,
      -- because otherwise it will be associated with the wrong process ID
      (sport, rport) <- DP.newChan
      sendChan sp ()
      DP.liftIO $ putMVar mvar sport
      proc rport
    receiveChan rp
    DP.liftIO $ takeMVar mvar

-- | Local version of 'call'. Running a process in this way isolates it from
-- messages sent to the caller process, and also allows silently dropping late
-- or duplicate messages sent to the isolated process after it exits.
-- Silently dropping messages may not always be the best approach.
callLocal :: Process a -> Process a
callLocal proc = DP.mask $ \release -> do
    mv    <- DP.liftIO newEmptyMVar :: Process (MVar (Either SomeException a))
    -- This is callLocal from d-p, with the addition of a c-h channel to signal
    -- to the scheduler that the mvar is filled.
    (sp, rp) <- DP.newChan
    (spInit, rpInit) <- DP.newChan -- TODO: Remove when spawnLocal inherits the
                                   -- masking state.
    child <- spawnLocal $ DP.mask_ $ do
               sendChan spInit ()
               r <- DP.try (release proc)
               sendChan sp ()
               DP.liftIO $ putMVar mv r
    rs <- (do receiveChan rp
              DP.liftIO (takeMVar mv)
            `DP.catch` \e ->
             do -- Don't kill the child before knowing that it had a chance
                -- to mask exceptions.
                --
                -- Also, be sure to rethrow async exceptions received during
                -- the cleanup. System.Timeout.timeout is sensitive to this.
                --
                -- Ideally, we would mask exceptions uninterruptibly, but the
                -- scheduler could block as it does not support doing this.
                uninterruptiblyMaskKnownExceptions_ $ receiveChan rpInit
                kill child ("exception in parent process " ++ show e)
                uninterruptiblyMaskKnownExceptions_ $ receiveChan rp
                DP.liftIO $ throwIO (e :: SomeException)
          )
    either throw return rs

-- Evaluates the given closure. Whenever known exceptions are raised,
-- the closure is retried and the exceptions are collected and rethrown after
-- evaluation of the closure succeeds.
--
-- This is a trick to simulate 'uninterruptibleMask_' at points where only
-- asynchronous exceptions are expected.
--
-- Unknown exception are not handled. The known exceptions are:
-- * 'ProcessExitException'
-- * 'ProcessKillException'
-- * 'ProcessLinkException'
-- * 'NodeLinkException'
--
-- These are all the exceptions the scheduler would ever deliver asynchronously.
--
uninterruptiblyMaskKnownExceptions_ :: Process a -> Process a
uninterruptiblyMaskKnownExceptions_ p = do
    (a, asyncRethrow) <- collectExceptions p
    asyncRethrow
    return a
  where
    collectExceptions :: Process a -> Process (a, Process ())
    collectExceptions proc = do
      let handler pid msg = do
            (a, r) <- collectExceptions proc
            self <- DP.getSelfPid
            return (a, sendS (Send pid self msg) >> r)
      self <- DP.getSelfPid
      (proc >>= \a -> return (a, return ()))
        `DP.catches`
          [ DP.Handler $ \(DP.ProcessExitException pid reason) ->
               handler pid (ExitMsg pid self reason)
          , DP.Handler $ \(ProcessKillException pid reason) ->
               handler pid (KillMsg pid self reason)
          , DP.Handler $ \(DP.ProcessLinkException pid reason) ->
               handler pid $
                 LinkExceptionMsg (DP.ProcessIdentifier pid) self reason
          , DP.Handler $ \(DP.NodeLinkException nid reason) ->
               handler (DP.nullProcessId nid) $
                 LinkExceptionMsg (DP.NodeIdentifier nid) self reason
          ]

-- | Looks up a process in the local registry.
whereis :: String -> Process (Maybe ProcessId)
whereis label = do
    self <- DP.getSelfPid
    sendS (Yield self)
    Continue <- DP.expect
    DP.whereis label

-- | Registers a process in the local registry.
register :: String -> ProcessId -> Process ()
register label p = yield >> DP.register label p

-- | Like 'register', but will replace an existing registration.
-- The name must already be registered.
reregister :: String -> ProcessId -> Process ()
reregister label p = yield >> DP.reregister label p

-- | Looks up a process in the registry of a node.
whereisRemoteAsync :: NodeId -> String -> Process ()
whereisRemoteAsync n label = do
    yield
    DP.whereisRemoteAsync n label
    reply <- DP.receiveWait
      [ DP.matchIf (\(DP.WhereIsReply label' _) -> label == label') return ]
    DP.getSelfPid >>= flip usend reply

-- | Registers a process in the registry of a node.
registerRemoteAsync :: NodeId -> String -> ProcessId -> Process ()
registerRemoteAsync n label p = do
    yield
    DP.registerRemoteAsync n label p
    reply <- DP.receiveWait
      [ DP.matchIf (\(DP.RegisterReply label' _ _) -> label == label') return ]
    DP.getSelfPid >>= flip usend reply

-- | Opaque type used by 'receiveWaitT'.
newtype MatchT m a =
    MatchT { unMatchT :: Maybe (IORef Bool) -> DPT.MatchT m a }

-- | Match against any message of the right type
matchT :: (Serializable a, MonadProcess m) => (a -> m b) -> MatchT m b
matchT = matchIfT (const True)

-- | Match against any message of the right type that satisfies a predicate
matchIfT :: Serializable a => (a -> Bool) -> (a -> m b) -> MatchT m b
matchIfT p h = MatchT $ \mr -> case mr of
                Nothing -> DPT.matchIfT p h
                Just r  -> DPT.matchIfT (\a -> p a && test r a) h
  where
    test r a = snd $ unsafePerformIO $ do
                 writeIORef r True
                 return (a,False)

{-# NOINLINE receiveWaitT #-}
receiveWaitT :: MonadProcess m => [MatchT m b] -> m b
receiveWaitT = if schedulerIsEnabled
               then receiveWaitTSched
               else DPT.receiveWaitT . map (flip unMatchT Nothing)
  where
    -- | Submits a transition request of type (2) to the scheduler.
    -- Blocks until the transition is allowed and any of the match clauses
    -- is performed.
    receiveWaitTSched ms = do
        r <- liftProcess $ DP.liftIO $ newIORef False
        go r $ map (flip unMatchT $ Just r) ms
      where
        go r ms' = do
          self <- liftProcess DP.getSelfPid
          void $ DPT.receiveTimeoutT 0 ms'
          hasMsg <- liftProcess $ DP.liftIO $ readIORef r
          if hasMsg then do
            liftProcess $ sendS (Yield self)
            Continue <- liftProcess DP.expect
            DPT.receiveWaitT $ map (flip unMatchT Nothing) ms
           else do
            liftProcess $ sendS (Block self Nothing)
            Continue <- liftProcess DP.expect
            go r ms'
