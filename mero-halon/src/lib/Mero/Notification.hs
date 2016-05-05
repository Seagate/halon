-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This module implements the Haskell bindings to the HA side of the
-- Notification interface. It contains the functions that pass messages between
-- the RC and the C side of the interface that communicates with Mero.
--
-- This module is enabled only when building with the RPC transport.
--
-- This module is intended to be imported qualified.

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-# OPTIONS_GHC -fno-warn-dodgy-exports #-}

module Mero.Notification
    ( Set(..)
    , Get(..)
    , GetReply(..)
    , initialize_pre_m0_init
    , initialize
    , finalize
    , notifyMero
    , withServerEndpoint
    , MonadProcess(..)
    , globalResourceGraphCache
    , getSpielAddress
    -- * Worker
    , notificationWorker
    , sentInterval
    , pendingInterval
    , cancelledInterval
    ) where

import Control.Distributed.Process

import Network.CEP (liftProcess, MonadProcess)

import Mero
import Mero.ConfC (Fid, ServiceType(..))
import Mero.Notification.HAState
import Mero.M0Worker
import HA.EventQueue.Producer (promulgate)
import HA.ResourceGraph (Graph)
import qualified HA.ResourceGraph as G
import qualified HA.Resources.Castor as R
import HA.Resources.Mero (Service(..), SpielAddress(..))
import qualified HA.Resources.Mero as M0
import HA.Resources.Mero.Note (lookupConfObjectStates)
import qualified HA.Resources.Mero.Note as M0
import Network.RPC.RPCLite
  ( ListenCallbacks(..)
  , RPCAddress
  , ServerEndpoint
  , initRPC
  , finalizeRPC
  , listen
  , stopListening
  )
import HA.RecoveryCoordinator.Events.Mero (GetSpielAddress(..))

import Control.Arrow ((***))
import Control.Concurrent.MVar
import Control.Distributed.Process.Internal.Types ( LocalNode )
import qualified Control.Distributed.Process.Node as CH ( runProcess, forkProcess )
import Control.Monad ( void, join )
import Control.Monad.Trans (MonadIO)
import Control.Monad.Catch (MonadCatch, SomeException)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TChan (TChan, readTChan, newTChanIO, writeTChan)
import qualified Control.Monad.Catch as Catch
import Data.Foldable (forM_)
import Data.Binary (Binary)
import Data.Hashable (Hashable)
import Data.List (nub)
import Data.Maybe (listToMaybe)
import Data.Typeable (Typeable)
import Data.IORef  (IORef, newIORef, readIORef)
import qualified Data.HashPSQ as PSQ
import Foreign.Ptr (Ptr)
import GHC.Generics (Generic)
import System.IO.Unsafe (unsafePerformIO)
import System.Clock
import Debug.Trace (traceEventIO)


-- | This message is sent to the RC when Mero informs of a state change.
--
-- This message may be also sent by te RC when the state of an object changes
-- and the change has to be communicated to Mero.
--
newtype Set = Set NVec
        deriving (Generic, Typeable, Binary, Hashable, Show, Eq)

-- | This message is sent to the RC when Mero requests state data for some
-- objects.
data Get = Get ProcessId [Fid]
        deriving (Generic, Typeable)

instance Binary Get

-- | This message is sent by the RC in reply to a 'Get' message.
newtype GetReply = GetReply NVec
        deriving (Generic, Typeable, Binary)

-- | A reference to a 'ServerEndpoint' along with metadata about
-- number of current users and finalization.
data EndpointRef = EndpointRef
  { _erServerEndpoint :: Maybe ServerEndpoint
    -- ^ The actual 'ServerEndpoint' used by the clients. If
    -- 'Nothing', it hasn't been 'initializeInternal'd.
  , _erRefCount :: Int
    -- ^ Number of current users, used to keep track of when it's safe
    -- to finalize.
  , _erWantsFinalize :: Bool
    -- ^ A flag determining whether any client asked for finalisation.
  }

emptyEndpointRef :: EndpointRef
emptyEndpointRef = EndpointRef Nothing 0 False

