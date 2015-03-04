-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE PackageImports #-}

module Control.Distributed.Process.Scheduler.Internal
  (
  -- * Initialization
    schedulerIsEnabled
  , startScheduler
  , stopScheduler
  , withScheduler
  , __remoteTable
  , spawnWrapClosure__tdict
  -- * distributed-process replacements
  , Match
  , send
  , usend
  , nsend
  , nsendRemote
  , sendChan
  , match
  , matchIf
  , matchChan
  , matchSTM
  , expect
  , receiveChan
  , receiveWait
  , spawnLocal
  , spawn
  , spawnAsync
  , whereisRemoteAsync
  , registerRemoteAsync
  -- * distributed-process-trans replacements
  , MatchT
  , matchT
  , matchIfT
  , receiveWaitT
  ) where

import Control.Applicative ( (<$>) )
import Control.Concurrent.STM
import "distributed-process" Control.Distributed.Process
    ( Closure, NodeId, Process, ProcessId, ReceivePort, SendPort )
import qualified "distributed-process" Control.Distributed.Process as DP
import qualified "distributed-process" Control.Distributed.Process.Internal.Types as DP
import qualified "distributed-process" Control.Distributed.Process.Internal.Messaging as DP
import Control.Distributed.Process.Closure ( remotable, mkClosure )
import Control.Distributed.Process.Serializable ( Serializable )
import "distributed-process-trans" Control.Distributed.Process.Trans ( MonadProcess(..) )
import qualified "distributed-process-trans" Control.Distributed.Process.Trans as DPT

import Control.Concurrent.MVar
    ( newMVar, newEmptyMVar, takeMVar, putMVar, MVar
    , readMVar, modifyMVar_
    )
import Control.Exception ( SomeException, throwIO )
import Control.Monad ( void, when, liftM2 )
import Control.Monad.Reader ( ask )
import Data.Binary ( Binary(..) )
import Data.IORef ( newIORef, writeIORef, readIORef, IORef )
import Data.Map ( Map )
import qualified Data.Map as Map
import Data.Set ( Set )
import qualified Data.Set as Set
import Data.Typeable ( Typeable )
import GHC.Generics ( Generic )
import System.Posix.Env ( getEnv )
import System.IO.Unsafe ( unsafePerformIO )
import System.Random ( StdGen, randomR, mkStdGen )


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
schedulerVar :: MVar ProcessId
schedulerVar = unsafePerformIO $ newEmptyMVar

-- | Preprocessed process or channel message that can be delivered via
-- 'DP.sendPayload'.
data AddressedMsg = AddressedMsg DP.Identifier DP.Message
  deriving Typeable

instance Binary AddressedMsg where
  put (AddressedMsg ident msg) =
    put ident >> put (DP.messageToPayload msg)
  get = liftM2 AddressedMsg get (fmap DP.payloadToMessage get)

-- | Messages that the tested application sends to the scheduler.
data SchedulerMsg
    = Send ProcessId ProcessId AddressedMsg
      -- ^ @Send source dest message@: send the @message@ from @source@ to
      -- @dest@.
    | NSend ProcessId NodeId String DP.Message
      -- ^ @NSend source destNode label message@: send the @message@ from
      -- @source@ to @label@ in @destNode@.
    | Blocking ProcessId       -- ^ @Blocking pid@: process @pid@ has no
                               -- messages to process and is blocked.
    | HasMessage ProcessId     -- ^ @HasMessage pid@: process @pid@ is ready
                               -- to pick a message from its mailbox (and there
                               -- is at least one elegible message).
    | CreatedNewProcess ProcessId  ProcessId
                                  -- ^ @CreatedNewProcess parent child@: a new
                                  -- process will be created by @parent@.
    | ProcessTerminated ProcessId -- ^ A process with the given pid has
                                  -- terminated.
  deriving (Generic, Typeable)

-- | Messages that the scheduler sends to the tested application.
data SchedulerResponse
    = Receive      -- ^ Pick a message from your mailbox.
    | TestReceive  -- ^ Look if there is some elegible message in your mailbox.
    | OkNewProcess -- ^ Please go on and create the child process.
  deriving (Generic, Typeable)

-- | Transitions that the scheduler can choose to perform when all
-- processes block.
data TransitionRequest
    = PutMsg ProcessId AddressedMsg
                            -- ^ Put this message in the mailbox of the target.
    | PutNSendMsg NodeId String DP.Message
                    -- ^ Put this nsend'ed message in the mailbox of the target.
    | ReceiveMsg ProcessId  -- ^ Have a process pick a message from its mailbox.

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

type ProcessMessages = Map ProcessId (Map ProcessId [AddressedMsg])
type NSendMessages = Map (NodeId, String) (Map ProcessId [DP.Message])

