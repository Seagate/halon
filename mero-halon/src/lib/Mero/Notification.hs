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
    ) where

import Control.Distributed.Process

import Network.CEP (liftProcess, MonadProcess)

import Mero
import Mero.ConfC (Fid)
import Mero.Notification.HAState
import Mero.M0Worker
import HA.EventQueue.Producer (promulgate)
import Network.RPC.RPCLite
  ( ListenCallbacks(..)
  , RPCAddress
  , ServerEndpoint
  , initRPC
  , finalizeRPC
  , listen
  )
import Control.Concurrent.MVar
import Control.Distributed.Process.Internal.Types ( LocalNode )
import qualified Control.Distributed.Process.Node as CH ( runProcess )
import Control.Monad ( void )
import Control.Monad.Trans (MonadIO)
import Control.Monad.Catch (MonadCatch, SomeException)
import qualified Control.Monad.Catch as Catch
import Data.Binary (Binary)
import Data.Hashable (Hashable)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import System.IO.Unsafe (unsafePerformIO)

-- | This message is sent to the RC when Mero informs of a state change.
--
-- This message may be also sent by te RC when the state of an object changes
-- and the change has to be communicated to Mero.
--
newtype Set = Set NVec
        deriving (Generic, Typeable, Binary, Hashable)

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
--
-- 
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
        -- We're the last worker, someone wanted to finalize and we
        -- have the lock: just call 'finalizeInternal'.
        True -> finalizeInternal m
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
    register notificationHandlerLabel self
    onException 
      (liftM0 $ do
        initRPC
        ep <- listen addr listenCallbacks
        let ref' = emptyEndpointRef { _erServerEndpoint = Just ep }
        return (globalEndpointRef, ref', ep))
      (liftIO $ putMVar globalEndpointRef ref)
  where
    listenCallbacks = ListenCallbacks {
      receive_callback = \_ _ -> return False
    }

-- | Initializes the hastate interface in the node where it will be
-- used. Call it before @m0_init@ and before 'initialize'.
initialize_pre_m0_init :: LocalNode -> IO ()
initialize_pre_m0_init lnode = initHAState ha_state_get
                                           ha_state_set
  where
    ha_state_get :: NVecRef -> IO ()
    ha_state_get nvecr =
      CH.runProcess lnode $ void $ spawnLocal $ do
        mrc <- whereis notificationHandlerLabel
        case mrc of
          Just rc -> do
            link rc
            self <- getSelfPid
            _ <- liftIO (readNVecRef nvecr) >>= promulgate . Get self . map no_id
            GetReply nvec <- expect
            liftIO $ updateNVecRef nvecr nvec
            liftIO $ doneGet nvecr 0
          Nothing ->
            say "notification interface callbacks: unknown RC."

    ha_state_set :: NVec -> IO Int
    ha_state_set nvec = do
      CH.runProcess lnode $ do
        say $ "m0d: received state vector " ++ show nvec
        void $ promulgate $ Set nvec
      return 0

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
finalizeInternal m = sendM0Task $ do
  finiHAState
  finalizeRPC
  putMVar m emptyEndpointRef

-- | Finalize the Notification subsystem. We make an assumption that
-- if 'globalEndpointRef' is empty, we have already finalized before
-- and do nothing.
finalize :: Process ()
finalize = liftIO $ takeMVar globalEndpointRef >>= \case
  -- if we have no further workers active, just finalize and fill the
  -- MVar with 'emptyEndpointRef'
  ref | _erRefCount ref <= 0 -> finalizeInternal globalEndpointRef
  -- There are some workers active so just signal that we want to
  -- finalize and put the MVar back. Once the last worker finishes, it
  -- will check this flag and run the finalization itself
      | otherwise -> putMVar globalEndpointRef $ ref { _erWantsFinalize = True }


notifyMero :: ServerEndpoint
           -> RPCAddress
           -> Set
           -> Process ()
notifyMero ep mero (Set nvec) = liftIO $
    sendM0Task (notify ep mero nvec 5)
