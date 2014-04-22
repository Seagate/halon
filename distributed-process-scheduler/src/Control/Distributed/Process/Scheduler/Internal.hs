-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE PackageImports #-}

module Control.Distributed.Process.Scheduler.Internal
  (
  -- * Initialization
    startScheduler
  , stopScheduler
  , withScheduler
  , __remoteTable
  -- * distributed-process replacements
  , Match
  , send
  , match
  , matchIf
  , expect
  , receiveWait
  , spawnLocal
  , spawn
  -- * distributed-process-trans replacements
  , MatchT
  , matchT
  , matchIfT
  , receiveWaitT
  ) where

import "distributed-process" Control.Distributed.Process
    ( AbstractMessage, Closure, NodeId, Process, ProcessId )
import qualified "distributed-process" Control.Distributed.Process as DP
import Control.Distributed.Process.Closure ( remotable, mkClosure )
import Control.Distributed.Process.Serializable ( Serializable )
import "distributed-process-trans" Control.Distributed.Process.Trans ( MonadProcess(..) )
import qualified "distributed-process-trans" Control.Distributed.Process.Trans as DPT

import Control.Concurrent.MVar
    ( newMVar, newEmptyMVar, takeMVar, putMVar, MVar
    , readMVar, modifyMVar_
    )
import Control.Exception ( SomeException, throwIO )
import Control.Monad ( void, when, forever )
import Data.Binary ( Binary )
import Data.IORef ( newIORef, writeIORef, readIORef, IORef )
import Data.Map ( Map )
import qualified Data.Map as Map
import Data.Set ( Set )
import qualified Data.Set as Set
import Data.Typeable ( Typeable )
import GHC.Generics ( Generic )
import System.IO.Unsafe ( unsafePerformIO )
import System.Random ( StdGen, randomR, mkStdGen )


