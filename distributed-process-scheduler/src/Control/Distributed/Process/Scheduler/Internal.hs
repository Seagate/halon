-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- This module provides the implementation of the scheduler and the replacement
-- for distributed-process functions which communicate with it.

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE MonoLocalBinds #-}

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
  , matchMessageIf
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
  , spawnMonitor
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
  , schedulerTrace
  , ifSchedulerIsEnabled
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
import qualified "distributed-process" Control.Distributed.Process.Internal.Primitives as DP
import Control.Distributed.Process.Internal.StrictMVar ( withMVar )
import "distributed-process-trans" Control.Distributed.Process.Trans ( MonadProcess(..) )
import qualified "distributed-process-trans" Control.Distributed.Process.Trans as DPT
import qualified Control.Distributed.Process.Internal.WeakTQueue as DP
import Control.Distributed.Process.Internal.Types (LocalProcess(..))

import Control.Concurrent (myThreadId)
import Control.Concurrent.MVar hiding (withMVar)
import Control.Exception (throwTo)
import Control.Monad
import Control.Monad.Catch
import Control.Monad.Reader ( ask )
import Data.Accessor ((^.))
import Data.Binary ( Binary(..), decode )
import Data.Function (fix, on)
import Data.Int
import Data.IORef ( newIORef, writeIORef, readIORef, IORef )
import Data.List (delete, union, sortBy, partition)
import Data.Map ( Map )
import qualified Data.Map as Map
import Data.Set ( Set )
import qualified Data.Set as Set
import Data.Time.Clock
import Data.Typeable ( Typeable )
import GHC.Generics ( Generic )
import Network.Transport (Transport)
import System.Environment (lookupEnv)
import System.IO
import System.IO.Unsafe ( unsafePerformIO )
import System.Mem.Weak (deRefWeak)
import System.Random
import Unsafe.Coerce


