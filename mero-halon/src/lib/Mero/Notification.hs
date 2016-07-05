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
{-# LANGUAGE RecursiveDo #-}
{-# OPTIONS_GHC -Wall -Werror #-}

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
import HA.RecoveryCoordinator.Events.Mero (GetSpielAddress(..))

import Control.Arrow ((***))
import Control.Lens
import Control.Concurrent.MVar
import Control.Distributed.Process.Internal.Types ( LocalNode, processNode )
import qualified Control.Distributed.Process.Node as CH ( forkProcess )
import Control.Monad ( void, join, when )
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
import Data.Maybe (listToMaybe)
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
    -- ^ A flag determining whether any client asked for finalisation.
  }

emptyEndpointRef :: EndpointRef
emptyEndpointRef = EndpointRef Nothing 0 False

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
               -> (NIRef -> m a)
               -> m a
withNI addr processFid profileFid f =
    liftProcess (initializeInternal addr processFid profileFid)
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
                   -> Process (MVar EndpointRef, EndpointRef, NIRef)
initializeInternal addr processFid profileFid = liftIO (takeMVar globalEndpointRef) >>= \ref -> case ref of
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
        (barrier, r) <- liftGlobalM0 $ do
           (barrier, niRef) <- initializeHAStateCallbacks (processNode proc) addr processFid profileFid
           addM0Finalizer $ finalizeInternal globalEndpointRef
           let ref' = emptyEndpointRef { _erNIRef = Just niRef }
           return (barrier, (globalEndpointRef, ref', niRef))
        liftIO $ either (Catch.throwM) return =<< takeMVar barrier
        return r)
      (do
        say "initializeInternal: error"
        liftIO $ putMVar globalEndpointRef ref )

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
    await_execute tm psq = do
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
    execute (Pending n@(Note fid _)) now psq = do
      announce [n]
      next_step (PSQ.insert fid (sentTime now) (Sent n) psq) now
    execute Sent{} now psq = next_step psq now
    execute Cancelled{} now psq = next_step psq now
    -- Decide what to do next
    next_step psq now =
      case PSQ.minView psq of
        Nothing -> await_event
        Just (_, pri, v, psq') ->
          if now >= pri
          then execute v now psq'
          else await_execute (delay pri now) psq
    readNoteMsg = matchSTM (readTChan chan) return
    pendingTime   now = now + TimeSpec 0 (fromIntegral $ 1000*pendingInterval)
    cancelledTime now = now + TimeSpec 0 (fromIntegral $ 1000*cancelledInterval)
    -- increase only half of the period on duplicate.
    sentTime now      = now + TimeSpec 0 (fromIntegral $ 500*sentInterval)
    cancelledTime' now = now + TimeSpec 0 (fromIntegral $ 500*cancelledInterval)
    delay  p now      = fromIntegral $ (timeSpecAsNanoSecs $ p `diffTimeSpec` now) `div` 1000

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

type NIState = IORef (Map HALink (Map Word64 Callback))

data NIRef = NIRef NIState

-- | Initializes the hastate interface in the node where it will be
-- used. Call it before @m0_init@ and before 'initialize'.
initializeHAStateCallbacks :: LocalNode
                           -> RPCAddress
                           -> Fid -- ^ Process Fid.
                           -> Fid -- ^ Profile Fid.
                           -> IO (MVar (Either SomeException ()), NIRef)
initializeHAStateCallbacks lnode addr processFid profileFid = do
    links <- newIORef Map.empty
    barrier <- newEmptyMVar
    _ <- forkM0OS $ do -- Thread will be joined just before mero will be finalized
             er <- Catch.try $ initHAState addr processFid profileFid
                            ha_state_get
                            (ha_process_event_set links)
                            (ha_state_set links)
                            ha_entrypoint
                            (ha_connected links)
                            (ha_reused links)
                            (ha_disconnecting links)
                            (ha_disconnected links)
                            (ha_delivered links)
                            (ha_cancelled links)
             putMVar barrier er
    return (barrier, NIRef links)
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

    ha_process_event_set :: NIState -> HALink -> HAMsgMeta -> ProcessEvent -> IO ()
    ha_process_event_set ref hlink meta pe = do
      when (_chp_event pe == TAG_M0_CONF_HA_PROCESS_STOPPED) $ do
        mv <- atomicModifyIORef' ref $
          swap . Map.updateLookupWithKey (const $ const $ Nothing) hlink
        for_ mv $ traverse_ onDelivered
      void $ CH.forkProcess lnode $ promulgateWait (meta, pe)

    ha_state_set :: NIState -> NVec -> IO ()
    ha_state_set _ nvec = do
      traceEventIO "START ha_state_set"
      atomically $ writeTChan notificationChannel nvec
      traceEventIO "STOP ha_state_set"

    ha_entrypoint :: ReqId -> Fid -> Fid -> IO ()
    ha_entrypoint reqId _procFid _profFid = void $ CH.forkProcess lnode $ do
      liftIO $ traceEventIO "START ha_entrypoint"
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
                 fmap join $ expectTimeout entryPointTimeout
        >>= \case
                 Just ep -> do
                   say $ "ha_entrypoint: succeeded: " ++ show ep
                   liftGlobalM0 $
                     entrypointReply reqId (sa_confds_fid ep)
                                           (sa_confds_ep  ep)
                                           (sa_rm_fid     ep)
                                           (sa_rm_ep      ep)
                 Nothing -> do
                   say "ha_entrypoint: failed."
                   liftGlobalM0 $ entrypointNoReply reqId
      liftIO $ traceEventIO "STOP ha_entrypoint"

    ha_connected :: NIState -> ReqId -> HALink -> IO ()
    ha_connected links _ hl = do
      atomicModifyIORef' links $ \x -> (Map.insert hl Map.empty x, ())

    ha_reused :: NIState -> ReqId -> HALink -> IO ()
    ha_reused _ _ _ = return ()

    ha_disconnecting :: NIState -> HALink -> IO ()
    ha_disconnecting links hl = do
      atomicModifyIORef' links $ \x -> (Map.delete hl x, ())
      -- TODO: call ha_state_disconnect hl when safe

    ha_disconnected :: NIState -> HALink -> IO ()
    ha_disconnected links hl = do
      atomicModifyIORef' links $ \x -> (Map.delete hl x, ())
      -- TODO: call ha_state_disconnect hl when safe


    ha_delivered :: NIState -> HALink -> Word64 -> IO ()
    ha_delivered ref hlink tag = do
      mv <- atomicModifyIORef' ref $ \mp ->
              swap $ mp & at hlink . _Just . at tag <<.~ Nothing
      for_ mv $ \x -> do
        onDelivered x

    ha_cancelled :: NIState -> HALink -> Word64 -> IO ()
    ha_cancelled ref hlink tag = do
      mv <- atomicModifyIORef' ref $ \mp ->
              swap $ mp & at hlink . _Just . at tag <<.~ Nothing
      for_ mv $ onCancelled

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
           -> Fid        -- ^ Profule Fid.
           -> Process (MVar EndpointRef)
initialize adr processFid profileFid = do
  (m, ref, _) <- initializeInternal adr processFid profileFid
  liftIO $ putMVar m ref
  return m

-- | Internal initialization routine, should not be called by external
-- users. Only to be called when the lock on the lock is already held.
finalizeInternal :: MVar EndpointRef -> IO ()
finalizeInternal m = do
  void $ swapMVar m emptyEndpointRef
  finiHAState

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
           -> Set   -- ^ Set of notifications to be send.
           -> IO () -- ^ What to do when all messages are delivered.
           -> IO () -- ^ What to do when any of messages failed to be delivered.
           -> Process ()
notifyMero (NIRef linksRef) (Set nvec) onOk onFail = liftIO $
    sendM0Task $ do
      links <- readIORef linksRef
      tags <- mdo
        storage <- liftIO $ newIORef tags
        let mkCallback l = Callback
              (do (mv, p) <- atomicModifyIORef' storage
                    $ (\(mv,p) -> (p,(mv,p))) . Map.updateLookupWithKey (\_ _ -> Nothing) l
                  when (Map.null p) $
                    for_ mv $ const $ do
                      onOk)
              (do mold <- atomicModifyIORef' storage
                    $ swap . Map.updateLookupWithKey (\_ _ -> Nothing) l
                  for_ mold $ const onFail)
        tags <- ifor links $ \l _ ->
           Map.singleton <$> notify l 0 nvec
                         <*> pure (mkCallback l)
        return tags
      atomicModifyIORef' linksRef $ \pm ->
        (Map.unionWith (Map.unionWith (<>)) pm tags, ())


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
  in (SpielAddress confdsFid confdsEps) <$> mrmFid <*> mrmEp
