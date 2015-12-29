-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE CPP                        #-}

module HA.RecoveryCoordinator.Actions.Core
  ( -- * Manipulating LoopState
    LoopState(..)
  , getLocalGraph
  , putLocalGraph
  , modifyGraph
  , modifyLocalGraph
    -- * Operating on the graph
  , getMultimapChan
  , syncGraph
  , syncGraphProcess
  , syncGraphProcessMsg
  , knownResource
  , registerNode
    -- * Communication with the EQ
  , messageProcessed
  , selfMessage
    -- * Lifted functions in PhaseM
  , decodeMsg
  , getSelfProcessId
  , sayRC
  , sendMsg
    -- * Utility functions
  , unlessM
  , whenM
#ifdef USE_MERO
    -- * M0 related core actions.
  , liftM0RC
#endif
  ) where

import HA.Multimap (StoreChan)
import qualified HA.ResourceGraph as G
import HA.Resources
  ( Cluster(..)
  , Has(..)
  , Node
  )

import HA.EventQueue.Types
import HA.Service
  ( ProcessEncode(..)
  , ServiceName(..)
  , decodeP
  )


import Control.Category ((>>>))
import Control.Distributed.Process
  ( ProcessId
  , Process
  , usend
  , say
  , getSelfPid
#ifdef USE_MERO
  , liftIO
#endif
  )
import Control.Monad (when, unless)
import Control.Distributed.Process.Serializable
#ifdef USE_MERO
import Mero.M0Worker
#endif

import qualified Data.Map.Strict as Map
import qualified Data.Set        as S

import Network.CEP

data LoopState = LoopState {
    lsGraph    :: G.Graph -- ^ Graph
  , lsFailMap  :: Map.Map (ServiceName, Node) Int
    -- ^ Failed reconfiguration count
  , lsMMChan   :: StoreChan -- ^ Replicated Multimap channel
  , lsEQPid    :: ProcessId -- ^ EQ pid
  , lsHandled  :: S.Set UUID
    -- ^ Set of HAEvent uuid we've already handled.
#ifdef USE_MERO
  , lsWorker   :: M0Worker  -- ^ M0 worker thread attached to RC.
#endif
}

-- | Is a given resource existent in the RG?
knownResource :: G.Resource a => a -> PhaseM LoopState l Bool
knownResource res = fmap (G.memberResource res) getLocalGraph

-- | Register a new satellite node in the cluster.
registerNode :: Node -> PhaseM LoopState l ()
registerNode node = modifyLocalGraph $ \rg -> do
    phaseLog "rg" $ "Registering satellite node: " ++ show node

    let rg' = G.newResource node >>>
              G.connect Cluster Has node $ rg

    return rg'

getLocalGraph :: PhaseM LoopState l G.Graph
getLocalGraph = fmap lsGraph $ get Global

putLocalGraph :: G.Graph -> PhaseM LoopState l ()
putLocalGraph rg = modify Global $ \ls -> ls { lsGraph = rg }

modifyGraph :: (G.Graph -> G.Graph) -> PhaseM LoopState l ()
modifyGraph k = modifyLocalGraph $ return . k

modifyLocalGraph :: (G.Graph -> PhaseM LoopState l G.Graph) -> PhaseM LoopState l ()
modifyLocalGraph k = do
    rg  <- getLocalGraph
    rg' <- k rg
    putLocalGraph rg'

-- | Explicitly syncs the graph to all replicas. When graph will be
-- synchronized callback will be called.
-- Callback will block multimap process so only fast calls, that do
-- not throw exceptions should be used there.
syncGraph :: Process () -> PhaseM LoopState l ()
syncGraph callback = modifyLocalGraph $ \rg ->
  liftProcess $ G.sync rg callback

-- | 'syncGraph' wrapper that will notify EQ about message beign processed.
-- This wrapper could be used then graph synchronization is a last command
-- before commiting a graph.
syncGraphProcessMsg :: UUID -> PhaseM LoopState l ()
syncGraphProcessMsg uuid = do
  eqPid <- lsEQPid <$> get Global
  syncGraph $ liftProcess (usend eqPid uuid)

-- | 'syncGraph' helper that passes current process id to the callback.
-- This method could be used when you want to send message to itself
-- in a callback.
syncGraphProcess :: (ProcessId -> Process ()) -> PhaseM LoopState l ()
syncGraphProcess action = do
  self <- liftProcess $ getSelfPid
  syncGraph $ liftProcess (action self)

-- | Declare that we have finished handling a message to the EQ, meaning it can
--   delete it.
messageProcessed :: UUID -> PhaseM LoopState l ()
messageProcessed uuid = do
  phaseLog "eq" $ unwords ["Removing message", show uuid, "from EQ."]
  eqPid <- lsEQPid <$> get Global
  liftProcess $ usend eqPid uuid

sayRC :: String -> Process ()
sayRC s = say $ "Recovery Coordinator: " ++ s

whenM :: Monad m => m Bool -> m () -> m ()
whenM cond act = cond >>= flip when act

unlessM :: Monad m => m Bool -> m () -> m ()
unlessM cond act = cond >>= flip unless act

-- | Send message to RC. This message is sent bypassing event queue, this means
-- that message will be receive by RC as soon as possible without any overhead.
-- However such messages are not persisted thus will not be resend upon RC failure.
-- N.B. Because messages are send bypassing replicated storage they do not have 'HAEvent'
-- wrapper around them so rules should catch pure types, not 'HAEvent'.
selfMessage :: Serializable a => a -> PhaseM LoopState l ()
selfMessage msg = liftProcess $ do
  pid <- getSelfPid
  usend pid msg

-- | Lifted version of @send@ to @PhaseM@.
sendMsg :: Serializable a => ProcessId -> a -> PhaseM g l ()
sendMsg pid a = liftProcess $ usend pid a

-- | Lifted version of @decodeP@
decodeMsg :: ProcessEncode a => BinRep a -> PhaseM g l a
decodeMsg = liftProcess . decodeP

getSelfProcessId :: PhaseM g l ProcessId
getSelfProcessId = liftProcess getSelfPid

-- | Get the 'StoreChan' for the multimap replicating the graph.
getMultimapChan :: PhaseM LoopState l StoreChan
getMultimapChan = fmap lsMMChan $ get Global

#ifdef USE_MERO
-- | Run the given computation in the m0 thread dedicated to the RC.
--
-- Some operations the RC submits cannot use the global m0 worker ('liftGlobalM0') because
-- they would require grabbing the global m0 worker a second time thus blocking the application.
-- Currently, these are spiel operations which use the notification interface before returning
-- control to the caller.
liftM0RC :: IO a -> PhaseM LoopState l a
liftM0RC task = do
  worker <- fmap lsWorker (get Global)
  liftIO $ runOnM0Worker worker task
#endif
