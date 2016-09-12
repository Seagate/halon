{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}

-- |
-- Copyright : (C) 2014-2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- This module implements the Haskell bindings to the HA side of the
-- Notification interface. It contains the functions that pass messages between
-- the RC and the C side of the interface that communicates with Mero.
--
-- This module is enabled only when building with the RPC transport.
--
-- This module is intended to be imported qualified.

module Mero.Notification
    ( Set(..)
    , Get(..)
    , GetReply(..)
    , initialize
    , finalize
    , NIRef
    , getRPCMachine
    , notifyMero
    , withNI
    , MonadProcess(..)
    , globalResourceGraphCache
    , getSpielAddress
    , runPing
    , pruneLinks
    -- * Worker
    , notificationWorker
    , sentInterval
    , pendingInterval
    , cancelledInterval
    ) where

import Control.Distributed.Process

import Network.CEP (liftProcess, MonadProcess)

import Mero
import Mero.ConfC (Fid, Cookie(..), ServiceType(..), Word128(..))
import Mero.Notification.HAState hiding (getRPCMachine)
import Mero.Concurrent
import qualified Mero.Notification.HAState as HAState
import Mero.M0Worker
import HA.EventQueue.Producer (promulgate, promulgateWait)
import HA.ResourceGraph (Graph)
import qualified HA.ResourceGraph as G
import qualified HA.Resources.Castor as R
import HA.Resources.Mero (Service(..), SpielAddress(..))
import qualified HA.Resources.Mero as M0
import HA.Resources.Mero.Note (lookupConfObjectStates)
import qualified HA.Resources.Mero.Note as M0
import Network.RPC.RPCLite
  ( RPCAddress
  , RPCMachine
  )
import HA.RecoveryCoordinator.Events.Mero (GetSpielAddress(..),GetFailureVector(..))

