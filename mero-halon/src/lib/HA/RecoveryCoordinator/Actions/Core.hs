{-# LANGUAGE RankNTypes                 #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- XXX: write module level documentation
module HA.RecoveryCoordinator.Actions.Core
  ( -- * Manipulating LoopState
    LoopState(..)
  , getLocalGraph
  , putLocalGraph
  , modifyGraph
  , modifyLocalGraph
    -- * Operating on the graph
  , getMultimapChan
  , syncGraphBlocking
  , registerSyncGraph
  , registerSyncGraphProcess
  , registerSyncGraphCallback
  , registerSyncGraphProcessMsg
  , knownResource
  , registerNode
    -- * Operations on ephimeral state
  , putStorageRC
  , getStorageRC
  , deleteStorageRC
  , insertStorageSetRC
  , memberStorageSetRC
  , deleteStorageSetRC
    -- * Communication with the EQ
  , messageProcessed
  , mkMessageProcessed
  , selfMessage
  , promulgateRC
  , unsafePromulgateRC
    -- * Event handling mechanism
  , notify
    -- * Multi-receiver messages
    -- $multi-receiver
  , todo
  , done
  , isNotHandled
  , defineSimpleTask
    -- * Lifted functions in PhaseM
  , decodeMsg
  , getSelfProcessId
  , sayRC
  , sendMsg
    -- * Utility functions
  , unlessM
  , whenM
  , mkLoop
  ) where

import HA.Multimap (StoreChan)
import qualified HA.ResourceGraph as G
import HA.Resources
  ( Cluster(..)
  , Has(..)
  , Node
  )

import qualified HA.RecoveryCoordinator.Actions.Storage as Storage
import HA.EventQueue.Types
import HA.EventQueue.Producer (promulgateWait)
import HA.Encode
  ( ProcessEncode(..)
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
  )
import Control.Monad (when, unless)
import Control.Distributed.Process.Serializable

import Data.Typeable (Typeable)
import Data.Functor (void)
import Data.Proxy
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import Network.CEP

data LoopState = LoopState {
    lsGraph    :: G.Graph -- ^ Graph
  , lsMMChan   :: StoreChan -- ^ Replicated Multimap channel
  , lsEQPid    :: ProcessId -- ^ EQ pid
  , lsRefCount :: Map.Map UUID Int
    -- ^ Set of HAEvent uuid we've already handled.
  , lsStorage :: !Storage.Storage -- ^ Global ephimeral storage.
}

-- | Get value from non-peristent global storage.
getStorageRC :: Typeable a => PhaseM LoopState l (Maybe a)
getStorageRC = Storage.get . lsStorage <$> get Global

-- | Put value to non-persistent global storage. For entry is indexed by it's
-- 'TypeRep' so it's possible to keep only one value of each type in storage.
putStorageRC :: Typeable a => a -> PhaseM LoopState l ()
putStorageRC x = modify Global $ \g -> g{lsStorage = Storage.put x $ lsStorage g}

-- | Delete value from non-peristent global storage.
deleteStorageRC :: Typeable a => Proxy a -> PhaseM LoopState l ()
deleteStorageRC p = modify Global $ \g -> g{lsStorage = Storage.delete p $ lsStorage g}

insertStorageSetRC :: (Typeable a, Ord a) => a -> PhaseM LoopState l ()
insertStorageSetRC x = modify Global $ \g -> do
  case Storage.get (lsStorage g) of
    Nothing -> g{lsStorage = Storage.put (Set.singleton x) $ lsStorage g}
    Just z  -> g{lsStorage = Storage.put (Set.insert x z)  $ lsStorage g}

memberStorageSetRC :: (Typeable a, Ord a) => a -> PhaseM LoopState l Bool
memberStorageSetRC x = do
   maybe False (Set.member x) . Storage.get . lsStorage <$> get Global

deleteStorageSetRC :: (Typeable a, Ord a) => a -> PhaseM LoopState l ()
deleteStorageSetRC x = modify Global $ \g -> do
  case Storage.get (lsStorage g) of
    Nothing -> g
    Just z  -> g{lsStorage = Storage.put (Set.delete x z)  $ lsStorage g}

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
registerSyncGraph :: Process () -> PhaseM LoopState l ()
registerSyncGraph callback = modifyLocalGraph $ \rg ->
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
registerSyncGraphProcessMsg :: UUID -> PhaseM LoopState l ()
registerSyncGraphProcessMsg uuid = do
  eqPid <- lsEQPid <$> get Global
  registerSyncGraph $ liftProcess (usend eqPid uuid)

-- | 'syncGraph' helper that passes current process id to the callback.
-- This method could be used when you want to send message to itself
-- in a callback.
registerSyncGraphProcess :: (ProcessId -> Process ()) -> PhaseM LoopState l ()
registerSyncGraphProcess action = do
  self <- liftProcess $ getSelfPid
  registerSyncGraph $ liftProcess (action self)

-- | 'syncGraph' helper that passes current process id and action to process
-- messages.
registerSyncGraphCallback :: (ProcessId -> (UUID -> Process ()) -> Process ()) -> PhaseM LoopState l ()
registerSyncGraphCallback action = do
  self  <- liftProcess getSelfPid
  eqPid <- lsEQPid <$> get Global
  registerSyncGraph $ action self (usend eqPid)

-- | Declare that we have finished handling a message to the EQ, meaning it can
--   delete it.
messageProcessed :: UUID -> PhaseM LoopState l ()
messageProcessed uuid = do
  eqPid <- lsEQPid <$> get Global
  liftProcess $ usend eqPid uuid

-- | Create function that will process message and can be called from
-- 'Process' context, is useful for marking message as processed from
-- spawned threads.
mkMessageProcessed :: PhaseM LoopState l (UUID -> Process ())
mkMessageProcessed = do
  eqPid <- lsEQPid <$> get Global
  return $ usend eqPid

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
-- solve that 'todo'/'done' framework was added. It allows marking message as needed
-- by the rule such message will be acknowledged only when all interested rules have
-- processed that message.
--
-- Currently there is a caveat because of possible race condition between rule marking
-- message as 'done' and another rule that is marking message as 'todo'. In order to
-- partially remove this race following rule was introduced:
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
  put Global st{ lsRefCount = Map.adjust (\x -> x - 1) uuid (lsRefCount st)}

-- | Check if no rule is already working on this message. Returns event if no
-- other rule is processing it, or processed not longer than 10 steps ago,
-- othwewise returns @Nothing@. This method is intended to be as a predicate
-- in 'setPhaseIf' family of functions.
isNotHandled :: HAEvent a -> LoopState -> l -> Process (Maybe (HAEvent a))
isNotHandled evt@(HAEvent eid _ _) ls _
    | Map.member eid $ lsRefCount ls = return Nothing
    | otherwise = return $ Just evt

-- | Wrap rule in 'todo' and 'done' calls. User should not mark message as
-- processed on it's own.
defineSimpleTask :: Serializable a
                 => String
                 -> (forall l . a -> PhaseM LoopState l ())
                 -> Specification LoopState ()
defineSimpleTask n f = defineSimple n $ \(HAEvent uuid a _) ->
   todo uuid >> f a >> done uuid


-- | Notify about event. This event will be sent to the internal rules
-- in addition it will be broadcasted to all external listeners as
-- 'Published a'.
notify :: Serializable a
       => a
       -> PhaseM LoopState l ()
notify msg = do
  selfMessage msg
  publish msg

-- | Handle incomming events in a loop.
mkLoop :: Serializable a => String            -- ^ Rule name suffix.
       -> Int                                 -- ^ Timeout (in seconds).
       -> Jump PhaseHandle                    -- ^ Rule to jump to in case of timeout.
       -> (a -> l -> PhaseM LoopState l (Either (Jump PhaseHandle) l))
       -- ^ State update function.
       -> (l -> Maybe [Jump PhaseHandle])     -- ^ Check if loop is finished.
       -> RuleM LoopState l (Jump PhaseHandle)
mkLoop name tm tmRule update check = do
  loop <- phaseHandle $ "_loop:entry:" ++ name
  inner <- phaseHandle $ "_loop:inner:" ++ name
  directly loop $ switch [inner, timeout tm tmRule]
  setPhase inner $ \x -> do
    l <- get Local
    ex <- update x l
    case ex of
      Right l' -> do put Local l'
                     maybe (continue loop) switch (check l')
      Left e -> continue e
  return loop