-- | Tells if there is a scheduler running.
{-# NOINLINE schedulerLock #-}
schedulerLock :: MVar Bool
schedulerLock = unsafePerformIO $ newMVar False

-- | Holds the scheduler pid if there is a scheduler running.
{-# NOINLINE schedulerVar #-}
schedulerVar :: MVar ProcessId
schedulerVar = unsafePerformIO $ newEmptyMVar

-- | Messages that the tested application sends to the scheduler.
data SchedulerMsg
    = Send ProcessId ProcessId -- ^ @Send source dest@: send a message from
                               -- @source@ to @dest@. The message data is given
                               -- to the scheduler in another message.
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
    | GetAbstractMsg ProcessId -- ^ Send message data to this auxiliary process.
    | OkNewProcess -- ^ Please go on and create the child process.
  deriving (Generic, Typeable)

-- | Transitions that the scheduler can choose to perform when all
-- processes block.
data TransitionRequest
    = PutMsg AbstractMessage -- ^ Put this message in the mailbox of the target.
    | ReceiveMsg            -- ^ Have a process pick a message from its mailbox.

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

type ProcessMessages = Map ProcessId (Map ProcessId [AbstractMessage])

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
           -- Communicates abstract messages to the scheduler.
           mvAM <- DP.liftIO $ newEmptyMVar
           -- The following auxiliary process plays a role in obtaining
           -- the message data to deliver as abstract messages.
           auxPid <- DP.spawnLocal $ forever
                       $ DP.receiveWait [ DP.matchAny $ DP.liftIO . putMVar mvAM ]
           self <- DP.getSelfPid
           spid <- DP.spawnLocal $
                     ((go auxPid mvAM (mkStdGen seed0) (Set.fromList initialProcs)
                                                     Map.empty Map.empty
                       `DP.finally` do
                          DP.exit auxPid "startScheduler: terminating scheduler"
                          DP.liftIO $ modifyMVar_ schedulerLock $
                              const $ return False
                      )
                      `DP.catchExit`
                        (\pid StopScheduler -> DP.send pid SchedulerTerminated))
                      `DP.catch` (\e -> do
                         DP.exit self $ "scheduler died: " ++ show e
                         DP.liftIO $ throwIO (e :: SomeException)
                       )
           DP.liftIO $ putMVar schedulerVar spid
           return (True,())
  where
    go :: ProcessId            -- ^ process providing message data
       -> MVar AbstractMessage -- ^ mvar through which message data is passed
       -> StdGen               -- ^ random number generator
       -> Set ProcessId        -- ^ set of tested processes
       -> Map ProcessId Bool   -- ^ state of processes (blocked | has_a_message)
       -> ProcessMessages      -- ^ messages targeted to each process
       -> Process ()
    go auxPid mvAM seed alive procs msgs
        -- Enter this equation if all processes are waiting for a transition
      | Set.size alive == Map.size procs = do
        -- complain if no process has a message and there are no messages to
        -- put in a mailbox
        when (Map.null (Map.filter id procs) && Map.null msgs) $ error $
          "startScheduler: All processes (" ++ show (Set.size alive) ++ ") are blocked."
        -- pick next transition
        let ((pid,r),seed',procs',msgs') = pickNextTransition seed procs msgs
        case r of
          PutMsg msg -> do
             DP.forward msg pid
             -- if the process was blocked let's ask it to check again if it
             -- has a message.
             procs'' <- if isBlocked pid procs
               then do DP.send pid TestReceive
                       return $ Map.delete pid procs'
               else return procs'
             go auxPid mvAM seed' alive procs'' msgs'
          ReceiveMsg -> do
             DP.send pid Receive
             go auxPid mvAM seed' alive procs' msgs'

    -- enter the next equation if some process is still active
    go auxPid mvAM seed alive procs msgs = do
      m <- DP.expect
      case m of
        -- a process is sending a message
        Send source pid -> do
            -- get the message data as an abstract message
            msg <- getAbstractMsg auxPid mvAM source
            go auxPid mvAM seed alive procs
              $ if Set.member pid alive
                 then Map.insertWith
                           (const $ Map.insertWith (flip (++)) source [msg])
                           pid (Map.singleton source [msg]) msgs
                 else msgs
        -- a process has a message and is ready to process it
        HasMessage pid ->
            go auxPid mvAM seed alive (Map.insert pid True procs) msgs
        -- a process has no messages and will block
        Blocking pid ->
            go auxPid mvAM seed alive (Map.insert pid False procs) msgs
        -- a new process will be created
        CreatedNewProcess parent child -> do
            DP.send parent OkNewProcess
            go auxPid mvAM seed (Set.insert child alive) procs msgs
        -- a process has terminated
        ProcessTerminated pid ->
            go auxPid mvAM seed (Set.delete pid alive) (Map.delete pid procs)
                                                     (Map.delete pid msgs)

    -- is the given process waiting for a new message?
    isBlocked pid procs =
      maybe (error "startScheduler.isBlocked: missing pid") not
        $ Map.lookup pid procs

    -- Requests to the source process to send the message to the
    -- auxiliary process so the scheduler can get it.
    getAbstractMsg auxPid mvAM source = do
      DP.send source $ GetAbstractMsg auxPid
      DP.liftIO $ takeMVar mvAM

    -- Picks the next transition.
    pickNextTransition :: StdGen
                       -> Map ProcessId Bool
                       -> ProcessMessages
                       -> ( (ProcessId,TransitionRequest)
                          , StdGen
                          , Map ProcessId Bool
                          , ProcessMessages
                          )
    pickNextTransition seed procs msgs =
      let has_a_message = Map.filter id procs
          msgsSizes@(msgsSize:_) = Map.foldl' (\ss@(s:_) ms -> s + Map.size ms : ss)
                                            [0] msgs
          (i,seed') = randomR (0,Map.size has_a_message + msgsSize - 1) seed
       in if i < Map.size has_a_message
        then let pid = Map.keys has_a_message !! i
              in ( (pid,ReceiveMsg)
                 , seed'
                 , Map.delete pid procs -- the process is active again
                 , msgs
                 )
        else let i' = i - Map.size has_a_message
                 i'' : rest = dropWhile (i'<) msgsSizes
                 (pid,pidMsgs) = Map.toList msgs !! length rest
                 (sender, m : ms) = Map.toList pidMsgs !! (i' - i'')
              in ( (pid,PutMsg m)
                 , seed'
                 , procs
                 , if null ms -- make sure to delete all empty containers
                    then if 1 == Map.size pidMsgs then Map.delete pid msgs
                          else Map.adjust (Map.delete sender) pid msgs
                    else Map.adjust (Map.adjust tail sender) pid msgs
                 )

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
  sendS (Send self pid)
  GetAbstractMsg auxPid <-  DP.expect
  DP.send auxPid msg

-- | Sends a message to the scheduler.
sendS :: Serializable a => a -> Process ()
sendS a = getScheduler >>= flip DP.send a

-- | Submits a transition request of type (2) to the scheduler.
-- Blocks until the transition is allowed and any of the match clauses
-- is performed.
receiveWait :: [ Match b ] -> Process b
receiveWait ms = do
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
spawn :: NodeId -> Closure (Process ()) -> Process ProcessId
spawn nid cp = do
    self <- DP.getSelfPid
    child <- DP.spawn nid $ $(mkClosure 'spawnWrapClosure) cp
    sendS $ CreatedNewProcess self child
    OkNewProcess <- DP.expect
    DP.send child ()
    return child


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

-- | Submits a transition request of type (2) to the scheduler.
-- Blocks until the transition is allowed and any of the match clauses
-- is performed.
receiveWaitT :: MonadProcess m => [MatchT m b] -> m b
receiveWaitT ms = do
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