import Control.Arrow ((***))
import Control.Lens
import Control.Concurrent.MVar
import Control.Distributed.Process.Internal.Types ( LocalNode, processNode )
import qualified Control.Distributed.Process.Node as CH ( forkProcess )
import Control.Monad (void, when)
import Control.Monad.Trans (MonadIO)
import Control.Monad.Catch (MonadCatch, SomeException)
import Control.Monad.Reader (ask)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TChan (TChan, readTChan, newTChanIO, writeTChan)
import qualified Control.Monad.Catch as Catch
import Data.Foldable (for_, traverse_)
import Data.Binary (Binary(..))
import Data.Hashable (Hashable)
import Data.List (nub)
import           Data.Map (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Maybe (listToMaybe, fromMaybe, mapMaybe)
import Data.Monoid ((<>))
import Data.Tuple (swap)
import Data.Typeable (Typeable)
import Data.IORef  (IORef, newIORef, readIORef, atomicModifyIORef')
import Data.Word
import qualified Data.HashPSQ as PSQ
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
  { _erNIRef :: Maybe NIRef
    -- ^ The actual 'ServerEndpoint' used by the clients. If
    -- 'Nothing', it hasn't been 'initializeInternal'd.
  , _erRefCount :: Int
    -- ^ Number of current users, used to keep track of when it's safe
    -- to finalize.
  , _erWantsFinalize :: Bool
    -- ^ MVars for finalization
    --
    -- The caller should fill the first MVar when it wants the ha_interface
    -- terminated.
    --
    -- The second MVar will be filled when the ha_interface is terminated.
  , _erFinalizationBarriers :: Maybe (MVar (), MVar ())
    -- ^ Marker if HA state should be stopped.
  }

emptyEndpointRef :: EndpointRef
emptyEndpointRef = EndpointRef Nothing 0 False Nothing

-- | Multiple places such as mero service or confc may need an
-- 'RPCMachine'. In order to ensure we don't end up initializing the machine
-- multiple times or finalizing it while it is still in use, we use a global
-- lock.
--
-- This lock is internal to the module. All users except 'initalize'
-- and 'finalizeInternal' should use 'withNI',
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

-- | Grab hold of an 'RPCMachine' and run the action on it. You
-- are required to pass in an 'RPCAddress' in case the endpoint is not
-- initialized already. Note that if the endpoint is already
-- initialized, the passed in 'RPCAddress' is __not__ used so do not
-- make any assumptions about which address the endpoint is started
-- at.
--
-- Further, be aware that the 'RPCMachine' used may be used
-- concurrently by other callers at the same time. For this reason you
-- should not use any sort of finalizers on it here: use 'finalize'
-- instead.
withNI :: forall m a. (MonadIO m, MonadProcess m, MonadCatch m)
               => RPCAddress
               -> Fid -- ^ Process Fid
               -> Fid -- ^ Profile Fid
               -> Fid -- ^ RM Fid
               -> (NIRef -> m a)
               -> m a
withNI addr processFid profileFid rmFid f =
    liftProcess (initializeInternal addr processFid profileFid rmFid)
      >>= (`withMVarProcess` f)
  where
    trySome :: MonadCatch m => m a -> m (Either SomeException a)
    trySome = Catch.try
    withMVarProcess :: (MVar EndpointRef, EndpointRef, NIRef)
                    -> (NIRef -> m a) -> m a
    withMVarProcess (m, ref, niRef) p = do
      -- Increase the refcount and run the process with the lock released
      void . liftIO $ putMVar m (ref { _erRefCount = _erRefCount ref + 1 })
      ev <- trySome $ p niRef
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

-- | Initialiazes the 'EndpointRef' subsystem.
--
-- An important thing to notice is that this function takes the lock
-- on 'globalEndpointRef' but does not release it:
-- 'initializeInternal' is only meant to be used followed by
-- 'withNI' which will release the lock. This is to ensure
-- that finalization doesn't happen between 'initializeInternal' and
-- 'withNI'.
initializeInternal :: RPCAddress -- ^ Listen address.
                   -> Fid        -- ^ Process FID
                   -> Fid        -- ^ Profile FID
                   -> Fid        -- ^ RM FID
                   -> Process (MVar EndpointRef, EndpointRef, NIRef)
initializeInternal addr processFid profileFid rmFid = liftIO (takeMVar globalEndpointRef) >>= \ref -> case ref of
  EndpointRef { _erNIRef = Just niRef } -> do
    say "initializeInternal: using existing endpoint"
    return (globalEndpointRef, ref, niRef)
  EndpointRef { _erNIRef = Nothing } -> do
    say "initializeInternal: making new endpoint"
    say $ "listening at " ++ show addr
    self <- getSelfPid
    Catch.onException
      (do
        pid <- spawnLocal $ do
                 link self
                 notificationWorker notificationChannel (void . promulgate . Set)
        link pid
        proc <- ask
        fbarrier <- liftIO $ newEmptyMVar
        fdone <- liftIO $ newEmptyMVar
        (barrier, r) <- liftGlobalM0 $ do
           (barrier, niRef) <- initializeHAStateCallbacks (processNode proc)
                                 addr processFid profileFid rmFid fbarrier fdone
           addM0Finalizer $ finalizeInternal globalEndpointRef
           let ref' = emptyEndpointRef
                        { _erNIRef = Just niRef
                        , _erFinalizationBarriers = Just (fbarrier, fdone)
                        }
           return (barrier, (globalEndpointRef, ref', niRef))
        liftIO $ either (Catch.throwM) return =<< takeMVar barrier
        return r)
      (do
        say "initializeInternal: error"
        liftIO $ putMVar globalEndpointRef ref )

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
--  Init----- Pending ---> Sent-->-+
--             |                   |->-Fini
--            Cancelled ------>----+
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
           | state `elem` filteredStates ->
             next_step (PSQ.singleton xid (pendingTime now) (Pending n)) now
        ns -> do announce ns
                 await_event
    -- Wait for the new event or next action.
    -- Invarant: 'tm' should be non-zero, in order to achieve that
    -- await_execute should not be called directly. Use next_step that maintains
    -- invariant.
    await_execute tm !psq = do
      mnote <- receiveTimeout tm [ readNoteMsg ]
      now <- liftIO $ getTime Monotonic
      case mnote of
        Nothing -> -- timeout happened process first messasge from PSQ
          case PSQ.minView psq of
            Nothing -> await_event
            Just (_, _, value, psq') -> execute value now psq'
        Just [] -> next_step psq now
        Just [note@(Note fid state)]
           | state `elem` filteredStates ->
             case PSQ.lookup fid psq of
               Nothing -> next_step (PSQ.insert fid (pendingTime now) (Pending note) psq) now
               Just (_, cache_state) ->
                 case cache_state of
                   Pending (Note _ old_state)
                     | state `isCancelling` old_state ->
                       next_step (PSQ.insert fid (cancelledTime now) (Cancelled note) psq) now
                     | state `isProgressing` old_state ->
                       next_step (PSQ.insert fid (pendingTime now) (Pending note) psq) now
                     | otherwise -> next_step psq now
                   Sent p
                     | p == note -> next_step (PSQ.insert fid (sentTime now) (Sent p) psq) now
                     | otherwise -> next_step (PSQ.insert fid (pendingTime now) (Pending note) psq) now
                   Cancelled p
                     | p == note -> next_step (PSQ.insert fid (cancelledTime' now) (Cancelled p) psq) now
                     | otherwise -> next_step (PSQ.insert fid (pendingTime now) (Pending note) psq) now
        Just ns -> do
           announce ns
           next_step psq now
    -- Execute current action.
    -- TODO: batch multiple events?
    execute (Pending n@(Note fid _)) !now !psq = do
      announce [n]
      next_step (PSQ.insert fid (sentTime now) (Sent n) psq) now
    execute Sent{} !now !psq = next_step psq now
    execute Cancelled{} !now !psq = next_step psq now
    -- Decide what to do next
    next_step !psq !now =
      case PSQ.minView psq of
        Nothing -> await_event
        Just (_, pri, v, psq') ->
          if now >= pri
          then execute v now psq'
          else await_execute (delay pri now) psq
    readNoteMsg = matchSTM (readTChan chan) return
    pendingTime   !now = now + TimeSpec 0 (fromIntegral $ 1000*pendingInterval)
    cancelledTime !now = now + TimeSpec 0 (fromIntegral $ 1000*cancelledInterval)
    -- increase only half of the period on duplicate.
    sentTime now      = now + TimeSpec 0 (fromIntegral $ 500*sentInterval)
    cancelledTime' !now = now + TimeSpec 0 (fromIntegral $ 500*cancelledInterval)
    delay  p !now      = fromIntegral $ (timeSpecAsNanoSecs $ p `diffTimeSpec` now) `div` 1000

-- | Time to keep sent value in the cache (remove duplicates).
sentInterval :: Int
sentInterval = 2000000 -- 2s

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

-- | Callback to be executed when notification was delivered or not.
data Callback = Callback
  { onDelivered :: IO ()
  , onCancelled :: IO ()
  }

instance Monoid Callback where
  mempty = Callback (return ()) (return ())
  Callback a b `mappend` Callback c d = Callback (a>>c) (b>>d)

data NIRef = NIRef
  { _ni_links     :: IORef (Map HALink (Map Word64 Callback))
  , _ni_requests  :: IORef (Map ReqId  Fid)
  , _ni_info      :: IORef (Map HALink Fid)
  , _ni_last_seen :: IORef (Map HALink TimeSpec)
  }

-- | Initializes the hastate interface in the node where it will be
-- used. Call it before @m0_init@ and before 'initialize'.
initializeHAStateCallbacks :: LocalNode
                           -> RPCAddress
                           -> Fid -- ^ Process Fid.
                           -> Fid -- ^ Profile Fid.
                           -> Fid -- ^ RM Fid.
                           -> MVar () -- ^ The caller should fill this MVar when
                                      -- it wants the ha_interface terminated.
                           -> MVar () -- ^ This MVar will be filled when the ha_interface
                                      -- is terminated.
                           -> IO (MVar (Either SomeException ()), NIRef)
initializeHAStateCallbacks lnode addr processFid profileFid rmFid fbarrier fdone = do
    niRef <- NIRef <$> newIORef Map.empty
                   <*> newIORef Map.empty
                   <*> newIORef Map.empty
                   <*> newIORef Map.empty
    barrier <- newEmptyMVar
    _ <- forkM0OS $ do -- Thread will be joined just before mero will be finalized
             er <- Catch.try $ initHAState addr processFid profileFid rmFid
                            ha_state_get
                            (ha_process_event_set niRef)
                            ha_service_event_set
                            ha_be_error
                            (ha_state_set niRef)
                            (ha_entrypoint niRef)
                            (ha_connected niRef)
                            (ha_reused niRef)
                            (ha_disconnecting niRef)
                            (ha_disconnected niRef)
                            (ha_delivered niRef)
                            (ha_cancelled niRef)
                            (ha_request_failure_vector niRef)
                            (ha_keepalive_reply niRef)
             putMVar barrier er
             case er of
               Right{} -> do
                 takeMVar fbarrier
                 finiHAState
                 putMVar fdone ()
               Left{} -> return ()
    return (barrier, niRef)
  where
    ha_state_get :: HALink -> Word64 -> NVec -> IO ()
    ha_state_get hl idx nvec = void $ CH.forkProcess lnode $ do
      liftIO $ traceEventIO "START ha_state_get"
      self <- getSelfPid
      let fids = map no_id nvec
      liftIO (fmap (getNVec fids) <$> readIORef globalResourceGraphCache)
         >>= \case
               Just nvec' ->
                 liftGlobalM0 $ void $ notify hl idx nvec'
               Nothing   -> do
                 _ <- promulgate (Get self fids)
                 GetReply nvec' <- expect
                 _ <- liftGlobalM0 $ notify hl idx nvec'
                 return ()
      liftIO $ traceEventIO "STOP ha_state_get"

    ha_process_event_set :: NIRef -> HALink -> HAMsgMeta -> ProcessEvent -> IO ()
    ha_process_event_set ni hlink meta pe = do
      currentTime <- getTime Monotonic
      atomicModifyIORef' (_ni_last_seen ni) $ \x -> (Map.insert hlink currentTime x, ())
      when  (_chp_event pe == TAG_M0_CONF_HA_PROCESS_STOPPED) $ do
        mv <- atomicModifyIORef' (_ni_links ni) $
                swap . Map.updateLookupWithKey (const $ const $ Nothing) hlink
        atomicModifyIORef' (_ni_info ni) $
          swap . Map.updateLookupWithKey (const $ const $ Nothing) hlink
        atomicModifyIORef' (_ni_last_seen ni) $
          swap . Map.updateLookupWithKey (const $ const $ Nothing) hlink
        for_ mv $ traverse_ onDelivered . Map.elems
      void $ CH.forkProcess lnode $ promulgateWait (meta, pe)

    ha_service_event_set :: HAMsgMeta -> ServiceEvent -> IO ()
    ha_service_event_set m e = void . CH.forkProcess lnode $ promulgateWait (m, e)

    ha_be_error :: HAMsgMeta -> BEIoErr -> IO ()
    ha_be_error m e = void . CH.forkProcess lnode $ promulgateWait (m, e)

    ha_state_set :: NIRef -> NVec -> IO ()
    ha_state_set _ nvec = atomically $ writeTChan notificationChannel nvec

    ha_entrypoint :: NIRef -> ReqId -> Fid -> Fid -> IO ()
    ha_entrypoint ni reqId procFid _profFid = void $ CH.forkProcess lnode $ do
      liftIO $ traceEventIO "START ha_entrypoint"
      liftIO $ atomicModifyIORef' (_ni_requests ni) $ \x -> (Map.insert reqId procFid x, ())
      say "ha_entrypoint: try to read values from cache."
      self <- getSelfPid
      liftIO ( (fmap (getSpielAddress True)) <$> readIORef globalResourceGraphCache)
        >>= \case
               Just (Just ep) -> return $ Just ep
               Just Nothing   -> do
                 say "ha_entrypoint: No spiel address. Is RM service defined?"
                 return Nothing
               Nothing        -> do
                 say "ha_entrypoint: request address from RC."
                 void $ promulgate $ GetSpielAddress self
                 expect
        >>= \case
                 Just ep -> do
                   say $ "ha_entrypoint: succeeded: " ++ show ep
                   liftGlobalM0 $
                     entrypointReply reqId (sa_confds_fid ep)
                                           (sa_confds_ep  ep)
                                           (sa_quorum     ep)
                                           (sa_rm_fid     ep)
                                           (sa_rm_ep      ep)
                 Nothing -> do
                   say "ha_entrypoint: failed."
                   liftGlobalM0 $ entrypointNoReply reqId
      liftIO $ traceEventIO "STOP ha_entrypoint"

    ha_connected :: NIRef -> ReqId -> HALink -> IO ()
    ha_connected ni req hl = do
      mfid <- atomicModifyIORef' (_ni_requests ni) $ \x -> (Map.delete req x, Map.lookup req x)
      for_ mfid $ \fid -> do
        currentTime <- getTime Monotonic
        atomicModifyIORef' (_ni_last_seen ni) $ \x -> (Map.insert hl currentTime x, ())
        atomicModifyIORef' (_ni_links ni)     $ \x -> (Map.insert hl Map.empty x, ())
        atomicModifyIORef' (_ni_info ni)      $ \x -> (Map.insert hl fid x, ())

    ha_reused :: NIRef -> ReqId -> HALink -> IO ()
    ha_reused ni ri hl = do
       mfid <- atomicModifyIORef' (_ni_requests  ni) $
         swap . Map.updateLookupWithKey (const $ const $ Nothing) ri
       for_ mfid $ \_ -> do
         currentTime <- getTime Monotonic
         atomicModifyIORef' (_ni_last_seen ni) $ \x -> (Map.insert hl currentTime x, ())

    ha_request_failure_vector :: NIRef -> HALink -> Cookie -> Fid -> IO ()
    ha_request_failure_vector ni hl cookie pool = do
      currentTime <- getTime Monotonic
      atomicModifyIORef' (_ni_last_seen ni) $ \x -> (Map.insert hl currentTime x, ())
      void $ CH.forkProcess lnode $ do
        liftIO $ traceEventIO "START ha_request_failure_vector"
        (send, recv) <- newChan
        promulgateWait (GetFailureVector pool send)
        mr <- receiveChan recv
        liftIO . liftGlobalM0 . failureVectorReply hl cookie pool
               $ fromMaybe [] mr
        liftIO $ traceEventIO "START ha_request_failure_vector"

    ha_disconnecting :: NIRef -> HALink -> IO ()
    ha_disconnecting _ _ = do
      -- our implementation of ha_disconnecting to date has always been
      -- a copy of ha_disconnected which was redundant: doing nothing at
      -- all here until we need special behaviour seems reasonable
      return ()

    ha_disconnected :: NIRef -> HALink -> IO ()
    ha_disconnected ni hl = do
      atomicModifyIORef' (_ni_links ni)     $ \x -> (Map.delete hl x, ())
      atomicModifyIORef' (_ni_last_seen ni) $ \x -> (Map.delete hl x, ())
      atomicModifyIORef' (_ni_info ni)      $ \x -> (Map.delete hl x, ())


    ha_delivered :: NIRef -> HALink -> Word64 -> IO ()
    ha_delivered ni hlink tag = do
      currentTime <- getTime Monotonic
      atomicModifyIORef' (_ni_last_seen ni) $ \x -> (Map.insert hlink currentTime x, ())
      mv <- atomicModifyIORef' (_ni_links ni) $ \mp ->
              swap $ mp & at hlink . _Just . at tag <<.~ Nothing
      for_ mv onDelivered

    ha_cancelled :: NIRef -> HALink -> Word64 -> IO ()
    ha_cancelled ni hlink tag = do
      mv <- atomicModifyIORef' (_ni_links ni) $ \mp ->
              swap $ mp & at hlink . _Just . at tag <<.~ Nothing
      for_ mv onCancelled

    -- Update the last seen time for the link the keepalive reply is coming on
    ha_keepalive_reply :: NIRef -> HALink -> IO ()
    ha_keepalive_reply ni hlink = do
      currentTime <- getTime Monotonic
      atomicModifyIORef' (_ni_last_seen ni) $ \x -> (Map.insert hlink currentTime x, ())

-- | 'disconnect' 'HALink's which haven't replied to keepalive in
-- specified amount of time.
--
-- Returns a list of process 'Fid's for the processes we know have
-- timed out the keepalive as well as the time last keepalive request
-- was sent to the process.
--
-- It should be noted that this list does not cleanly map onto what
-- 'HALink's are actually 'disconnect'ed: consider a failed link for a
-- process (link @A@) and process subsequently reconnecting on a new
-- link (link @B@). The request sent on @A@ will time out but in
-- reality the process is fine, we can talk to it on @B@ and don't
-- want to fail the process. In this case we still want to
-- 'disconnect' @A@ but don't return the process 'Fid'.
--
-- Briefly, the process 'Fid's returned here are only for processes
-- whose all links are known to be timed out.
--
-- For processes where multiple links are detected to have timed out
-- in the same run of 'pruneLinks', the 'Fid' will be reported only
-- once with 'M0.TimeSpec' for one of the links though all links will
-- be 'disconnect'ed.
pruneLinks :: NIRef
           -> Int -- ^ How many seconds should pass since we last saw
                  -- a keepalive reply to consider the process as
                  -- timed out.
           -> IO [(Fid, M0.TimeSpec)]
pruneLinks ni expireSecs = do
  now <- getTime Monotonic
  (dead,live) <- atomicModifyIORef' (_ni_last_seen ni) $ \mp ->
    let (dead, live) = Map.partition (isExpired now) mp
    in (live, (dead, live))

  case Map.null dead of
    True -> return []
    False -> do
      -- Could remove the link from the map here but let disconnect
      -- callbacks do it and deal with removing entries from the (ReqId ->
      -- Fid) Map while there.
      sendM0Task $ for_ (Map.keys dead) disconnect

      info <- readIORef (_ni_info ni)
      -- We exclude processes that have any link that is alive.
      let deadFids = Map.fromList . Map.elems
                   $ Map.mapMaybeWithKey (\l t -> (,M0.TimeSpec t) <$> Map.lookup l info) dead
          liveFids = Set.fromList $ mapMaybe (\l -> Map.lookup l info)
                   $ Map.keys live
      return . Map.toList $ Map.filterWithKey (\l _ -> l `Set.notMember` liveFids) deadFids
  where
    isExpired now (TimeSpec secs ns) =
      TimeSpec (secs + fromIntegral expireSecs) ns <= now

-- | Yields the 'RPCMachine' created with 'initializeHAStateCallbacks'.
getRPCMachine :: IO (Maybe RPCMachine)
getRPCMachine = HAState.getRPCMachine

-- | Initialiazes the 'EndpointRef' subsystem.
--
-- This function is not too useful by itself as by the time the
-- resulting 'MVar' is to be used, it could be finalized already. Most
-- users want to simply call 'withNI'.
initialize :: RPCAddress -- ^ Listen address.
           -> Fid        -- ^ Process Fid.
           -> Fid        -- ^ Profile Fid.
           -> Fid        -- ^ RM Fid.
           -> Process (MVar EndpointRef)
initialize adr processFid profileFid rmFid = do
  (m, ref, _) <- initializeInternal adr processFid profileFid rmFid
  liftIO $ putMVar m ref
  return m

-- | Internal initialization routine, should not be called by external
-- users. Only to be called when the lock on the lock is already held.
finalizeInternal :: MVar EndpointRef -> IO ()
finalizeInternal m = do
  ref <- swapMVar m emptyEndpointRef
  for_ (_erFinalizationBarriers ref) $ \(fbarrier, fdone) -> do
    putMVar fbarrier ()
    takeMVar fdone

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

-- | Send notification to all connected mero processes
notifyMero :: NIRef -- ^ Internal storage with information about connections.
           -> [Fid] -- ^ Fids that halon thinks notification should go to.
           -> Set   -- ^ Set of notifications to be send.
           -> (Fid -> IO ()) -- ^ What to do when all messages are delivered.
           -> (Fid -> IO ()) -- ^ What to do when any of messages failed to be delivered.
           -> Process ()
notifyMero ref fids (Set nvec) onOk onFail = liftIO $
    sendM0Task $ do
      links <- readIORef (_ni_links ref)
      let mkCallback l = Callback (ok l) (fail l)
          ok l = do r <- readIORef (_ni_info ref)
                    for_ (Map.lookup l r) onOk
          fail l = do r <- readIORef (_ni_info ref)
                      for_ (Map.lookup l r) onFail
      tags <- ifor links $ \l _ ->
        Map.singleton <$> notify l 0 nvec
                      <*> pure (mkCallback l)
      atomicModifyIORef' (_ni_links ref) $ \pm ->
        (Map.unionWith (Map.unionWith (<>)) pm tags, ())

      -- send failed notification for all processes that have no connection
      -- to the interface.
      info <- readIORef (_ni_info ref)
      let known = Set.fromList $ Map.elems info
      for_ (filter (`Set.notMember` known) fids) $ onFail


-- | Send a ping on every known 'HALink': we should have at least one
-- known 'HALink' per process. Each link can in turn have muliple
-- 'ReqId's associated with it (if for some reason process sends
-- entrypoint request multiple times): we just send it to most
-- recently known 'ReqId' for the link.
runPing :: NIRef -> IO ()
runPing ni = do
  sendM0Task $ do
    links <- Map.keys <$> readIORef (_ni_links ni)
    for_ links $ pingProcess (Word128 4 2)

-- | Load an entry point for spiel transaction.
getSpielAddress :: Bool -- Allow returning dead services
                -> G.Graph
                -> Maybe SpielAddress
getSpielAddress b g =
   let svs = M0.getM0Services g
       (confdsFid,confdsEps) = nub *** nub . concat $ unzip
         [ (fd, eps) | svc@(Service { s_fid = fd, s_type = CST_MGS, s_endpoints = eps }) <- svs
                     , b || M0.getState svc g == M0.SSOnline ]
       (rmFids, rmEps) = unzip
         [ (fd, eps) | svc@(Service { s_fid = fd, s_type = CST_RMS, s_endpoints = eps }) <- svs
                     , G.isConnected svc R.Is M0.PrincipalRM g]
       mrmFid = listToMaybe $ nub rmFids
       mrmEp  = listToMaybe $ nub $ concat rmEps
       quorum = ceiling $ fromIntegral (length confdsFid) / 2

  in (SpielAddress confdsFid confdsEps) <$> mrmFid <*> mrmEp <*> pure quorum