-- | Multiple places such as mero service or confc may need a
-- 'ServerEndpoint' but currently RPC(Lite) only supports a single
-- endpoint at a time. In order to ensure we don't end up calling
-- 'initRPC' multiple times or 'finalizeRPC' while the endpoint is
-- still in use, we use a global lock.
--
-- This lock is internal to the module. All users except 'initalize'
-- and 'finalizeInternal' should use 'withServerEndpoint,
-- 'initializeInternal' and 'finalize' themselves.
globalEndpointRef :: MVar EndpointRef
globalEndpointRef = unsafePerformIO $ newMVar emptyEndpointRef
{-# NOINLINE globalEndpointRef #-}

-- | Global cache of the 'ResourceGraph'. This graph is used for read
-- queries from HA Note callbacks. Such graph have the same guarantees
-- as queriyng using RC but is much faster as such queries are not persisted.
-- RC is capable of updating this cache on each step, and clearing that
-- when it's no longer an RC.
-- This variable is intended to be used as follows:
-- 1. Before RC is running an operation that could send requests to
--    RG via RC, it should put current graph into the variable
-- 2. After RC have finished running this operation RC should put @Nothing@
--    into cache variable
globalResourceGraphCache :: IORef (Maybe Graph)
globalResourceGraphCache = unsafePerformIO $ newIORef Nothing
{-# NOINLINE globalResourceGraphCache #-}

-- | Grab hold of a 'ServerEndpoint' and run the action on it. You
-- are required to pass in an 'RPCAddress' in case the endpoint is not
-- initialized already. Note that if the endpoint is already
-- initialized, the passed in 'RPCAddress' is __not__ used so do not
-- make any assumptions about which address the endpoint is started
-- at.
--
-- Further, be aware that the 'ServerEndpoint' used may be used
-- concurrently by other callers at the same time. For this reason you
-- should not use any sort of finalizers on it here: use 'finalize'
-- instead.
withServerEndpoint :: forall m a. (MonadIO m, MonadProcess m, MonadCatch m)
                   => RPCAddress
                   -> (ServerEndpoint -> m a)
                   -> m a
withServerEndpoint addr f = liftProcess (initializeInternal addr)
                            >>= (`withMVarProcess` f)
  where
    trySome :: MonadCatch m => m a -> m (Either SomeException a)
    trySome = Catch.try
    withMVarProcess :: (MVar EndpointRef, EndpointRef, ServerEndpoint)
                    -> (ServerEndpoint -> m a) -> m a
    withMVarProcess (m, ref, ep) p = do
      -- Increase the refcount and run the process with the lock released
      void . liftIO $ putMVar m (ref { _erRefCount = _erRefCount ref + 1 })
      ev <- trySome $ p ep
      -- Get the possibly updated endpoint reference after our process
      -- has finished and decrease the count
      newRef <- liftIO $ takeMVar m >>= \x ->
        return (x { _erRefCount = max 0 (_erRefCount x - 1) })

      liftIO $ case _erWantsFinalize newRef && _erRefCount newRef <= 0 of
        -- There's either more workers or we don't want to finalize,
        -- just put the endpoint with decreased refcount back
        False -> putMVar m newRef
        -- We are not finalizing endpoint here, because it may be not
        -- safe to do, because RC may still be using endpoint.
        True -> putMVar m newRef
      either Catch.throwM return ev

-- | Label of the process serving configuration object states.
notificationHandlerLabel :: String
notificationHandlerLabel = "mero-halon.notification.interface.handler"

-- | Initialiazes the 'EndpointRef' subsystem.
--
-- An important thing to notice is that this function takes the lock
-- on 'globalEndpointRef' but does not release it:
-- 'initializeInternal' is only meant to be used followed by
-- 'withServerEndpoint' which will release the lock. This is to ensure
-- that finalization doesn't happen between 'initializeInternal' and
-- 'withServerEndpoint'.
initializeInternal :: RPCAddress -- ^ Listen address.
                   -> Process (MVar EndpointRef, EndpointRef, ServerEndpoint)
initializeInternal addr = liftIO (takeMVar globalEndpointRef) >>= \ref -> case ref of
  EndpointRef { _erServerEndpoint = Just ep } -> do
    say "initializeInternal: using existing endpoint"
    return (globalEndpointRef, ref, ep)
  EndpointRef { _erServerEndpoint = Nothing } -> do
    say "initializeInternal: making new endpoint"
    say $ "listening at " ++ show addr
    self <- getSelfPid
    Catch.onException
      (do
        register notificationHandlerLabel self
        pid <- spawnLocal $ do
                 link self
                 notificationWorker notificationChannel (void . promulgate . Set)
        link pid
        liftGlobalM0 $ do
          initRPC
          ep <- listen addr listenCallbacks
          addM0Finalizer $ finalizeInternal globalEndpointRef
          let ref' = emptyEndpointRef { _erServerEndpoint = Just ep }
          return (globalEndpointRef, ref', ep))
      (do unregister notificationHandlerLabel
          liftIO $ putMVar globalEndpointRef ref)
  where
    listenCallbacks = ListenCallbacks {
      receive_callback = \_ _ -> return False
    }

-- | Timeout before handler will decide that it's impossible to find entrypoint
entryPointTimeout :: Int
entryPointTimeout = 10000000


-- | Get information about Fid states from local graph.
getNVec :: [Fid] -> Graph -> [Note]
getNVec fids = fmap (uncurry Note) . lookupConfObjectStates fids


-- | Channel to send notificaitons to the worker.
notificationChannel :: TChan NVec
notificationChannel = unsafePerformIO $ newTChanIO
{-# NOINLINE notificationChannel #-}

-- |
-- Worker that implements notification filtering, that will effectively filter
-- events that were cancelled too fast and merge duplicated events into one.
--
-- Algorithm is applied only to single events with state one of:
-- ONLINE, FAILED, TRANSIENT. All other events are automatically resent to RC.
--
-- Worker embedds priority queue for the incomming messages. Each new event
-- that should be added to queue is added in @Pending@ state and worker gives
-- mero some time to cancel that event.
--
-- In case if message was cancelled or sent it moves to @Cancelled@/@Sent@
-- state appropriatelly. In those states duplicates are filtered out from the
-- queue.
--
-- Life time of the event:
--
-- @@@
--    +----- Pending ---> Sent----+
--  Init      |                   Fini
--    +----- Cancelled -----------+
-- @@@
--
--
notificationWorker :: TChan NVec -> (NVec -> Process ()) -> Process ()
notificationWorker chan announce = await_event
  where
    -- Wait for the new event when cache is empty.
    await_event = do
      note <- receiveWait [ readNoteMsg ]
      now <- liftIO $ getTime Monotonic
      case note of
        [] -> return ()
        [n@(Note xid state)]
           | state `elem` filteredStates -> do
             next_step (PSQ.singleton xid (pendingTime now) (Pending n)) now
        ns -> do announce ns
                 await_event
    -- Wait for the new event or next action.
    await_execute tm psq = do
      mnote <- receiveTimeout tm [ readNoteMsg ]
      now <- liftIO $ getTime Monotonic
      case mnote of
        Nothing -> do -- timeout happened process first messasge from PSQ
          case PSQ.minView psq of
            Nothing -> await_event
            Just (fid, _, value, psq') -> execute value now psq'
        Just [] -> next_step psq now
        Just [note@(Note fid state)]
           | state `elem` filteredStates ->
             case PSQ.lookup fid psq of
               Nothing -> next_step (PSQ.insert fid (pendingTime now) (Pending note) psq) now
               Just (pri, cache_state) ->
                 case cache_state of
                   Pending p@(Note _ old_state)
                     | state `isCancelling` old_state ->
                       next_step (PSQ.insert fid (cancelledTime now) (Cancelled note) psq) now
                     | state `isProgressing` old_state ->
                       next_step (PSQ.insert fid (pendingTime now) (Pending note) psq) now
                     | otherwise -> next_step psq now
                   Sent p
                     | p == note -> next_step (PSQ.insert fid (sentTime' now) (Sent p) psq) now
                     | otherwise -> next_step (PSQ.insert fid (pendingTime now) (Pending note) psq) now
                   Cancelled p
                     | p == note -> next_step (PSQ.insert fid (cancelledTime' now) (Cancelled p) psq) now
                     | otherwise -> next_step (PSQ.insert fid (pendingTime now) (Pending note) psq) now
        Just ns -> do
           announce ns
           next_step psq now
    -- Execute current action.
    -- TODO: batch multiple events?
    execute (Pending n@(Note fid _)) now psq = do
      announce [n]
      next_step (PSQ.insert fid (pendingTime now) (Sent n) psq) now
    execute (Sent n) now psq = do
      next_step psq now
    execute (Cancelled n) now  psq = next_step psq now
    -- Decide what to do next
    next_step psq now = do
      case PSQ.findMin psq of
        Nothing -> await_event
        Just (fid, pri, v) -> do
          if now >= pri
          then execute v now psq
          else await_execute (delay pri now) psq
    readNoteMsg = matchSTM (readTChan chan) return
    pendingTime   now = now + TimeSpec 0 (fromIntegral $ 1000*pendingInterval)
    cancelledTime now = now + TimeSpec 0 (fromIntegral $ 1000*cancelledInterval)
    sentTime      now = now + TimeSpec 0 (fromIntegral $ 1000*sentInterval)
    -- increase only half of the period on duplicate.
    sentTime' now      = now + TimeSpec 0 (fromIntegral $ 500*sentInterval)
    cancelledTime' now = now + TimeSpec 0 (fromIntegral $ 500*cancelledInterval)
    delay  p now      = fromIntegral $ (timeSpecAsNanoSecs $ p `diffTimeSpec` now) `div` 1000

-- | Time to keep sent value in the cache (remove duplicates).
sentInterval :: Int
sentInterval = 1000000

-- | Time to keep message in pending state (wait for cancellation).
pendingInterval :: Int
pendingInterval = 300000 -- 0.3s

-- | Time to keep message in cancelled state (remove duplicates).
cancelledInterval :: Int
cancelledInterval = sentInterval * 2


isCancelling :: M0.ConfObjectState -> M0.ConfObjectState -> Bool
isCancelling M0.M0_NC_ONLINE M0.M0_NC_ONLINE = False
isCancelling M0.M0_NC_ONLINE _ = True
isCancelling _ M0.M0_NC_ONLINE = True
isCancelling _ _ = False

isProgressing :: M0.ConfObjectState -> M0.ConfObjectState -> Bool
isProgressing M0.M0_NC_TRANSIENT M0.M0_NC_FAILED = True
isProgressing _ _ = False

-- | States that are affected by the filtering algorithm.
filteredStates :: [M0.ConfObjectState]
filteredStates = [ M0.M0_NC_ONLINE, M0.M0_NC_TRANSIENT, M0.M0_NC_FAILED]

-- | State inside priority queue
data CacheState = Pending Note
                | Cancelled Note
                | Sent Note


-- | Initializes the hastate interface in the node where it will be
-- used. Call it before @m0_init@ and before 'initialize'.
initialize_pre_m0_init :: LocalNode -> IO ()
initialize_pre_m0_init lnode = initHAState ha_state_get
                                           ha_state_set
                                           ha_entrypoint
  where
    ha_state_get :: NVecRef -> IO ()
    ha_state_get nvecr = void $ CH.forkProcess lnode $ do
      liftIO $ traceEventIO "START ha_state_get"
      whereis notificationHandlerLabel >>= \case
        Just rc -> do
          link rc
          self <- getSelfPid
          fids <- fmap no_id <$> liftIO (readNVecRef nvecr)
          liftIO (fmap (getNVec fids) <$> readIORef globalResourceGraphCache)
             >>= \case
                   Just nvec -> return nvec
                   Nothing   -> do
                     _ <- promulgate (Get self fids)
                     GetReply nvec <- expect
                     return nvec
             >>= \nvec -> do
                    liftIO $ updateNVecRef nvecr nvec
                    liftGlobalM0 $ doneGet nvecr 0
        Nothing -> do
          say "notification interface callbacks: unknown RC."
          liftGlobalM0 $ doneGet nvecr (-1)
      liftIO $ traceEventIO "STOP ha_state_get"

    ha_state_set :: NVec -> IO Int
    ha_state_set nvec = do
      traceEventIO "START ha_state_set"
      atomically $ writeTChan notificationChannel nvec
      traceEventIO "STOP ha_state_set"
      return 0

    ha_entrypoint :: Ptr FomV -> Ptr EntryPointRepV -> IO ()
    ha_entrypoint fom crep = void $ CH.forkProcess lnode $ do
      liftIO $ traceEventIO "START ha_entrypoint"
      say "ha_entrypoint: try to read values from cache."
      self <- getSelfPid
      liftIO ( (fmap getSpielAddress) <$> readIORef globalResourceGraphCache)
        >>= \case
               Just (Just ep) -> return $ Just ep
               Just Nothing   -> do
                 say "ha_entrypoint: No spiel address. Is RM service defined?"
                 return Nothing
               Nothing        -> do
                 say "ha_entrypoint: request address from RC."
                 void $ promulgate $ GetSpielAddress self
                 fmap join $ expectTimeout entryPointTimeout
        >>= \case
                 Just ep -> do
                   say $ "ha_entrypoint: succeeded: " ++ show ep
                   liftGlobalM0 $
                     entrypointReplyWakeup fom crep (sa_confds_fid ep)
                                                    (sa_confds_ep  ep)
                                                    (sa_rm_fid     ep)
                                                    (sa_rm_ep      ep)
                 Nothing -> do
                   say "ha_entrypoint: failed."
                   liftGlobalM0 $ entrypointNoReplyWakeup fom crep
      liftIO $ traceEventIO "STOP ha_entrypoint"

-- | Initialiazes the 'EndpointRef' subsystem.
--
-- This function is not too useful by itself as by the time the
-- resulting 'MVar' is to be used, it could be finalized already. Most
-- users want to simply call 'withServerEndpoint'.
initialize :: RPCAddress -- ^ Listen address.
           -> Process (MVar EndpointRef)
initialize adr = do
  (m, ref, _) <- initializeInternal adr
  liftIO $ putMVar m ref
  return m

-- | Internal initialization routine, should not be called by external
-- users. Only to be called when the lock on the lock is already held.
finalizeInternal :: MVar EndpointRef -> IO ()
finalizeInternal m = do
  finiHAState
  EndpointRef mep _ _ <- swapMVar m emptyEndpointRef
  forM_ mep stopListening
  finalizeRPC

-- | Finalize the Notification subsystem. We make an assumption that
-- if 'globalEndpointRef' is empty, we have already finalized before
-- and do nothing.
finalize :: Process ()
finalize = liftIO $ takeMVar globalEndpointRef >>= \case
  -- We can't finalize EndPoint here, because it may be unsafe to do so
  -- as RC could use that.
  ref | _erRefCount ref <= 0 -> putMVar globalEndpointRef ref
  -- There are some workers active so just signal that we want to
  -- finalize and put the MVar back. Once the last worker finishes, it
  -- will check this flag and run the finalization itself
      | otherwise -> putMVar globalEndpointRef $ ref { _erWantsFinalize = True }

-- | Send notification to mero address
notifyMero :: ServerEndpoint
           -> RPCAddress
           -> Set
           -> Process ()
notifyMero ep mero (Set nvec) = liftIO $
    sendM0Task (notify ep mero nvec 5)

-- | Load an entry point for spiel transaction.
getSpielAddress :: G.Graph -> Maybe SpielAddress
getSpielAddress g =
   let svs = M0.getM0Services g
       (confdsFid,confdsEps) = nub *** nub . concat $ unzip
         [ (fd, eps) | svc@(Service { s_fid = fd, s_type = CST_MGS, s_endpoints = eps }) <- svs
                     , G.isConnected svc R.Is M0.M0_NC_ONLINE g]
       (rmFids, rmEps) = unzip
         [ (fd, eps) | svc@(Service { s_fid = fd, s_type = CST_RMS, s_endpoints = eps }) <- svs
                     , G.isConnected svc R.Is M0.PrincipalRM g]
       mrmFid = listToMaybe $ nub rmFids
       mrmEp  = listToMaybe $ nub $ concat rmEps
  in (SpielAddress confdsFid confdsEps) <$> mrmFid <*> mrmEp
