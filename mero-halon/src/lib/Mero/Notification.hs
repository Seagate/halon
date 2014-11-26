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

{-# LANGUAGE CPP #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

{-# OPTIONS_GHC -fno-warn-dodgy-exports #-}

module Mero.Notification
    ( Set(..)
    , Get(..)
    , GetReply(..)
    , initialize
    , finalize
    , matchSet
    ) where

#ifdef USE_MERO
import Mero.ConfC (Fid)
import Mero.Notification.HAState
import HA.EventQueue.Producer (promulgate)
import HA.Network.Transport
import Network.RPC.RPCLite
  ( ListenCallbacks(..)
  , ServerEndpoint
  , listen
  , rpcAddress)
import Control.Distributed.Process.Internal.Types ( processNode, LocalNode )
import qualified Control.Distributed.Process.Node as CH ( runProcess )
import Control.Monad ( void )
import Control.Monad.Reader ( ask )
import Data.Binary (Binary)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)

#ifdef USE_RPC
import HA.Network.Transport
import Network.Transport.RPC (serverEndPoint)
#else
import Control.Concurrent.MVar
import System.IO.Unsafe (unsafePerformIO)
#endif

#endif

import Control.Distributed.Process


#ifdef USE_MERO

#ifndef USE_RPC
-- | Local endpoint
localRPCEndpoint :: MVar ServerEndpoint
localRPCEndpoint = unsafePerformIO $ newEmptyMVar
#endif

-- | This message is sent to the RC when Mero informs of a state change.
--
-- This message may be also sent by te RC when the state of an object changes
-- and the change has to be communicated to Mero.
--
newtype Set = Set NVec
        deriving (Generic, Typeable, Binary)

-- | This message is sent to the RC when Mero requests state data for some
-- objects.
data Get = Get ProcessId [Fid]
        deriving (Generic, Typeable)

instance Binary Get

-- | This message is sent by the RC in reply to a 'Get' message.
newtype GetReply = GetReply NVec
        deriving (Generic, Typeable, Binary)

-- | Initialiazes the Notification subsystem.
initialize :: Process ()
initialize = do
    lnode <- fmap processNode ask
    self <- getSelfPid
    liftIO $ initHAState (ha_state_get self lnode)
                         (ha_state_set lnode)
#ifndef USE_RPC
    liftIO $ do
      ep <- listen "m0_halon" addr listenCallbacks
      void $ tryPutMVar localRPCEndpoint ep
#endif
  where
#ifndef USE_RPC
    addr = rpcAddress ""
    listenCallbacks = ListenCallbacks {
      receive_callback = \_ _ -> return False
    }
#endif
    ha_state_get :: ProcessId -> LocalNode -> NVecRef -> IO ()
    ha_state_get parent lnode nvecr =
      CH.runProcess lnode $ void $ spawnLocal $ do
        link parent
        self <- getSelfPid
        liftIO (readNVecRef nvecr) >>= promulgate . Get self . map no_id
        GetReply nvec <- expect
        liftIO $ updateNVecRef nvecr nvec
        liftIO $ doneGet nvecr 0

    ha_state_set :: LocalNode -> NVec -> IO Int
    ha_state_set lnode nvec = do
      CH.runProcess lnode $ void $ promulgate $ Set nvec
      return 0

-- | Finalize the Notification subsystem.
finalize :: Process ()
finalize = liftIO finiHAState

-- | Reacts to 'Set' messages by notifying Mero.
matchSet :: Process a -> [Match a]
#ifdef USE_RPC
matchSet cont =
  [  match $ \(Set nvec) -> do
      transport <- liftIO readTransportGlobalIVar
      liftIO $ notify (serverEndPoint transport) (rpcAddress "") nvec 5
      cont
  ]
#else
matchSet cont =
  [  match $ \(Set nvec) -> do
      endPoint <- liftIO . readMVar $ localRPCEndpoint
      liftIO $ notify endPoint (rpcAddress "") nvec 5
      cont
  ]
#endif

#else

data Set
data Get
data GetReply

initialize :: Process ()
initialize = return ()

finalize :: Process ()
finalize = return ()

matchSet :: Process a -> [Match a]
matchSet _ = []

#endif
