-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
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
  , syncGraphBlocking
  , syncGraphProcess
  , syncGraphProcessMsg
  , knownResource
  , registerNode
    -- * Communication with the EQ
  , messageProcessed
  , selfMessage
  , promulgateRC
  , unsafePromulgateRC
    -- * Multi-receiver messages
    -- $multi-receiver
  , todo
  , done
  , defineSimpleTask
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
import HA.EventQueue.Producer (promulgateWait)
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
  , newChan
  , receiveChan
  , say
  , sendChan
  , getSelfPid
  , spawnLocal
  , link
#ifdef USE_MERO
  , liftIO
#endif
  )
import Control.Monad (when, unless)
import Control.Distributed.Process.Serializable
#ifdef USE_MERO
import Mero.Notification (Set)
import Mero.M0Worker
#endif

import Data.Functor (void)
import qualified Data.Map.Strict as Map

import Network.CEP

data LoopState = LoopState {
    lsGraph    :: G.Graph -- ^ Graph
  , lsFailMap  :: Map.Map (ServiceName, Node) Int
    -- ^ Failed reconfiguration count
  , lsMMChan   :: StoreChan -- ^ Replicated Multimap channel
  , lsEQPid    :: ProcessId -- ^ EQ pid
  , lsRefCount :: Map.Map UUID Int
    -- ^ Set of HAEvent uuid we've already handled.
#ifdef USE_MERO
  , lsStateChangeHandlers :: forall l. [Set -> PhaseM LoopState l ()]
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

-- | Sync the graph and block the caller until this is complete. This
--   internally uses a wait for a hidden message type.
syncGraphBlocking :: PhaseM LoopState l ()
syncGraphBlocking = modifyLocalGraph $ \rg -> liftProcess $ do
  (sp, rp) <- newChan
  G.sync rg (sendChan sp ()) <* receiveChan rp

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


-- | Lifted wrapper over 'HA.Event.Queue.Producer.promulgate' call. 'promulgateRC'
-- should be called in case when RC should send a message to itself, but this message
-- should be guaranteed to be persisted. This call is blocking RC, so if message can't
-- be persisted then RC will not continue processing neither this nor other rules.
-- However main EQ node should be collocated with RC, this means that the only case
-- when 'promulgateRC' could be blocked is when there is no quorum. In such case RC
-- anyway should be killed, and it's better to stop as soon as possible.
-- Promulgate call will be cancelled if RC thread will receive an exception.
--
-- However, 'promulgateRC' introduces additional synchronization overhead in normal
-- case, so on a fast-path 'unsafePromulgateRC' could be used.
promulgateRC :: Serializable msg => msg -> PhaseM LoopState l ()
promulgateRC msg = liftProcess $ promulgateWait msg

-- | Fast-path 'promulgateRC', this call is not blocking call, so there is no guarantees
-- of message to be persisted when RC exit 'unsafePromulgateRC' call. This call is much
-- more efficient in a normal case, because different promulgate calls could be run in
-- parallel and make use of replicated-log batching, however in order to survive failures,
-- programmer should handle those cases explicitly.
--
-- In order to provide an action that will be triggered after message was persisten
-- callback could be set.
--
-- Promulgate call will be cancelled if RC thread that emitted call will die.
unsafePromulgateRC :: Serializable msg => msg -> Process () -> PhaseM LoopState l ()
unsafePromulgateRC msg callback = liftProcess $ do
   self <- getSelfPid
   void $ spawnLocal $ do
     link self
     promulgateWait msg
     callback

-- $multi-receiver
-- Sometimes message may be wanted by many rules, in that case, it's not correct to
-- acknowledge message processing until all rules have processed message. In order to
-- solve that 'todo'/'done' framework was added. It allow to mark message as needed,
-- and message will be acknowledged only when all rules have processed that message.
--
-- Currently there is a caveat because of possible race condition between rule marking
-- message as 'done' and another 'rule' that is marking message as 'todo'. In order to
-- make partially remove this race following rule was introduced:
--   * Message is acknowledged if no rule is interested in message (all rules that call
--     'todo' called 'done' also) and there were enough steps done, currently 10.
--
-- This means that race is still possible and message can be already acknowledged if
-- another rule read have to big gap befoe starting work with message.

-- |
-- Mark message as in process. This will guarantee that another rule will not
-- process this message before current rule will call 'done'.
todo :: UUID -> PhaseM LoopState l ()
todo uuid = do
  st <- get Global
  put Global st{ lsRefCount = Map.insertWith add uuid 1 (lsRefCount st)}
  where
    add old new
      | old < 0 = new
      | otherwise = old + new

-- |
-- Mark message as being processed. After this call RC could acknowledge message.
-- Mesage will be acknowledged only when there were same number of 'done's as
-- were 'todo's, and some time gap was given.
done :: UUID -> PhaseM LoopState l ()
done uuid = do
  st <- get Global
  put Global st{ lsRefCount = Map.insertWith (flip (-)) uuid 1 (lsRefCount st)}

-- | Wrap rule in 'todo' and 'done' calls
defineSimpleTask :: Serializable a
                 => String
                 -> (forall l . HAEvent a -> PhaseM LoopState l ())
                 -> Specification LoopState ()
defineSimpleTask n f = defineSimple n $ \a@(HAEvent uuid _ _) ->
   todo uuid >> f a >> done uuid
