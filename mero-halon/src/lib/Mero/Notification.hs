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

{-# OPTIONS_GHC -fno-warn-dodgy-exports #-}

module Mero.Notification
    ( Set(..)
    , Get(..)
    , GetReply(..)
    , initialize
    , finalize
    , notifyMero
    , withServerEndpoint
    ) where

import Control.Distributed.Process

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
import Control.Distributed.Process.Internal.Types ( processNode, LocalNode )
import qualified Control.Distributed.Process.Node as CH ( runProcess )
import Control.Monad ( void )
import Control.Monad.Reader ( ask )
import Data.Binary (Binary)
import Data.Hashable (Hashable)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import System.IO.Unsafe (unsafePerformIO)

import Control.Exception (SomeException)
import qualified Control.Exception as Ex (try)

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

-- | Multiple places such as mero service or confc may need a
-- 'ServerEndpoint' but currently RPC(Lite) only supports a single
-- endpoint at a time. In order to ensure we don't end up calling
-- 'initRPC' multiple times or 'finalizeRPC' while the endpoint is
-- still in use, we use a global lock.
--
-- This lock is internal to the module. All users except 'initalize'
-- and 'finalize' should use 'withServerEndpoint, 'initialize' and
-- 'finalize' themselves.
globalEndpointRef :: MVar ServerEndpoint
globalEndpointRef = unsafePerformIO newEmptyMVar
{-# NOINLINE globalEndpointRef #-}

log' = liftIO . appendFile "/tmp/log" . (++ "\n")

-- | Grab hold of a 'ServerEndpoint' and run the action on it. You
-- are required to pass in an 'RPCAddress' in case the endpoint is not
-- initialized already. Note that if the endpoint is already
-- initialized, the passed in 'RPCAddress' is __not__ used so do not
-- make any assumptions about which address the endpoint is started
-- at.
withServerEndpoint :: RPCAddress -> (ServerEndpoint -> Process a) -> Process a
withServerEndpoint addr f = log' ("wse " ++ show addr) >> initialize addr >>= (`withMVarProcess` f)
  where
    -- Note that this does *not* mask!
    withMVarProcess :: MVar a -> (a -> Process b) -> Process b
    withMVarProcess m p = do
      log' "pretake"
      x <- liftIO $ takeMVar m
      log' "posttake"
      v <- p x
      log' "postexec"
      liftIO $ putMVar m x
      log' "postput"
      return v

-- | Initialiazes the Notification subsystem. If the system has
-- already been initialized, does nothing but return the (untaken)
-- lock. It is therefore safe to call 'initialize' multiple times.
initialize :: RPCAddress -- ^ Listen address.
           -> Process (MVar ServerEndpoint)
initialize addr = log' "init" >> liftIO (tryTakeMVar globalEndpointRef) >>= \case
  Just ep -> log' "just ep" >> liftIO (putMVar globalEndpointRef ep) >> return globalEndpointRef
  Nothing -> do
    log' "init1"
    lnode <- fmap processNode ask
    self <- getSelfPid
    say $ "listening at " ++ show addr
    log' "init2"
    liftIO $ runOnGlobalM0Worker $ do
      appendFile "/tmp/log" "init3\n"
      initRPC
      appendFile "/tmp/log" "init4\n"
      ep <- listen addr listenCallbacks
      appendFile "/tmp/log" "init5\n"
      Ex.try (initHAState (ha_state_get self lnode) (ha_state_set lnode)) >>= \case
        Left a -> appendFile "/tmp/log" ("initHAState Left: " ++ show (a :: SomeException) ++ "\n")
        Right _ -> appendFile "/tmp/log" "initHAState Right!\n"
      appendFile "/tmp/log" "init6\n"
      putMVar globalEndpointRef ep
      appendFile "/tmp/log" "init7\n"
      return globalEndpointRef
  where
    listenCallbacks = ListenCallbacks {
      receive_callback = \_ _ -> return False
    }
    ha_state_get :: ProcessId -> LocalNode -> NVecRef -> IO ()
    ha_state_get parent lnode nvecr =
      CH.runProcess lnode $ void $ spawnLocal $ do
        link parent
        self <- getSelfPid
        _ <- liftIO (readNVecRef nvecr) >>= promulgate . Get self . map no_id
        GetReply nvec <- expect
        liftIO $ updateNVecRef nvecr nvec
        liftIO $ doneGet nvecr 0

    ha_state_set :: LocalNode -> NVec -> IO Int
    ha_state_set lnode nvec = do
      CH.runProcess lnode $ do
        say $ "m0d: received state vector " ++ show nvec
        void $ promulgate $ Set nvec
      return 0

-- | Finalize the Notification subsystem. We make an assumption that
-- if 'globalEndpointRef' is empty, we have already finalized before
-- and do nothing.
finalize :: Process ()
finalize = liftIO (tryTakeMVar globalEndpointRef) >>= \case
  Nothing -> return ()
  Just _ -> liftIO $ runOnGlobalM0Worker $ do
    appendFile "/tmp/log" "pre finiHAState\n"
    finiHAState
    {-
    -- XXX finalizeRPC hangs
    appendFile "/tmp/log" "pre finalizeRPC\n"
    finalizeRPC
    appendFile "/tmp/log" "post finalizeRPC\n"
    -}

notifyMero :: ServerEndpoint
           -> RPCAddress
           -> Set
           -> Process ()
notifyMero ep mero (Set nvec) = liftIO $
    runOnGlobalM0Worker (notify ep mero nvec 5)
--