-- | Starts the scheduler assuming the given initial amount of processes and
-- a seed to generate a sequence of random values.
startScheduler :: [ProcessId] -- ^ initial processes
               -> Int -- ^ seed
               -> Process ()
startScheduler initialProcs seed0 = do
    modifyMVarP schedulerLock
      $ \initialized -> do
        if initialized
         then error "startScheduler: scheduler already started."
         else do
           self <- DP.getSelfPid
           spid <- DP.spawnLocal $
                     ((go (mkStdGen seed0) (Set.fromList initialProcs)
                          Map.empty Map.empty Map.empty
                       `DP.finally` do
                          DP.liftIO $ modifyMVar_ schedulerLock $
                              const $ return False
                      )
                      `DP.catchExit`
                        (\pid StopScheduler -> DP.send pid SchedulerTerminated))
                      `DP.catch` (\e -> do
                         DP.exit self $ "scheduler died: " ++ show e
                         DP.liftIO $ do
                           putStrLn $ "scheduler died: " ++ show e
                           throwIO (e :: SomeException)
                       )
           DP.liftIO $ putMVar schedulerVar spid
           return (True,())
  where
    go :: StdGen               -- ^ random number generator
       -> Set ProcessId        -- ^ set of tested processes
       -> Map ProcessId Bool   -- ^ state of processes (blocked | has_a_message)
       -> ProcessMessages      -- ^ messages targeted to each process
       -> NSendMessages        -- ^ messages targeted with a label
       -> Process ()
    go seed alive procs msgs nsMsgs
        -- Enter this equation if all processes are waiting for a transition
      | Set.size alive == Map.size procs = do
        -- complain if no process has a message and there are no messages to
        -- put in a mailbox
        when (Map.null (Map.filter id procs)
              && Map.null msgs
              && Map.null nsMsgs) $
          error $ "startScheduler: All processes (" ++ show (Set.size alive) ++
                  ") are blocked."
        -- pick next transition
        let (r , seed', procs', msgs', nsMsgs') =
               pickNextTransition seed procs msgs nsMsgs
        case r of
          PutMsg pid msg -> do
             forward msg
             -- if the process was blocked let's ask it to check again if it
             -- has a message.
             procs'' <- if isBlocked pid procs
               then do DP.send pid TestReceive
                       return $ Map.delete pid procs'
               else return procs'
             go seed' alive procs'' msgs' nsMsgs'
          PutNSendMsg nid label msg -> do
             DP.whereisRemoteAsync nid label
             DP.WhereIsReply _ mpid <- DP.expect
             case mpid of
               Nothing -> do
                 go seed' alive procs' msgs' nsMsgs'
               Just pid -> do
                 forward $ AddressedMsg (DP.ProcessIdentifier pid) msg
                 -- if the process was blocked let's ask it to check again if it
                 -- has a message.
                 procs'' <- if isBlocked pid procs
                   then do DP.send pid TestReceive
                           return $ Map.delete pid procs'
                   else return procs'
                 go seed' alive procs'' msgs' nsMsgs'
          ReceiveMsg pid -> do
             DP.send pid Receive
             go seed' alive procs' msgs' nsMsgs'

    -- enter the next equation if some process is still active
    go seed alive procs msgs nsMsgs = do
      m <- DP.expect
      case m of
        -- a process is sending a message
        Send source pid msg -> do
            go seed alive procs
              (if Set.member pid alive
                 then Map.insertWith
                           (const $ Map.insertWith (flip (++)) source [msg])
                           pid (Map.singleton source [msg]) msgs
                 else msgs
              )
              nsMsgs
        NSend source nid label msg -> do
            go seed alive procs msgs $
              Map.insertWith (const $ Map.insertWith (flip (++)) source [msg])
                             (nid, label)
                             (Map.singleton source [msg])
                             nsMsgs
        -- a process has a message and is ready to process it
        HasMessage pid ->
            go seed alive (Map.insert pid True procs) msgs nsMsgs
        -- a process has no messages and will block
        Blocking pid ->
            go seed alive (Map.insert pid False procs) msgs nsMsgs
        -- a new process will be created
        CreatedNewProcess parent child -> do
            DP.send parent OkNewProcess
            go seed (Set.insert child alive) procs msgs nsMsgs
        -- a process has terminated
        ProcessTerminated pid ->
            go seed (Set.delete pid alive)
                    (Map.delete pid procs)
                    (Map.delete pid msgs)
                    nsMsgs

    -- is the given process waiting for a new message?
    isBlocked pid procs =
      maybe (error "startScheduler.isBlocked: missing pid") not
        $ Map.lookup pid procs

    -- Picks the next transition.
    pickNextTransition :: StdGen
                       -> Map ProcessId Bool
                       -> ProcessMessages
                       -> NSendMessages
                       -> ( TransitionRequest
                          , StdGen
                          , Map ProcessId Bool
                          , ProcessMessages
                          , NSendMessages
                          )
    pickNextTransition seed procs msgs nsMsgs =
      let has_a_message = Map.filter id procs
          msgsSizes@(msgsSize:_) =
              Map.foldl' (\ss@(!s:_) ms -> s + Map.size ms : ss) [0] msgs
          nsMsgsSizes@(nsMsgsSize:_) =
              Map.foldl' (\ss@(!s:_) ms -> s + Map.size ms : ss) [0] nsMsgs
          (i,seed') = randomR (0, Map.size has_a_message +
                                  msgsSize +
                                  nsMsgsSize - 1
                              )
                              seed
       in if i < Map.size has_a_message
        then let pid = Map.keys has_a_message !! i
              in ( ReceiveMsg pid
                 , seed'
                 , Map.delete pid procs -- the process is active again
                 , msgs
                 , nsMsgs
                 )
        else if i < Map.size has_a_message + msgsSize
        then let -- index in the range of messages to send
                 i' = i - Map.size has_a_message
                 -- the start of the range of senders of messages to the chosen
                 -- process
                 i'' : rest = dropWhile (i'<) msgsSizes
                 -- the chosen process
                 (pid, pidMsgs) = Map.toList msgs !! length rest
                 -- the chosen sender
                 (sender, m : ms) = Map.toList pidMsgs !! (i' - i'')
              in ( PutMsg pid m
                 , seed'
                 , procs
                 , if null ms -- make sure to delete all empty containers
                    then if 1 == Map.size pidMsgs then Map.delete pid msgs
                          else Map.adjust (Map.delete sender) pid msgs
                    else Map.adjust (Map.adjust tail sender) pid msgs
                 , nsMsgs
                 )
        else let -- index in the range of messages to send
                 i' = i - Map.size has_a_message - msgsSize
                 -- the start of the range of senders of messages to the chosen
                 -- process
                 i'' : rest = dropWhile (i'<) nsMsgsSizes
                 -- the chosen process
                 ((nid, label), nidlMsgs) = Map.toList nsMsgs !! length rest
                 -- the chosen sender
                 (sender, m : ms) = Map.toList nidlMsgs !! (i' - i'')
              in ( PutNSendMsg nid label m
                 , seed'
                 , procs
                 , msgs
                 , if null ms -- make sure to delete all empty containers
                    then if 1 == Map.size nidlMsgs
                         then Map.delete (nid, label) nsMsgs
                         else Map.adjust (Map.delete sender) (nid, label) nsMsgs
                    else Map.adjust (Map.adjust tail sender) (nid, label) nsMsgs
                 )

    forward (AddressedMsg rid msg) = do
        self <- ask
        let n = DP.processNode self
            nid = DP.localNodeId n
        case rid of
          DP.ProcessIdentifier pid -> DP.forward msg pid
          DP.SendPortIdentifier spId ->
            if DP.processNodeId (DP.sendPortProcessId spId) == nid then
              -- The local path is more than an optimization.
              -- It is needed to ensure that forwarded messages and
              -- those sent with DP.send arrive in order in the local case.
              DP.sendCtrlMsg Nothing (DP.LocalPortSend spId msg)
            else do
              -- TODO: There used to be an implementation which used
              -- DP.sendPayload to send messages through channels.
              -- Unfortunately, messages sent through channels and control
              -- messages sent by the scheduler to the process waiting on the
              -- receiving end can arrive in any order.
              DP.say "startScheduler.forward: remote channels are not supported"
              error "startScheduler.forward: remote channels are not supported"
          _ -> do DP.say $ "startScheduler.forward: unhandled case " ++ show rid
                  error $ "startScheduler.forward: unhandled case " ++ show rid


-- | Lift 'Control.Concurrent.modifyMVar'
modifyMVarP :: MVar a -> (a -> Process (a,b)) -> Process b
modifyMVarP mv thing = DP.mask $ \restore -> do
    a <- DP.liftIO $ takeMVar mv
    (a',b) <- (restore (thing a) `DP.onException` DP.liftIO (putMVar mv a))
    DP.liftIO $ putMVar mv a'
    return b

-- | Stops the scheduler.
stopScheduler :: Process ()
stopScheduler =
    do spid <- DP.liftIO (takeMVar schedulerVar)
       running <- modifyMVarP schedulerLock $ \running -> do
         when running $ DP.exit spid StopScheduler
         return (False,running)
       when running $ do
         SchedulerTerminated <- DP.expect
         return ()

-- | Wraps a Process computation with calls to 'startScheduler' and
-- 'stopScheduler'.
withScheduler :: [ProcessId]   -- ^ initial processes
              -> Int       -- ^ seed
              -> Process a -- ^ computation to wrap
              -> Process a
withScheduler ps s p = DP.getSelfPid >>= \self ->
  DP.bracket_ (startScheduler (self:ps) s) stopScheduler p

getScheduler :: Process ProcessId
getScheduler = DP.liftIO (readMVar schedulerVar)

-- | Sends a transition request of type (1) to the scheduler.
-- The scheduler will take care of placing the message in the mailbox of the
-- target process. Returns immediately.
send :: Serializable a => ProcessId -> a -> Process ()
send pid msg = do
  self <- DP.getSelfPid
  sendS $ Send self pid $ AddressedMsg
    (DP.ProcessIdentifier pid)
    (DP.createUnencodedMessage msg)

usend :: Serializable a => ProcessId -> a -> Process ()
usend = send

nsendRemote :: Serializable a => NodeId -> String -> a -> Process ()
nsendRemote nid label msg = do
    self <- DP.getSelfPid
    sendS $ NSend self nid label $ DP.createMessage msg

nsend :: Serializable a => String -> a -> Process ()
nsend label a = DP.whereis label >>= maybe (return ()) (flip send a)

sendChan :: Serializable a => SendPort a -> a -> Process ()
sendChan sendPort msg = do
    self <- DP.getSelfPid
    let spId = DP.sendPortId sendPort
    sendS $ Send self (DP.sendPortProcessId spId) $ AddressedMsg
      (DP.SendPortIdentifier spId)
      (DP.createUnencodedMessage msg)

-- | Sends a message to the scheduler.
sendS :: Serializable a => a -> Process ()
sendS a = getScheduler >>= flip DP.send a

-- The receiveWait and receiveWaitT functions are marked NOINLINE,
-- because this way the "if" statement only has to be evaluated once
-- and not at every call site.  After the first evaluation, these
-- top-level functions are simply a jump to the appropriate function.

{-# NOINLINE receiveWait #-}
receiveWait :: [ Match b ] -> Process b
receiveWait = if schedulerIsEnabled
              then receiveWaitSched
              else DP.receiveWait . map (flip unMatch Nothing)
  where
    -- | Submits a transition request of type (2) to the scheduler.
    -- Blocks until the transition is allowed and any of the match clauses
    -- is performed.
    receiveWaitSched ms = do
        r <- DP.liftIO $ newIORef False
        go r $ map (flip unMatch $ Just r) ms
      where
        go r ms' = do
          self <- DP.getSelfPid
          void $ DP.receiveTimeout 0 ms'
          hasMsg <- DP.liftIO $ readIORef r
          if hasMsg then do
            sendS (HasMessage self)
            Receive <- DP.expect
            DP.receiveWait $ map (flip unMatch Nothing) ms
           else do
            sendS (Blocking self)
            TestReceive <- DP.expect
            go r ms'

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
                Just r  -> DP.matchIf (\a -> p a && test r a) h
  where
    test r a = snd $ unsafePerformIO $ do
                 writeIORef r True
                 return (a,False)

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

-- | Notifies the scheduler of a new process. When acknowledged, starts the new
-- process and notifies again the scheduler when the process terminates. Returns
-- immediately.
spawnLocal :: Process () -> Process ProcessId
spawnLocal p = do
    self <- DP.getSelfPid
    child <- DP.spawnLocal $ DP.expect >>= \() ->
               p `DP.finally` (DP.getSelfPid >>= sendS . ProcessTerminated)
    sendS $ CreatedNewProcess self child
    OkNewProcess <- DP.expect
    DP.send child ()
    return child

spawnWrapClosure :: Closure (Process ()) -> Process ()
spawnWrapClosure p = DP.expect >>= \() ->
  (DP.unClosure p >>= id) `DP.finally` (DP.getSelfPid >>= sendS . ProcessTerminated)

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
    sendS $ CreatedNewProcess self child
    OkNewProcess <- DP.expect
    DP.send child ()
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

-- | Looks up a process in the registry of a node.
whereisRemoteAsync :: NodeId -> String -> Process ()
whereisRemoteAsync n label = do
    self <- DP.getSelfPid
    DP.whereisRemoteAsync n label
    reply <- DP.receiveWait
      [ DP.matchIf (\(DP.WhereIsReply label' _) -> label == label') return ]
    usend self reply

-- | Registers a process in the registry of a node.
registerRemoteAsync :: NodeId -> String -> ProcessId -> Process ()
registerRemoteAsync n label p = do
    self <- DP.getSelfPid
    DP.registerRemoteAsync n label p
    reply <- DP.receiveWait
      [ DP.matchIf (\(DP.RegisterReply label' _) -> label == label') return ]
    usend self reply

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
            liftProcess $ sendS (HasMessage self)
            Receive <- liftProcess DP.expect
            DPT.receiveWaitT $ map (flip unMatchT Nothing) ms
           else do
            liftProcess $ sendS (Blocking self)
            TestReceive <- liftProcess DP.expect
            go r ms'
