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

{-# OPTIONS_GHC -fno-warn-dodgy-exports #-}

module Mero.Notification
    ( Set(..)
    , Get(..)
    , GetReply(..)
    , initialize
    , finalize
    , notifyMero
    ) where

import Control.Distributed.Process

import Mero.ConfC (Fid)
import Mero.Notification.HAState
import HA.EventQueue.Producer (promulgate)
import Network.RPC.RPCLite
  ( ListenCallbacks(..)
  , RPCAddress
  , ServerEndpoint
  , initRPCAt
  , finalizeRPC
  , listen
  )
import Control.Distributed.Process.Internal.Types ( processNode, LocalNode )
import qualified Control.Distributed.Process.Node as CH ( runProcess )
import Control.Monad ( void )
import Control.Monad.Reader ( ask )
import Data.Binary (Binary)
import Data.Hashable (Hashable)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)

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

-- | Initialiazes the Notification subsystem.
initialize :: FilePath -- ^ Persistence path for RPC.
           -> RPCAddress -- ^ Listen address.
           -> Process ServerEndpoint
initialize fp addr = do
    lnode <- fmap processNode ask
    self <- getSelfPid
    liftIO $ initRPCAt fp
    ep <- liftIO $ listen "m0_halon" addr listenCallbacks
    liftIO $ initHAState (ha_state_get self lnode)
                         (ha_state_set lnode)
    return ep
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
      CH.runProcess lnode $ void $ promulgate $ Set nvec
      return 0

-- | Finalize the Notification subsystem.
finalize :: Process ()
finalize = liftIO $ finiHAState >> finalizeRPC

notifyMero :: ServerEndpoint
           -> RPCAddress
           -> Set
           -> Process ()
notifyMero ep mero (Set nvec) = liftIO $
  notify ep mero nvec 5
