{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Copyright : (C) 2014-2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
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
    , finalize
    , NIRef
    , getRPCMachine
    , notifyMero
    , withNI
    , withMero
    , MonadProcess(..)
    , globalResourceGraphCache
    , getSpielAddress
    , runPing
    , pruneLinks
    -- * Worker
    , getM0Worker
    ) where

import           Mero.ConfC
  ( Cookie(..)
  , Fid
  , ServiceType(..)
  , Word128(..)
  , m0_fid0
  )
import           Mero.Concurrent
import qualified Mero.Notification.HAState as HA
import           Mero.Engine
import           Mero.Lnet
import           Mero.M0Worker

import           HA.EventQueue (promulgateWait)
import           HA.Logger (mkHalonTracerIO)
import           HA.RecoveryCoordinator.Mero.Actions.Conf (getPrincipalRM')
import           HA.RecoveryCoordinator.Mero.Events
  ( GetSpielAddress(..)
  , GetFailureVector(..)
  )
import           HA.ResourceGraph (Graph)
import qualified HA.ResourceGraph as G
import           HA.Resources.Castor (Is(..))
import           HA.Resources.Mero (Service(..), SpielAddress(..))
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note
  ( PrincipalRM(..)
  , getState
  , lookupConfObjectStates
  )
import           HA.SafeCopy
import           Network.CEP (liftProcess, MonadProcess)
import           Network.RPC.RPCLite (RPCAddress, RPCMachine)

import           Control.Arrow ((***))
import           Control.Concurrent.MVar
import           Control.Concurrent.STM
import           Control.Distributed.Process
import           Control.Distributed.Process.Internal.Types
  ( LocalNode
  , processNode
  )
import qualified Control.Distributed.Process.Node as CH (forkProcess)
import           Control.Lens (ifor, at, _Just, (<<.~), (&))
import           Control.Monad (void, when)
import           Control.Monad.Catch (MonadCatch, SomeException)
import qualified Control.Monad.Catch as Catch
import           Control.Monad.Reader (ask)
import           Control.Monad.Trans (MonadIO)
import           Data.Binary (Binary(..))
import           Data.Foldable (for_, traverse_)
import           Data.Function (fix)
import           Data.Hashable (Hashable)
import           Data.IORef (IORef, newIORef, readIORef, atomicModifyIORef')
import           Data.List (nub)
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe (listToMaybe, fromMaybe)
import           Data.Monoid ((<>))
import qualified Data.Set as Set
import qualified Data.Text as T
import           Data.Tuple (swap)
import           Data.Typeable (Typeable)
import           Data.Word (Word64)
import           Debug.Trace (traceEventIO)
import           GHC.Generics (Generic)
import           System.Clock
import           System.IO.Unsafe (unsafePerformIO)

import           Prelude hiding (log)

log :: String -> IO ()
log = mkHalonTracerIO "m0:notification"

-- | This message is sent to the RC when Mero informs of a state change.
--
-- This message may be also sent by te RC when the state of an object changes
-- and the change has to be communicated to Mero.
--
newtype Set_v0 = Set_v0 HA.NVec
  deriving (Generic, Typeable, Hashable, Show, Eq)

data Set = Set HA.NVec (Maybe HA.HAMsgMeta)
  deriving (Generic, Typeable, Show, Eq)
instance Hashable Set
instance Monoid Set where
  mempty = Set mempty mempty
  mappend (Set v1 mm1) (Set v2 mm2) = Set (v1 <> v2) (mm1 <> mm2)

instance Migrate Set where
     type MigrateFrom Set = Set_v0
     migrate (Set_v0 nvec) = Set nvec Nothing

deriveSafeCopy 0 'base ''Set_v0
deriveSafeCopy 1 'extension ''Set

-- | This message is sent to the RC when Mero requests state data for some
-- objects.
data Get = Get ProcessId [Fid]
        deriving (Generic, Typeable)
deriveSafeCopy 0 'base ''Get

-- | This message is sent by the RC in reply to a 'Get' message.
newtype GetReply = GetReply HA.NVec
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
  , _erFinalizationBarriers :: Maybe (TMVar (), MVar ())
    -- ^ Marker if HA state should be stopped.
  , _erWorker :: Maybe M0Worker
    -- ^ Dedicated worker for the spiel operations.
  }

emptyEndpointRef :: EndpointRef
emptyEndpointRef = EndpointRef Nothing 0 False Nothing Nothing

-- | Multiple places such as mero service or confc may need an
-- 'RPCMachine'. In order to ensure we don't end up initializing the machine
-- multiple times or finalizing it while it is still in use, we use a global
-- lock.
--
-- This lock is internal to the module. All users except 'finalizeInternal'
-- should use 'withNI', 'initializeInternal' and 'finalize' themselves.
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
               -> Fid -- ^ HA Service Fid
               -> Fid -- ^ RM Service Fid
               -> (NIRef -> m a)
               -> m a
withNI addr processFid haFid rmFid f =
    liftProcess (initializeInternal addr processFid haFid rmFid)
      >>= (`withMVarProcess` f)
  where
    trySome :: m a -> m (Either SomeException a)
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

      case _erRefCount newRef <= 0 of
        -- There's either more workers or we don't want to finalize,
        -- just put the endpoint with decreased refcount back
        False -> liftIO $ putMVar m newRef
        -- We can finalize endpoint now.
        True -> do liftIO $ putMVar m newRef
                   liftProcess finalize
      either Catch.throwM return ev

-- | Initialiazes the 'EndpointRef' subsystem.
--
-- An important thing to notice is that this function takes the lock
-- on 'globalEndpointRef' but does not release it:
-- 'initializeInternal' is only meant to be used followed by
-- 'withNI' which will release the lock. This is to ensure
-- that finalization doesn't happen between 'initializeInternal' and
-- 'withNI'.
initializeInternal :: RPCAddress -- ^ Listen address
                   -> Fid        -- ^ Process FID
                   -> Fid        -- ^ HA Service FID
                   -> Fid        -- ^ RM Service FID
                   -> Process (MVar EndpointRef, EndpointRef, NIRef)
initializeInternal addr processFid haFid rmFid = liftIO (takeMVar globalEndpointRef) >>= \ref -> case ref of
  EndpointRef { _erNIRef = Just niRef } -> do
    say "initializeInternal: using existing endpoint"
    return (globalEndpointRef, ref, niRef)
  EndpointRef { _erNIRef = Nothing } -> do
    say "initializeInternal: making new endpoint"
    say $ "listening at " ++ show addr
    Catch.onException
      (do
        proc <- ask
        fbarrier <- liftIO $ newEmptyTMVarIO
        fdone <- liftIO $ newEmptyMVar
        (barrier, niRef) <- liftGlobalM0 $
           initializeHAStateCallbacks (processNode proc)
             addr processFid haFid rmFid fbarrier fdone
        eresult <- liftIO $ takeMVar barrier
        case eresult of
          Left exc -> Catch.throwM exc
          Right worker ->
            let ref' = emptyEndpointRef
                        { _erNIRef = Just niRef
                        , _erFinalizationBarriers = Just (fbarrier, fdone)
                        , _erWorker = Just worker
                        }
            in return (globalEndpointRef, ref', niRef))
      (do
        say "initializeInternal: error"
        liftIO $ putMVar globalEndpointRef ref )

-- | Get information about Fid states from local graph.
getNVec :: [Fid] -> Graph -> [HA.Note]
getNVec fids = fmap (uncurry HA.Note) . lookupConfObjectStates fids

-- | Callback to be executed when notification was delivered or not.
data Callback = Callback
  { onDelivered :: IO ()
  , onCancelled :: IO ()
  }

instance Monoid Callback where
  mempty = Callback (return ()) (return ())
  Callback a b `mappend` Callback c d = Callback (a>>c) (b>>d)

-- | Notification interface reference; contains references to
-- necessary information about 'HA.HALink' and process 'Fid'
-- associations.
data NIRef = NIRef
  { _ni_links     :: MVar (Map HA.HALink (Map Word64 Callback))
  -- ^ Stores callbacks that should be ran when a notification to the
  -- given 'HA.HALink' either fails or succeeds.
  --
  -- 'MVar' is needed for synchronisation.
  , _ni_requests  :: IORef (Map HA.ReqId  Fid)
  -- ^ Stores mapping of 'HA.ReqId's to process 'Fid's.
  , _ni_info      :: IORef (Map HA.HALink Fid)
  -- ^ Stores mapping of 'HA.HALink's to process 'Fid's. Combine with
  -- '_ni_requests' we can retrieve association between 'HA.ReqId' and
  -- 'HA.HALink'.
  , _ni_last_seen :: IORef (Map HA.HALink TimeSpec)
  -- ^ Last time given 'HA.HALink' has replied to a keepalive request.
  , _ni_worker    :: TChan (IO ())
  -- ^ Channel of tasks executed by mero worker.
  }

-- | Notify mero using notification interface thread.
-- Action is executed asynchronously.
notifyNi :: NIRef -> HA.HALink -> Word64 -> HA.NVec -> Fid -> Fid -> Process ()
notifyNi ref hl w v ha_pfid ha_sfid =
    liftIO . atomically . writeTChan (_ni_worker ref) . void $
      HA.notify hl w v ha_pfid ha_sfid dummy_epoch
  where
    dummy_epoch = 0

-- | Run generic action on notification interface. Use with great care
-- as this code may heavily impact performance, as notificaion interface
-- thread will be blocked while action is executed.
actionOnNi :: NIRef -> IO () -> IO ()
actionOnNi ref = atomically . writeTChan (_ni_worker ref)

-- | Initializes the hastate interface in the node where it will be
-- used. Call it before @m0_init@ and before 'initialize'.
initializeHAStateCallbacks :: LocalNode
                           -> RPCAddress
                           -> Fid -- ^ Process Fid.
                           -> Fid -- ^ HA Service Fid.
                           -> Fid -- ^ RM Service Fid.
                           -> TMVar () -- ^ The caller should fill this TMVar when
                                      -- it wants the ha_interface terminated.
                           -> MVar () -- ^ This MVar will be filled when the ha_interface
                                      -- is terminated.
                           -> IO (MVar (Either SomeException M0Worker), NIRef)
initializeHAStateCallbacks lnode addr processFid haFid rmFid fbarrier fdone = do
    taskPool <- newTChanIO
    niRef <- NIRef <$> newMVar  Map.empty
                   <*> newIORef Map.empty
                   <*> newIORef Map.empty
                   <*> newIORef Map.empty
                   <*> pure taskPool
    let hsc = HA.HSC
         { HA.hscStateGet      = ha_state_get niRef
         , HA.hscProcessEvent  = ha_process_event_set niRef
         , HA.hscStobIoqError  = ha_stob_ioq_error niRef
         , HA.hscServiceEvent  = ha_service_event_set niRef
         , HA.hscBeError       = ha_be_error niRef
         , HA.hscStateSet      = ha_state_set niRef
         , HA.hscFailureVector = ha_request_failure_vector niRef
         , HA.hscKeepalive     = ha_keepalive_reply niRef
         , HA.hscRPCEvent      = ha_rpc_event niRef
         }
    barrier <- newEmptyMVar
    _ <- forkM0OS $ do -- Thread will be joined just before mero will be finalized
             er <- Catch.try $ HA.initHAState addr processFid haFid rmFid
                            hsc
                            (ha_entrypoint niRef)
                            (ha_connected niRef)
                            (ha_reused niRef)
                            (ha_absent niRef)
                            (ha_disconnecting niRef)
                            (ha_disconnected niRef)
                            (ha_delivered niRef)
                            (ha_cancelled niRef)
             case er of
               Right{} -> do
                 worker <- newM0Worker
                 putMVar barrier (Right worker)
                 addM0Finalizer $ finalizeInternal globalEndpointRef
                 fix $ \loop -> do
                   et <- atomically $ (Left  <$> takeTMVar fbarrier)
                             `orElse` (Right <$> readTChan taskPool)
                   for_ et $ \t -> t >> loop
                 -- During stop ha interface can still send messages
                 -- and those messages should be processed. So we fork
                 -- a worker that processes them. Because our thread
                 -- would be blocked.
                 d <- newTVarIO False
                 tid <- forkM0OS $ fix $ \loop -> do
                          et <- atomically $ (pure Nothing <* (check =<< readTVar d))
                                  `orElse` (Just <$> readTChan taskPool)
                          for_ et $ \t -> t >> loop
                 terminateM0Worker worker
                 HA.finiHAState
                 atomically $ writeTVar d True
                 joinM0OS tid
                 putMVar fdone ()
               Left e -> putMVar barrier (Left e)
    return (barrier, niRef)
  where
    ha_state_get :: NIRef -> HA.HAMsgPtr -> HA.HALink -> Word64 -> HA.NVec -> IO ()
    ha_state_get ni p hl idx nvec = void $ CH.forkProcess lnode $ do
      self <- getSelfPid
      let fids = map HA.no_id nvec
      liftIO (fmap (getNVec fids) <$> readIORef globalResourceGraphCache)
         >>= \case
               Just nvec' -> do
                 liftIO $ actionOnNi ni $ HA.delivered hl p
                 notifyNi ni hl idx nvec' processFid haFid
               Nothing   -> do
                 _ <- promulgateWait (Get self fids)
                 liftIO $ actionOnNi ni $ HA.delivered hl p
                 GetReply nvec' <- expect
                 notifyNi ni hl idx nvec' processFid haFid

    ha_process_event_set :: NIRef -> HA.HAMsgPtr -> HA.HALink -> HA.HAMsgMeta -> HA.ProcessEvent -> IO ()
    ha_process_event_set ni p hlink meta pe = do
      currentTime <- getTime Monotonic
      atomicModifyIORef' (_ni_last_seen ni) $ \x -> (Map.insert hlink currentTime x, ())
      when  (HA._chp_event pe == HA.TAG_M0_CONF_HA_PROCESS_STOPPED) $ do
        mv :: Maybe (Map Word64 Callback) <- modifyMVar (_ni_links ni) $ \links -> do
          _ <- atomicModifyIORef' (_ni_info ni) $
            swap . Map.updateLookupWithKey (const $ const Nothing) hlink
          _ <- atomicModifyIORef' (_ni_last_seen ni) $
            swap . Map.updateLookupWithKey (const $ const Nothing) hlink
          return $ swap $ Map.updateLookupWithKey (const $ const Nothing) hlink links
        log $ "ha_process_event_set: link=" ++ show hlink
            ++ " tags=" ++ show (Map.keys <$> mv)
        for_ mv $ traverse_ onDelivered . Map.elems
      void . CH.forkProcess lnode $ do
        promulgateWait $ HA.HAMsg pe meta
        liftIO $ actionOnNi ni $ HA.delivered hlink p

    ha_stob_ioq_error :: NIRef -> HA.HAMsgPtr -> HA.HALink -> HA.HAMsgMeta -> HA.StobIoqError -> IO ()
    ha_stob_ioq_error ni p hlink m sie = void . CH.forkProcess lnode $ do
      promulgateWait $ HA.HAMsg sie m
      liftIO $ actionOnNi ni $ HA.delivered hlink p

    ha_service_event_set :: NIRef -> HA.HAMsgPtr -> HA.HALink -> HA.HAMsgMeta -> HA.ServiceEvent -> IO ()
    ha_service_event_set ni p hlink m e = void . CH.forkProcess lnode $ do
      promulgateWait $ HA.HAMsg e m
      liftIO $ actionOnNi ni $ HA.delivered hlink p

    ha_be_error :: NIRef -> HA.HAMsgPtr -> HA.HALink -> HA.HAMsgMeta -> HA.BEIoErr -> IO ()
    ha_be_error ni p hlink m e = void . CH.forkProcess lnode $ do
      promulgateWait $ HA.HAMsg e m
      liftIO $ actionOnNi ni $ HA.delivered hlink p

    ha_state_set :: NIRef -> HA.HAMsgPtr -> HA.HALink -> HA.NVec -> HA.HAMsgMeta -> IO ()
    ha_state_set ni p hlink nvec meta = void . CH.forkProcess lnode $ do
      promulgateWait $ Set nvec (Just meta)
      liftIO $ actionOnNi ni $ HA.delivered hlink p

    ha_entrypoint :: NIRef -> HA.ReqId -> Fid -> Fid -> IO ()
    ha_entrypoint ni reqId procFid profFid = void $ CH.forkProcess lnode $ do
      liftIO $ traceEventIO "START ha_entrypoint"
      liftIO $ atomicModifyIORef' (_ni_requests ni) $ \x -> (Map.insert reqId procFid x, ())
      self <- getSelfPid
      liftIO ( (fmap (getSpielAddress True)) <$> readIORef globalResourceGraphCache)
        >>= \case
               Just (Just ep) -> do
                 return $ Just ep
               Just Nothing   -> do
                 say "ha_entrypoint: No spiel address. Is RM service defined?"
                 return Nothing
               Nothing        -> do
                 say "ha_entrypoint: request address from RC."
                 promulgateWait $ GetSpielAddress procFid profFid self
                 expect
        >>= \case
                 Just ep -> do
                   say $ "ha_entrypoint: succeeded: " ++ show ep
                   liftGlobalM0 $
                     HA.entrypointReply reqId (sa_confds_fid ep)
                                              (sa_confds_ep  ep)
                                              (sa_quorum     ep)
                                              (sa_rm_fid     ep)
                                              (sa_rm_ep      ep)
                 Nothing -> do
                   say "ha_entrypoint: failed."
                   liftGlobalM0 $ HA.entrypointNoReply reqId
      liftIO $ traceEventIO "STOP ha_entrypoint"

    ha_connected :: NIRef -> HA.ReqId -> HA.HALink -> IO ()
    ha_connected ni req hl = do
      mfid <- atomicModifyIORef' (_ni_requests ni) $
        \x -> (Map.delete req x, Map.lookup req x)
      for_ mfid $ \fid -> do
        currentTime <- getTime Monotonic
        atomicModifyIORef' (_ni_last_seen ni) $ \x -> (Map.insert hl currentTime x, ())
        modifyMVar_ (_ni_links ni) $ \links -> do
          atomicModifyIORef' (_ni_info ni) $ \x -> (Map.insert hl fid x, ())
          log $ "ha_connected: link=" ++ show hl ++ " fid=" ++ show fid
          return $ Map.insertWith Map.union hl Map.empty links

    ha_reused :: NIRef -> HA.ReqId -> HA.HALink -> IO ()
    ha_reused ni ri hl = do
       mfid <- atomicModifyIORef' (_ni_requests  ni) $
         swap . Map.updateLookupWithKey (const $ const Nothing) ri
       for_ mfid $ \fid -> do
         log $ "ha_reused: link=" ++ show hl ++ " fid=" ++ show fid
         currentTime <- getTime Monotonic
         atomicModifyIORef' (_ni_last_seen ni) $ \x -> (Map.insert hl currentTime x, ())

    -- XXX we don't really care about this callback. Let's ignore it and fix the issue if it becomes a problem.
    ha_absent :: NIRef -> HA.ReqId -> IO ()
    ha_absent _ni _ri = pure ()

    ha_request_failure_vector :: NIRef -> HA.HAMsgPtr -> HA.HALink -> Cookie -> Fid -> IO ()
    ha_request_failure_vector ni p hl cookie pool = do
      currentTime <- getTime Monotonic
      atomicModifyIORef' (_ni_last_seen ni) $ \x -> (Map.insert hl currentTime x, ())
      void $ CH.forkProcess lnode $ do
        liftIO $ traceEventIO "START ha_request_failure_vector"
        (send, recv) <- newChan
        promulgateWait (GetFailureVector pool send)
        liftIO $ actionOnNi ni $ HA.delivered hl p
        mr <- receiveChan recv
        liftIO $ actionOnNi ni $ HA.failureVectorReply hl cookie pool processFid haFid $ fromMaybe [] mr
        liftIO $ traceEventIO "STOP ha_request_failure_vector"

    ha_disconnecting :: NIRef -> HA.HALink -> IO ()
    ha_disconnecting ni hl = do
      modifyMVar_ (_ni_links ni) $ \links -> do
        atomicModifyIORef' (_ni_info ni)      $ \x -> (Map.delete hl x, ())
        HA.disconnect hl
        log $ "ha_disconnecting: link=" ++ show hl
        return $ Map.delete hl links

    ha_disconnected :: NIRef -> HA.HALink -> IO ()
    ha_disconnected ni hl = do
      modifyMVar_ (_ni_links ni) $ \links -> do
        atomicModifyIORef' (_ni_last_seen ni) $ \x -> (Map.delete hl x, ())
        atomicModifyIORef' (_ni_info ni)      $ \x -> (Map.delete hl x, ())
        log $ "ha_disconnected: link=" ++ show hl
        return $ Map.delete hl links

    ha_delivered :: NIRef -> HA.HALink -> Word64 -> IO ()
    ha_delivered ni hlink tag = do
      currentTime <- getTime Monotonic
      atomicModifyIORef' (_ni_last_seen ni) $ \x ->
        (Map.insert hlink currentTime x, ())
      mv <- modifyMVar (_ni_links ni) $ \links ->
        return $ swap $ links & at hlink . _Just . at tag <<.~ Nothing
      log $ "ha_delivered: link=" ++ show hlink
          ++ " tag=" ++ show tag ++ " has_cb=" ++ show (not $ null mv)
      for_ mv onDelivered

    ha_cancelled :: NIRef -> HA.HALink -> Word64 -> IO ()
    ha_cancelled ni hlink tag = do
      mv <- modifyMVar (_ni_links ni) $ \links ->
        return $ swap $ links & at hlink . _Just . at tag <<.~ Nothing
      log $ "ha_cancelled: link=" ++ show hlink
          ++ " tag=" ++ show tag ++ " has_cb=" ++ show (not $ null mv)
      for_ mv onCancelled

    -- Update the last seen time for the link the keepalive reply is coming on
    ha_keepalive_reply :: NIRef -> HA.HALink
                       -> Word128 -- ^ kap_id (matching the request)
                       -> Word64 -- ^ kap_counter (should increment)
                       -> IO ()
    ha_keepalive_reply ni hlink kap_id kap_counter = do
      log $ "ha_keepalive_reply: link=" ++ show hlink
          ++ " kap_id=" ++ show kap_id
          ++ " kap_counter=" ++ show kap_counter
      currentTime <- getTime Monotonic
      atomicModifyIORef' (_ni_last_seen ni) $ \x -> (Map.insert hlink currentTime x, ())

    ha_rpc_event :: NIRef -> HA.HAMsgPtr -> HA.HALink -> HA.HAMsgMeta -> HA.RpcEvent -> IO ()
    ha_rpc_event ni p hl m e = void . CH.forkProcess lnode $ do
      promulgateWait $ HA.HAMsg e m
      liftIO $ actionOnNi ni $ HA.delivered hl p

-- | Find processes with "dead" links and fail them. Do not disconnect
-- the links manually: mero will invoke a callback we set in
-- 'initializeHAStateCallbacks' which will do the disconnecting.
--
-- We don't have to account for multiple links, some timing out and
-- some alive: when process reconnects, it re-uses old link. Only new
-- processes use new links. We won't see a new process unless we have
-- failed and restarted an old one, which will run the callback and
-- disconnect the old link.
--
-- <https://seagate.slack.com/archives/mero-halon/p1476267532005945>
pruneLinks :: NIRef
           -> Int -- ^ How many seconds should pass since we last saw
                  -- a keepalive reply to consider the process as
                  -- timed out.
           -> IO [(Fid, M0.TimeSpec)]
pruneLinks ni expireSecs = do
  now <- getTime Monotonic
  dead <- atomicModifyIORef' (_ni_last_seen ni) $ \mp ->
    -- Keep alive processes in map and extract dead ones
    swap (Map.partition (isExpired now) mp)

  case Map.null dead of
    True -> return []
    False -> do
      info <- readIORef (_ni_info ni)
      let deadFids = Map.fromList . Map.elems
                   $ Map.mapMaybeWithKey (\l t -> (,M0.TimeSpec t) <$> Map.lookup l info) dead
      return $ Map.toList deadFids
  where
    isExpired now (TimeSpec secs ns) =
      TimeSpec (secs + fromIntegral expireSecs) ns <= now

-- | Yields the 'RPCMachine' created with 'initializeHAStateCallbacks'.
getRPCMachine :: IO (Maybe RPCMachine)
getRPCMachine = HA.getRPCMachine

-- | Internal initialization routine, should not be called by external
-- users. Only to be called when the lock on the lock is already held.
finalizeInternal :: MVar EndpointRef -> IO ()
finalizeInternal m = do
  ref <- takeMVar m
  for_ (_erFinalizationBarriers ref) $ \(fbarrier, fdone) -> do
    atomically $ putTMVar fbarrier ()
    takeMVar fdone
  putMVar m emptyEndpointRef

-- | Finalize the Notification subsystem. We make an assumption that
-- if 'globalEndpointRef' is empty, we have already finalized before
-- and do nothing.
finalize :: Process ()
finalize = liftIO $ takeMVar globalEndpointRef >>= \case
  ref | _erRefCount ref <= 0 -> do putMVar globalEndpointRef ref
                                   finalizeInternal globalEndpointRef
  -- There are some workers active so just signal that we want to
  -- finalize and put the MVar back. Once the last worker finishes, it
  -- will check this flag and run the finalization itself
      | otherwise -> putMVar globalEndpointRef $ ref { _erWantsFinalize = True }

-- | Send notification to all connected mero processes
notifyMero :: NIRef -- ^ Internal storage with information about connections.
           -> [Fid] -- ^ Fids that halon thinks notification should go to.
           -> Set   -- ^ Set of notifications to be send.
           -> Fid   -- ^ HA process 'Fid'
           -> Fid   -- ^ HA service 'Fid'
           -> Word64 -- ^ HA message epoch
           -> (Fid -> IO ()) -- ^ What to do when all messages are delivered.
           -> (Fid -> IO ()) -- ^ What to do when any of messages failed to be delivered.
           -> Process ()
notifyMero ref fids (Set nvec _) ha_pfid ha_sfid epoch onOk onFail = liftIO $ do
   known <- sendM0Task $ modifyMVar (_ni_links ref) $ \links -> do
      let mkCallback l = Callback (ok l) (fail' l)
          ok l = do r <- readIORef (_ni_info ref)
                    for_ (Map.lookup l r) $ \fid -> do
                      log $ "Notification for epoch " ++ show epoch
                          ++ " acknowledged on link " ++ show l
                          ++ " from " ++ show fid
                      onOk fid
          fail' l = do r <- readIORef (_ni_info ref)
                       for_ (Map.lookup l r) $ \fid -> do
                         log $ "Notification for epoch " ++ show epoch
                             ++ " failed on link " ++ show l
                             ++ " for " ++ show fid
                         onFail fid
      tags :: Map HA.HALink (Map Word64 Callback) <- ifor links $ \l _ ->
        Map.singleton <$> HA.notify l 0 nvec ha_pfid ha_sfid epoch
                      <*> pure (mkCallback l)
      log $ "notifyMero: epoch=" ++ show epoch ++ " [(link, tag)]="
          ++ show (fmap (head . Map.keys) <$> Map.toAscList tags)
      -- send failed notification for all processes that have no connection
      -- to the interface.
      info <- readIORef (_ni_info ref)
      return ( Map.unionWith (Map.unionWith (<>)) links tags
             , Set.fromList $ Map.elems info)
   for_ (filter (`Set.notMember` known) fids) $ \fid -> do
    log $ "Notification for epoch " ++ show epoch
        ++ " failed due to no link for " ++ show fid
    onFail fid

-- | Send a ping on every known 'HA.HALink': we should have at least one
-- known 'HA.HALink' per process.
runPing :: NIRef -> Fid -> Fid -> IO ()
runPing ni ha_pfid ha_sfid  = actionOnNi ni $ do
    links <- Map.keys <$> readMVar (_ni_links ni)
    info <- readIORef (_ni_info ni)
    for_ links $ \l -> do
      let !fid' = fromMaybe m0_fid0 $! Map.lookup l info
      HA.pingProcess (Word128 4 2) l fid' ha_pfid ha_sfid

-- | Load an entry point for spiel transaction.
getSpielAddress :: Bool -- Allow returning dead confd services
                -> G.Graph
                -> Maybe SpielAddress
getSpielAddress b g =
  let ep2s = T.unpack . encodeEndpoint
      svs = M0.getM0Services g
      qsize = if b
              then length [ () | Service {s_type = CST_CONFD} <- svs ]
              else length confdsFid
      (confdsFid,confdsEps) = nub *** nub . concat $ unzip
        [ (fd, eps) | svc@(Service { s_fid = fd, s_type = CST_CONFD, s_endpoints = eps }) <- svs
                    , b || getState svc g == M0.SSOnline ]
      (rmFids, rmEps) = unzip
        [ (fd, eps) | svc@(Service { s_fid = fd, s_type = CST_RMS, s_endpoints = eps }) <- svs
                    , not (rmsHaveStarted g) || Just svc == getPrincipalRM' g
                    , G.isConnected svc Is PrincipalRM g ]
      mrmFid = listToMaybe $ nub rmFids
      mrmEp  = fmap ep2s . listToMaybe . nub $ concat rmEps
      quorum = ceiling $ fromIntegral qsize / (2::Double)
      rmsHaveStarted = maybe False (> 0) . M0.getM0BootLevelValue
  in (SpielAddress confdsFid (ep2s <$> confdsEps)) <$> mrmFid
                                                   <*> mrmEp
                                                   <*> pure quorum

-- | Get current M0Worker, return nothing if worker is not yet initilized.
getM0Worker :: IO (Maybe M0Worker)
getM0Worker = _erWorker <$> readMVar globalEndpointRef