-- | @True@ iff the package "distributed-process-scheduler" should be
-- used (iff DP_SCHEDULER_ENABLED environment variable is 1, to be
-- replaced with HFlags in the future).
{-# NOINLINE schedulerIsEnabled #-}
schedulerIsEnabled :: Bool
schedulerIsEnabled = unsafePerformIO $
    maybe False (== "1") <$> lookupEnv "DP_SCHEDULER_ENABLED"

-- | Yields the first value if 'schedulerIsEnabled' is @True@,
-- otherwise it yields the second value.
ifSchedulerIsEnabled :: a -> a -> a
ifSchedulerIsEnabled a b
    | schedulerIsEnabled = a
    | otherwise          = b

-- | A tracing function for debugging purposes.
schedulerTrace :: String -> Process ()
schedulerTrace msg = do
    let b = unsafePerformIO $
              maybe False (elem "d-p-scheduler" . words)
                <$> lookupEnv "DP_SCHEDULER_TRACING"
    when b $ ifSchedulerIsEnabled
      (do self <- DP.getSelfPid
          DP.liftIO $ hPutStrLn stderr $
            show self ++ ": [d-p-scheduler] " ++ msg
      )
      (DP.say $ "[d-p-scheduler] " ++ msg)

-- | Tells if there is a scheduler running.
{-# NOINLINE schedulerLock #-}
schedulerLock :: MVar Bool
schedulerLock = unsafePerformIO $ newMVar False

-- | Holds the scheduler pid if there is a scheduler running.
{-# NOINLINE schedulerVar #-}
schedulerVar :: MVar LocalProcess
schedulerVar = unsafePerformIO newEmptyMVar

-- | Messages that the scheduler can queue to deliver to a processes.
--
-- The semantics of these messages are implemented in the function
-- 'forwardSystemMsg'.
--
data SystemMsg
    = -- | @MailboxMsg pid msg@ has message @msg@ sent to a process @pid@.
      MailboxMsg ProcessId DP.Message
      -- | Like 'MailboxMsg' but the message is sent through a channel instead.
    | ChannelMsg DP.SendPortId DP.Message
      -- | @LinkExceptionMsg src dst reason@ has a link exception thrown to the
      -- process @dst@ indicating the @src@ died with the given @reason@.
    | LinkExceptionMsg DP.Identifier ProcessId DP.DiedReason
      -- | @ExitMsg src dst msg@ has process @dst@ terminate with reason @msg@
      -- and reports @src@ as the caller of 'exit'.
    | ExitMsg ProcessId ProcessId DP.Message
      -- | Like 'ExitMsg' but the process is terminated as done by 'kill'.
    | KillMsg ProcessId ProcessId String
  deriving (Typeable, Generic, Show)

instance Binary SystemMsg

-- | Messages that processes send to the scheduler.
data SchedulerMsg
    = -- | @Send source dest message@: sent by process @source@ when it wants to
      -- send a @message@ to process @dest@.
      Send ProcessId ProcessId SystemMsg
      -- | @NSend source destNode label message@: sent by process @source@ when
      -- it wants to send a @message@ to process registered with @label@ at node
      -- @destNode@.
    | NSend ProcessId NodeId String DP.Message
      -- | @Block pid timeout@: sent by process @pid@ when it has no messages to
      -- handle and it wants to block for the given timeout in microseconds.
    | Block ProcessId (Maybe Int)
      -- | @Yield pid@: sent by process @pid@ when it is ready to continue but
      -- it can yield control to some other process if the scheduler so decides.
    | Yield ProcessId
      -- | @SpawnedProcess child p@: sent when a new process was spawned.
      -- 'SpawnAck' needs to be sent to @p@.
    | SpawnedProcess ProcessId ProcessId
      -- | @Monitor who whom isLink@: sent by process @who@ when it wants to
      -- monitor process or node @whom@. @isLink@ is @True@ when linking is
      -- intended.
    | Monitor ProcessId DP.Identifier Bool
      -- | A process wants to stop monitoring some process or node.
    | Unmonitor DP.MonitorRef
      -- | @Unlink who whom@: sent when process @who@ wants to unlink @whom@.
    | Unlink ProcessId DP.Identifier
      -- @WhereIs caller nodeid label@: sent when process @caller@ wants to
      -- query the registry for @label@ at node @nodeid@.
    | WhereIs ProcessId NodeId String
      -- | A process wants to read the virtual clock.
    | GetTime ProcessId
      -- | A process wants to add failures between the given pairs of nodes with
      -- the given probabilities.
    | AddFailures [((NodeId, NodeId), Double)]
      -- | A process wants to remove failures between the given pairs of nodes.
    | RemoveFailures [(NodeId, NodeId)]
  deriving (Generic, Typeable, Show)

-- | Messages that the scheduler sends to a process in response to messages it
-- sent to the scheduler.
data SchedulerResponse
    = -- | Sent after the process sends a 'Yield' or 'Block' message, or to kick
      -- start the execution of a newly spawned process. It is meant to resume
      -- execution of the process.
      Continue
      -- | Like 'Continue' but it has the process unblock by timing out.
    | Timeout
      -- | Acknowledges a 'SpawnedProcess' message.
      --
      -- An ack is needed to implement
      -- 'Control.Distributed.Process.Node.forkProcess' correctly. Otherwise
      -- 'forkProcess' could return before the scheduler is aware of the new
      -- process, which in turn could cause the scheduler to believe the
      -- application is in deadlock if the caller blocks immediately after the
      -- 'forkProcess' call.
    | SpawnAck
      -- | Acknowledges an 'Unlink' message. An ack is needed because if the
      -- linked process dies after the unlink call terminates, the link
      -- exception could be delivered if the 'Unlink' message wasn't processed.
    | UnlinkAck
  deriving (Generic, Typeable, Show)

-- | Actions that the scheduler can choose to perform when all processes block.
--
-- Semantics of these messages are implemented in the @go@ local function of
-- 'startScheduler'.
data Transition
    = -- | Deliver this message to the mailbox of the given process.
      PutMsg ProcessId SystemMsg
      -- | Like 'PutMsg' but it is delivered to whatever process if registered
      -- at the given node with the given name.
    | PutNSendMsg NodeId String DP.Message
      -- | Has the given process continue execution. This is only valid if the
      -- process has sent a 'Yield' message.
    | ContinueMsg ProcessId
      -- | Has the given process timeout. This is only valid if the process has
      -- sent a 'Block' message.
    | TimeoutMsg ProcessId
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

-- | A queue of messages for each pair of processes
--
-- The messages appear in the queue in the order in which they were sent.
-- The outer map uses the destination process as key, and the inner map
-- uses the source process as key.
--
-- Invariants: No inner map is empty and no queue is empty.
type ProcessMessages = Map ProcessId (Map ProcessId [SystemMsg])

-- | Like 'ProcessMessages' but the destination process is allowed to be
-- identified with a @(nodeid, label)@ pair.
type NSendMessages = Map (NodeId, String) (Map ProcessId [DP.Message])

-- The type of the virtual clock. Counts microseconds.
type Time = Int

-- | Internal scheduler state
data SchedulerState = SchedulerState
    { -- | random number generator
      stateSeed     :: StdGen
    , -- | set of tested processes
      stateAlive    :: Set ProcessId
      -- | state of processes
      --
      -- It is 'False' when the process is waiting for a message and @True@
      -- when the process has a message to handle. If the process is running
      -- it has no state in this field.
    , stateProcs    :: Map ProcessId Bool
      -- | Messages targeted to each process
      --
      -- Messages arriving at the mailbox or through a channel endup in the
      -- same queue. TODO: To test more interleavings, each channel should have
      -- its own queue per pair of processes.
    , stateMessages :: ProcessMessages
      -- | Messages targeted with a label
    , stateNSend    :: NSendMessages
      -- | The monitors of each process or node.
      --
      -- The key is the monitored process or node. The boolean indicates if
      -- the monitor is a link.
    , stateMonitors :: Map DP.Identifier [(DP.MonitorRef, Bool)]
      -- | The counter for producing monitor references
    , stateMonitorCounter :: Int32
      -- | The clock of the simulation is used to decide when
      -- timeouts are expired.
    , stateClock :: Time
      -- | The processes blocked with timeouts which have expired
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
      -- This is useful to quickly find if a process has a timeout and when.
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

-- | We redefine 'ProcessKillException' because distributed-process does not
-- export it.
data ProcessKillException =
    ProcessKillException !ProcessId !String
  deriving (Typeable)

instance Exception ProcessKillException
instance Show ProcessKillException where
  show (ProcessKillException pid reason) =
    "killed-by=" ++ show pid ++ ",reason=" ++ reason

-- | We redefine 'throwException' because distributed-process does not export
-- it.
throwException :: Exception e => ProcessId -> e -> Process ()
throwException pid e = do
  proc <- ask
  DP.liftIO $ withLocalProc (DP.processNode proc) pid $ \p ->
    void $ throwTo (DP.processThread p) e

-- | We redefine 'withLocalProc' because distributed-process does not export it.
withLocalProc :: DP.LocalNode
              -> ProcessId
              -> (DP.LocalProcess -> IO ())
              -> IO ()
withLocalProc node pid p =
  let lpid = DP.processLocalId pid in do
  DP.withValidLocalState node $ \vst ->
    forM_ (vst ^. DP.localProcessWithId lpid) p

remotableDecl [ [d|

 -- Forwards a 'SystemMsg' to the application.
 --
 -- An important property of this function is that the message is guaranteed
 -- to be delivered when it completes. Thus, the scheduler can control the order
 -- in which the messages are handled by the application.
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

    -- A version of 'ncEffectLocalPortSend' from distributed-process that can
    -- handled encoded messages.
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
-- the provided seed. This is convenient to make deterministic the behavior of
-- functions in other libraries which also depend on the global random
-- generator. In the case of distributed-process this is necessary to have
-- 'ProcessId's generated with the same uniques.
--
startScheduler :: Int -- ^ seed
               -> Int -- ^ microseconds to increase the clock in every
                      -- transition
               -> Int -- ^ Nodes to create
               -> Transport -- ^ Transport to use for the nodes.
               -> DP.RemoteTable -- ^ RemoteTable to use for the nodes.
               -> IO [LocalNode]
startScheduler seed0 clockDelta numNodes transport rtable = do
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
                   `finally` do
                      DP.liftIO $ modifyMVar_ schedulerLock $
                          const $ return False
                  )
                  `DP.catchExit`
                    (\pid StopScheduler -> DP.send pid SchedulerTerminated))
                  `catch` (\e -> do
                     DP.liftIO $ do
                       putStrLn $ "scheduler died: " ++ show e
                       throwM (e :: SomeException)
                   )
               void $ DP.liftIO $ readMVar schedulerVar
               return (True, sortedLNodes)
  where
    go :: SchedulerState -> Process a
    go st@(SchedulerState _ alive procs msgs nsMsgs _ _ _ expired timeouts _ _)
        -- Enter this equation if all processes are waiting for a transition
      | Set.size alive == Map.size procs && not (Set.null alive) = do
        -- Determine if no process has a message and there are no messages to
        -- put in a mailbox.
        let systemStuck =
                 Map.null (Map.filter id procs)
              && Map.null msgs
              && Map.null nsMsgs
              && Set.null expired
        -- Complain if the system is stuck and there are no timeouts we could
        -- wait to observe some activity.
        when (systemStuck && Map.null timeouts) $
          error $ "startScheduler: All processes (" ++ show (Set.size alive) ++
                  ") are blocked."
        -- pick next transition
        let (r , st') = pickNextTransition $
                          if systemStuck then jumpToNextTimeout st else st
        schedulerTrace $ "scheduler: " ++ show (stateSeed st, r)
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
        [ DP.match $ \m ->
        (schedulerTrace $ "scheduler: " ++ show (stateSeed st, m)) >> case m of
        GetTime pid -> DP.send pid clock >> go st
        -- a process is sending a message
        Send source pid msg ->
          handleSend st (source, pid, msg) >>= go . fst
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
            -- Remove the old timeout if the process had one.
            let timeouts' = maybe timeouts (\t -> multimapDelete t pid timeouts)
                          $ Map.lookup pid revTimeouts
            go st { stateProcs = Map.insert pid False procs
                  , stateTimeouts =
                      Map.insertWith union (clock + ts) [pid] timeouts'
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
        -- the process @who@ is monitoring @whomPid@
        Monitor who whom@(DP.ProcessIdentifier whomPid) isLink -> do
            let ref = DP.MonitorRef (DP.ProcessIdentifier who) mcounter
            DP.send who ref
            let st' = st { stateMonitors =
                             Map.insertWith (++) whom [(ref, isLink)] monitors
                         , stateMonitorCounter = mcounter + 1
                         }
                f = Map.lookup (DP.processNodeId who, DP.processNodeId whomPid)
                               (stateFailures st')
                (v, seed') = randomR (0.0, 1.0) $ stateSeed st'
                st'' = maybe st' (const $ st' {stateSeed = seed'}) f
            case f of
              Just p | v <= p -> do
                notifyNodeMonitors st''
                                   (DP.processNodeId who)
                                   (DP.processNodeId whomPid)
                                   DP.DiedDisconnect
                  >>= go
              _ ->
                if Set.member whomPid alive then
                  go st''
                else
                  notifyProcessMonitors st'' (== DP.processNodeId who)
                                        (DP.processNodeId whomPid)
                                        whomPid
                                        DP.DiedUnknownId
                    >>= go

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
            let nothingOn p x = if p x then Nothing else Just x
                isTheLink (DP.MonitorRef (DP.ProcessIdentifier who') _, True) =
                  who == who'
                isTheLink _ = False
            DP.send who UnlinkAck
            go st { -- Remove the corresponding monitor.
                    stateMonitors = Map.update
                      (nothingOn null . filter (not . isTheLink)) whom monitors
                    -- Remove any pending LinkExceptionMsg.
                  , stateMessages =
                      let whomNid = case whom of
                            DP.ProcessIdentifier whomPid ->
                              DP.processNodeId whomPid
                            DP.NodeIdentifier nid        -> nid
                            _                            ->
                              error "d-p-scheduler: Unlink unexpected whom"
                          isTheLinkMsg (LinkExceptionMsg source _ _)
                                         = source == whom
                          isTheLinkMsg _ = False
                       in Map.update
                            ( nothingOn Map.null
                            . Map.update
                                (nothingOn null . filter (not . isTheLinkMsg))
                                (DP.nullProcessId $ DP.processNodeId who)
                            . Map.update
                                (nothingOn null . filter (not . isTheLinkMsg))
                                (DP.nullProcessId whomNid)
                            )
                            who
                            (stateMessages st)
                  }
        WhereIs pid nid label -> do
            let f = Map.lookup (DP.processNodeId pid, nid) $ stateFailures st
                (v, seed') = randomR (0.0, 1.0) $ stateSeed st
                st' = maybe st (const $ st {stateSeed = seed'}) f
            case f of
              -- Flip a coin to decide if we should drop the @WhereIs@ message.
              Just p | v <= p -> do
                notifyNodeMonitors st' (DP.processNodeId pid)
                                   nid DP.DiedDisconnect
                  >>= go
              _ -> do
                DP.whereisRemoteAsync nid label
                rep <- DP.receiveWait
                  [ DP.matchIf (\(DP.WhereIsReply lbl _) -> lbl == label)
                               return
                  ]
                handleSend st' ( DP.nullProcessId nid
                               , pid
                               , MailboxMsg pid $ DP.createUnencodedMessage rep
                               )
                  >>= go . fst
        AddFailures fls ->
            go st { stateFailures = foldr (uncurry Map.insert) failures fls }
        RemoveFailures fls ->
            go st { stateFailures = foldr Map.delete failures fls }

        -- A process has terminated. Notify monitors and remove all state
        -- associated to the dead process.
        , DP.match $ \pmn@(DP.ProcessMonitorNotification _ pid reason) -> do
            schedulerTrace $ "scheduler: " ++ show (stateSeed st, pmn)
            st' <- notifyProcessMonitors st (const True)
                                         (DP.processNodeId pid)
                                         pid reason
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

    -- Queues a message for a given process in the appropriate queue.
    --
    -- If failures are in effect, the message might be dropped without
    -- queuing it. If the message is dropped, notification messages are
    -- produced for the interested monitors.
    --
    -- Returns 'True' iff the message was sent.
    handleSend :: SchedulerState
               -> (ProcessId, ProcessId, SystemMsg)
                  -- ^ (sender, destination, message)
               -> Process (SchedulerState, Bool)
    handleSend st (source, pid, msg) = do
      let mp = Map.lookup (DP.processNodeId source, DP.processNodeId pid)
                          (stateFailures st)
      case mp of
        -- drop message
        Just p | (v, seed') <- randomR (0.0, 1.0) (stateSeed st), v <= p -> do
          (,False) <$> notifyNodeMonitors (st { stateSeed = seed' })
                         (DP.processNodeId source)
                         (DP.processNodeId pid)
                         DP.DiedDisconnect
        -- queue the message
        _ | Set.member pid (stateAlive st) ->
          return
             (st
               { stateMessages =
                   Map.insertWith
                     (const $ Map.insertWith (flip (++)) source [msg])
                     pid (Map.singleton source [msg]) (stateMessages st)
               }
             , True
             )
        -- If the target is not known to the scheduler we assume it doesn't
        -- matter in which order messages are delivered to it.
        _ -> do
          forwardSystemMsg msg
          return (st, True)

    -- Like 'handleSend' but messages are directed to process with a label and
    -- a 'NodeId'.
    handleNSend :: SchedulerState
                -> (ProcessId, NodeId, String, DP.Message)
                -> Process SchedulerState
    handleNSend st (source, nid, label, msg) = do
      case Map.lookup (DP.processNodeId source, nid) (stateFailures st) of
        -- drop message
        Just p | (v, seed') <- randomR (0.0, 1.0) (stateSeed st), v <= p -> do
          notifyNodeMonitors (st { stateSeed = seed' })
                             (DP.processNodeId source)
                             nid
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

    -- Given a process failure, produces notification messages and sends
    -- them to the interested monitors.
    --
    -- The identifier of the node where the failure is detected is important to
    -- determine whether the node has the conectivity to reach the monitors.
    --
    -- This function takes a predicate to indicate which monitors should be
    -- notified:
    -- * When a process dies, all monitors in all reachable nodes should be
    --   notified.
    -- * When a process A tries to monitor an unknown process, only the monitors
    --   in the node of A are notified.
    --
    -- Notifications might be dropped due to connection failures. In this case
    -- new notifications would be produced.
    --
    notifyProcessMonitors :: SchedulerState
      -> (NodeId -> Bool)  -- ^ Whether monitors residing on a particular node
                           -- should be notified.
      -> NodeId -- ^ Id of the node where the notification originated. For
                -- disconnected monitored processes, this is the node detecting
                -- the disconnection. For dead processes, this is the node where
                -- the dead process resided.
      -> ProcessId -- ^ Id of the process which was monitored.
      -> DP.DiedReason
      -> Process SchedulerState
    notifyProcessMonitors st shouldNotify srcNid pid
                          reason =
      case Map.lookup (DP.ProcessIdentifier pid) (stateMonitors st) of
        Just mons -> do
          let -- Determine which monitors to notify. We will keep the others.
              (shouldMons, otherMons) =
                partition (\(DP.MonitorRef src _, _) ->
                             shouldNotify $ DP.nodeOf src
                          )
                          mons
              -- Determine the kind of notification to send to each monitor.
              -- These are either a link exception or a monitor notification
              -- message.
              sends = flip map shouldMons $
                \(ref@(DP.MonitorRef (DP.ProcessIdentifier p) _)
                 , isLink
                 ) ->
                  if isLink
                  then ( DP.nullProcessId srcNid
                       , p
                       , LinkExceptionMsg (DP.ProcessIdentifier pid) p reason
                       )
                  else ( DP.nullProcessId srcNid
                       , p
                       , MailboxMsg p $
                           DP.createUnencodedMessage $
                           DP.ProcessMonitorNotification ref pid reason
                       )
          -- Remove the notified monitors from the state.
          let st' = st { stateMonitors =
                           if null otherMons then
                             Map.delete (DP.ProcessIdentifier pid)
                                        (stateMonitors st)
                           else Map.insert (DP.ProcessIdentifier pid)
                                           otherMons
                                           (stateMonitors st)
                       }
          -- Add back the monitors if the notifications were not sent.
          -- The destination node may not be reachable.
          (\f -> fix f st' (zip sends shouldMons) []) $ \loop st2 xs0 acc ->
            case xs0 of
              []          -> return st2
                { stateMonitors =
                    if null acc then stateMonitors st2
                      else Map.insertWith (++) (DP.ProcessIdentifier pid) acc
                                               (stateMonitors st)
                }
              (x, m) : xs -> do (st3, sent) <- handleSend st2 x
                                loop st3 xs (if sent then acc else m : acc)
        Nothing ->
          return st

    -- Notifies node monitors of a node disconnection. Notifications are also
    -- produced for monitors interested on any process on the disconnected node.
    --
    -- Only the monitors in the node detecting the failure are notified.
    --
    notifyNodeMonitors :: SchedulerState
      -> NodeId -- ^ Identifier of the node detecting the disconnection.
      -> NodeId -- ^ Id of the node which was disconnected.
      -> DP.DiedReason
      -> Process SchedulerState
    notifyNodeMonitors st srcNid nid reason = do
      let impliesDeathOf (DP.NodeIdentifier nid') = nid == nid'
          impliesDeathOf (DP.ProcessIdentifier p) = nid == DP.processNodeId p
          impliesDeathOf _                        = False
          -- Determine which monitors are interested in the node failure.
          (mons, remainingMons) =
            Map.partitionWithKey (const . impliesDeathOf) (stateMonitors st)
          -- Determine which monitors should be notified.
          (shouldMons, otherMons) =
            let splitMons = partition (\(DP.MonitorRef dpId _, _) ->
                                         srcNid == DP.nodeOf dpId
                                      )
                              <$> mons
             in (fst <$> splitMons, snd <$> splitMons)
          -- Remove notified monitors.
          st' = st { stateMonitors =
                       Map.union (Map.filter (not . null) otherMons)
                                 remainingMons
                   }
          -- Determine the kind of notification to send to each monitor.
          -- These are either a node or a process monitor notification.
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

      -- In the node failure case, notifications travel locally only. Thus,
      -- unlike in the 'notifyprocessMonitor' case, we don't need to worry about
      -- unreachable monitors.
      foldM (\a b -> fst <$> handleSend a b) st'
        [ mkMsg k x | (k, xs) <- Map.toList shouldMons, x <- xs ]

    multimapDelete :: (Ord k, Eq a) => k -> a -> Map k [a] -> Map k [a]
    multimapDelete k x = flip Map.update k $ \xs ->
      case delete x xs of
        []  -> Nothing
        xs' -> Just xs'

    -- Tells if the process is waiting for messages without anything useful to
    -- do in the meantime.
    isBlocked pid procs =
      maybe (error $ "startScheduler.isBlocked: missing pid " ++ show pid) not
        $ Map.lookup pid procs

    -- Tells if the 'SystemMsg' is an exception.
    isExceptionMsg (LinkExceptionMsg _ _ _) = True
    isExceptionMsg (ExitMsg _ _ _) = True
    isExceptionMsg (KillMsg _ _ _) = True
    isExceptionMsg _ = False

    -- | @chooseUniformly [(n_0, f_0),...,(n_k, f_k)] g@
    --
    -- The input must be sorted in ascending order of the @n_i@s.
    --
    -- Each pair @(n_i, f_i)@ is associated to a range @[s i .. s (i+1) - 1]@
    -- associated to function @f_i@ where
    --
    -- > s 0 = 0
    -- > s i = sum [n_0 .. n_(i-1)]
    --
    -- This function chooses a value from the range @(0, sum n_i)@ and then
    -- applies the function @f_i@ corresponding to the range of the selected
    -- value.
    chooseUniformly :: (Num i, Ord i, Random i, RandomGen g)
                    => g -> [(i, i -> g -> a)] -> a
    chooseUniformly seed ranges =
      let (i, seed') = randomR (0, sum (map fst ranges) - 1) seed
          pick xs n = case xs of
            [] -> error "Scheduler.chooseUniformly: used with empty list."
            (k, f) : xs' | n < k     -> f n seed'
                         | otherwise -> pick xs' (n - k)
       in pick ranges i

    -- Picks the next transition and advances the virtual clock.
    --
    -- This function uses 'chooseUniformly' to select among the possible
    -- transitions that the system can do.
    pickNextTransition :: SchedulerState
                       -> ( Transition
                          , SchedulerState
                          )
    pickNextTransition st@(SchedulerState seed _ procs msgs nsMsgs _ _ _
                                          expired _ _ _
                          ) =
      -- We tick the clock on every transition.
      second tickClock $ chooseUniformly seed $
        [ -- Continue running one of the non-blocked processes.
          let has_a_message = Map.filter id procs
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
        [ -- Send a message from the front of one of the message queues.
          (Map.size pidMsgs, \i seed' ->
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
        [ -- Send a message from the front of one of the message queues for
          -- processes addressed by label and 'NodeId'.
          (Map.size nidlMsgs, \i seed' ->
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
        [ -- Continue running one of the processes with an expired timeout.
          (Set.size expired, \i seed' ->
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

    -- Advances the virtual clock.
    --
    -- This increases the clock and moves any newly expired timeouts from
    -- 'stateTimeouts' to 'stateExpiredTimeouts'.
    tickClock :: SchedulerState -> SchedulerState
    tickClock st =
      let -- New value of the clock
          clock' = stateClock st + clockDelta
          -- Recently expired timeouts
          (newExpired, mtpid, trest) =
            Map.splitLookup (clock' + 1) (stateTimeouts st)
          -- New expired set of timeouts
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
           -- Terminate 'withScheduler' if the scheduler dies.
           DP.link spid
           self <- DP.getSelfPid
           -- Announce the running process to the scheduler.
           DP.send spid $ SpawnedProcess self self
           SpawnAck <- DP.expect
           Continue <- DP.expect
           -- Run the process closure.
           p ns
           DP.unlink spid
          `finally` DP.liftIO stopScheduler
        DP.liftIO $ putMVar mv ()
       `catch` \e -> DP.liftIO $ do
         throwTo tid (e :: SomeException)
         throwM e
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
      maybe (throwM AbsentScheduler) return

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

send :: Serializable a => ProcessId -> a -> Process ()
send pid msg = do
  self <- DP.getSelfPid
  sendS $ Send self pid $ MailboxMsg
    pid
    (DP.createUnencodedMessage msg)

usend :: Serializable a => ProcessId -> a -> Process ()
usend = send

say :: String -> Process ()
say string = do
    self <- DP.getSelfPid
    schedulerTrace "say"
    sendS $ GetTime self
    now <- DP.expect
    -- Treat ticks as milliseconds.
    let utc = addUTCTime (toEnum now * 1000 * 1000) (UTCTime (toEnum 0) 0)
    nsend "logger" (DP.SayMessage utc self string)

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

uforward :: DP.Message -> ProcessId -> Process ()
uforward msg pid = do
    self <- DP.getSelfPid
    sendS $ Send self pid $ MailboxMsg pid msg

-- | Sends a message to the scheduler.
sendS :: Serializable a => a -> Process ()
sendS a = DP.liftIO getScheduler >>= flip DP.send a . processId

receiveWait :: [ Match b ] -> Process b
receiveWait ms =
    ifSchedulerIsEnabled
      (do Just b <- receiveTimeoutM Nothing ms
          return b
      )
      (DP.receiveWait $ map (flip unMatch Nothing) ms)

receiveTimeout :: Int -> [ Match b ] -> Process (Maybe b)
receiveTimeout us =
    ifSchedulerIsEnabled
      (receiveTimeoutM (Just us))
      (DP.receiveTimeout us . map (flip unMatch Nothing))

-- | Waits for a message with a timeout.
--
-- Waits indefinitely if given @Nothing@.
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
          _ -> do
            DP.say $ "receiveTimeoutM: unexpected " ++ show command
            error $ "receiveTimeoutM: unexpected " ++ show command

expect :: Serializable a => Process a
expect = receiveWait [ match return ]

receiveChan :: Serializable a => ReceivePort a -> Process a
receiveChan rPort = receiveWait [ matchChan rPort return ]

-- | Opaque type used by 'receiveWait'.
newtype Match a = Match
  { -- | Matches a message intended for the caller if given 'Nothing'.
    --
    -- When given @Just ref@, it rejects all messages, but writes 'True'
    -- to @ref@ for those messages that would have been matched if given
    -- 'Nothing'.
    --
    -- This mechanism allows a process to query if there is some message to
    -- process without taking it from the mailbox or the channel.
    --
    -- This information allows the scheduler to know which processes are able to
    -- make progress.
    unMatch :: Maybe (IORef Bool) -> DP.Match a
  }

instance Functor Match where
  fmap f (Match g) = Match $ fmap f . g

match :: Serializable a => (a -> Process b) -> Match b
match = matchIf (const True)

matchIf :: Serializable a => (a -> Bool) -> (a -> Process b) -> Match b
matchIf p h = Match $ \mr -> case mr of
    Nothing -> DP.matchIf p h
    Just r  -> DP.matchIf (\a -> p a && seq (unsafeWriteIORef r True a) False) h

unsafeWriteIORef :: IORef a -> a -> b -> b
unsafeWriteIORef r a b = unsafePerformIO $ do
    writeIORef r a
    return b

matchAny :: (DP.Message -> Process b) -> Match b
matchAny h = Match $ \mr -> case mr of
    Nothing -> DP.matchAny h
    Just r  -> fmap undefined $
      DP.matchMessageIf (\a -> seq (unsafeWriteIORef r True a) False) return

matchMessageIf :: (DP.Message -> Bool) -> (DP.Message -> Process DP.Message)
               -> Match DP.Message
matchMessageIf p h = Match $ \mr -> case mr of
  Nothing -> DP.matchMessageIf p h
  Just r ->
    DP.matchMessageIf (\a -> p a && seq (unsafeWriteIORef r True a) False) h

matchSTM :: STM a -> (a -> Process b) -> Match b
matchSTM sa h = Match $ \mr -> case mr of
                  Nothing -> DP.matchSTM sa h
                  Just r  -> DP.matchSTM (sa >> setAndRetry r) h
  where
    setAndRetry r = unsafePerformIO (writeIORef r True) `seq` retry

matchChan :: ReceivePort a -> (a -> Process b) -> Match b
matchChan = matchSTM . DP.receiveSTM

monitor :: ProcessId -> Process DP.MonitorRef
monitor pid = do self <- DP.getSelfPid
                 sendS $ Monitor self (DP.ProcessIdentifier pid) False
                 DP.expect

unmonitor :: DP.MonitorRef -> Process ()
unmonitor = sendS . Unmonitor

monitorNode :: NodeId -> Process DP.MonitorRef
monitorNode nid = do
    self <- DP.getSelfPid
    sendS $ Monitor self (DP.NodeIdentifier nid) False
    DP.expect

link :: ProcessId -> Process ()
link pid = do self <- DP.getSelfPid
              sendS $ Monitor self (DP.ProcessIdentifier pid) True
              _ <- DP.expect :: Process DP.MonitorRef
              return ()

unlink :: ProcessId -> Process ()
unlink pid = do self <- DP.getSelfPid
                sendS $ Unlink self $ DP.ProcessIdentifier pid
                UnlinkAck <- DP.expect
                return ()

linkNode :: NodeId -> Process ()
linkNode nid = do
    self <- DP.getSelfPid
    sendS $ Monitor self (DP.NodeIdentifier nid) True
    _ <- DP.expect :: Process DP.MonitorRef
    return ()

exit :: Serializable a => ProcessId -> a -> Process ()
exit pid reason = do
  self <- DP.getSelfPid
  sendS $ Send self pid $ ExitMsg self pid $ DP.createMessage reason

kill :: ProcessId -> String -> Process ()
kill pid reason = do
  self <- DP.getSelfPid
  sendS $ Send self pid $ KillMsg self pid reason

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

spawnMonitor :: NodeId -> Closure (Process ())
             -> Process (ProcessId, DP.MonitorRef)
spawnMonitor nid cp = do
    pid <- spawn nid cp
    mref <- monitor pid
    return (pid, mref)

spawn :: NodeId -> Closure (Process ()) -> Process ProcessId
spawn nid cp = do
    ref <- spawnAsync nid cp
    receiveWait [ matchIf (\(DP.DidSpawn ref' _) -> ref' == ref) $
                           \(DP.DidSpawn _ pid) -> return pid
                ]

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

callLocal :: Process a -> Process a
callLocal proc = mask $ \release -> do
    mv    <- DP.liftIO newEmptyMVar :: Process (MVar (Either SomeException a))
    -- This is callLocal from d-p, with the addition of a c-h channel to signal
    -- to the scheduler that the mvar is filled.
    (sp, rp) <- DP.newChan
    (spInit, rpInit) <- DP.newChan -- TODO: Remove when spawnLocal inherits the
                                   -- masking state.
    child <- spawnLocal $ mask_ $ do
               sendChan spInit ()
               r <- try (release proc)
               sendChan sp ()
               DP.liftIO $ putMVar mv r
    rs <- (do receiveChan rp
              DP.liftIO (takeMVar mv)
            `catch` \e ->
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
                throwM (e :: SomeException)
          )
    either throwM return rs

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

whereis :: String -> Process (Maybe ProcessId)
whereis label = yield >> DP.whereis label

register :: String -> ProcessId -> Process ()
register label p = yield >> DP.register label p

reregister :: String -> ProcessId -> Process ()
reregister label p = yield >> DP.reregister label p

whereisRemoteAsync :: NodeId -> String -> Process ()
whereisRemoteAsync n label = do
    yield
    self <- DP.getSelfPid
    sendS (WhereIs self n label)

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

receiveWaitT :: MonadProcess m => [MatchT m b] -> m b
receiveWaitT = ifSchedulerIsEnabled
                 receiveWaitTSched
                 (DPT.receiveWaitT . map (flip unMatchT Nothing))
  where
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
