{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE MonoLocalBinds #-}

-- |
-- Module    : HA.RecoveryCoordinator.Actions.Core
-- Copyright : (C) 2015-2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- XXX: write module level documentation
module HA.RecoveryCoordinator.RC.Actions.Core
  ( RC
    -- * Manipulating LoopState
  , LoopState(..)
  , getGraph
  , liftGraph
  , liftGraph2
  , putGraph
  , modifyGraph
  , modifyGraphM
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
    -- ** Helpers for Set
  , insertStorageSetRC
  , memberStorageSetRC
  , deleteStorageSetRC
    -- ** Helpers for Map
  , insertWithStorageMapRC
  , memberStorageMapRC
  , deleteStorageMapRC
  , lookupStorageMapRC
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
  , setPhaseIfConsume
    -- * Lifted functions in PhaseM
  , decodeMsg
  , sendMsg
    -- * Utility functions
  , sayRC
  , unlessM
  , whenM
  , mkLoop
    -- * Predefined accessor fields.
  , fldUUID
  , FldUUID
  ) where

import           Control.Distributed.Process
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
import           Control.Distributed.Process.Serializable
import           Control.Monad (when, unless, (<=<))
import           Data.Functor (void)
import qualified Data.Map.Strict as Map
import           Data.Maybe (fromMaybe)
import           Data.Proxy
import qualified Data.Set as Set
import           Data.Typeable (Typeable)
import           Data.UUID (UUID)
import           HA.Encode (ProcessEncode(..), decodeP)
import           HA.EventQueue (HAEvent(..), promulgateWait)
import           HA.Multimap (StoreChan)
import           HA.RecoveryCoordinator.RC.Application
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.RecoveryCoordinator.RC.Internal.Storage as Storage
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..), Has(..), Node)
import           HA.SafeCopy
import           Network.CEP

-- | Get value from non-peristent global storage.
getStorageRC :: Typeable a => PhaseM RC l (Maybe a)
getStorageRC = Storage.get . lsStorage <$> get Global

-- | Put value to non-persistent global storage. For entry is indexed by it's
-- 'TypeRep' so it's possible to keep only one value of each type in storage.
putStorageRC :: Typeable a => a -> PhaseM RC l ()
putStorageRC x = modify Global $ \g -> g{lsStorage = Storage.put x $ lsStorage g}

-- | Delete value from the ephemeral storage.
deleteStorageRC :: Typeable a => Proxy a -> PhaseM RC l ()
deleteStorageRC p = modify Global $ \g -> g{lsStorage = Storage.delete p $ lsStorage g}

-- | Put value in in global, ephemeral storage.
insertStorageSetRC :: (Typeable a, Ord a) => a -> PhaseM RC l ()
insertStorageSetRC x = modify Global $ \g -> do
  case Storage.get (lsStorage g) of
    Nothing -> g{lsStorage = Storage.put (Set.singleton x) $ lsStorage g}
    Just z  -> g{lsStorage = Storage.put (Set.insert x z)  $ lsStorage g}

-- | Is the given value in global, ephemeral storage?
memberStorageSetRC :: (Typeable a, Ord a) => a -> PhaseM RC l Bool
memberStorageSetRC x = do
   maybe False (Set.member x) . Storage.get . lsStorage <$> get Global

-- | Delete the value from the ephemeral storage.
deleteStorageSetRC :: (Typeable a, Ord a) => a -> PhaseM RC l ()
deleteStorageSetRC x = modify Global $ \g -> do
  case Storage.get (lsStorage g) of
    Nothing -> g
    Just z  -> g{lsStorage = Storage.put (Set.delete x z)  $ lsStorage g}

-- | Helper that wraps. 'Data.Map.member' for map kept in Storage.
memberStorageMapRC :: forall proxy k v l . (Typeable k, Typeable v, Ord k)
                   => proxy v -> k -> PhaseM RC l Bool
memberStorageMapRC _ x =
  maybe False (\m -> Map.member x (m :: Map.Map k v))
    . Storage.get . lsStorage <$> get Global

-- | 'Map.insertWith' into a 'Map' inside ephemeral 'Storage'.
insertWithStorageMapRC :: (Typeable k, Typeable v, Ord k)
                       => (v -> v -> v) -> k -> v -> PhaseM RC l ()
insertWithStorageMapRC f k v = modify Global $ \g -> do
  let z = fromMaybe Map.empty $ Storage.get (lsStorage g)
  g{lsStorage = Storage.put (Map.insertWith f k v z) $ lsStorage g}

-- | Delete a map of given types from the ephemeral storage.
deleteStorageMapRC :: forall proxy k v l . (Typeable k, Typeable v, Ord k)
                   => proxy v -> k -> PhaseM RC l ()
deleteStorageMapRC _ x = modify Global $ \g -> do
  case Storage.get (lsStorage g) of
    Nothing -> g
    Just (z::Map.Map k v) -> g{lsStorage = Storage.put (Map.delete x z)  $ lsStorage g}

-- | Lookup a value store inside the a 'Map' inside ephemeral storage.
lookupStorageMapRC :: forall k v l . (Typeable k, Typeable v, Ord k)
                   => k -> PhaseM RC l (Maybe v)
lookupStorageMapRC x =
  ((\m -> Map.lookup x (m :: Map.Map k v))
    <=< Storage.get . lsStorage) <$> get Global

-- | Is a given resource existent in the RG?
knownResource :: G.Resource a => a -> PhaseM RC l Bool
knownResource res = G.memberResource res <$> getGraph

-- | Register a new satellite node in the cluster.
registerNode :: Node -> PhaseM RC l ()
registerNode node = do
  Log.rcLog' Log.DEBUG $ "Registering satellite node: " ++ show node
  modifyGraph $ G.connect Cluster Has node

-- | Retrieve the Resource 'G.Graph' from the 'Global' state.
getGraph :: PhaseM RC l G.Graph
getGraph = lsGraph <$> get Global

-- | Take a pure operation requiring a graph as its last argument and lift
--   it into a phase operation which gets the graph from local state.
liftGraph :: (a -> G.Graph -> b) -> a -> PhaseM RC l b
liftGraph op a = op a <$> getGraph

-- | Take a pure operation requiring a graph as its last argument and lift
--   it into a phase operation which gets the graph from local state.
liftGraph2 :: (a -> c -> G.Graph -> b) -> a -> c -> PhaseM RC l b
liftGraph2 op = \a c -> op a c <$> getGraph

-- | Update the RG in the global state.
putGraph :: G.Graph -> PhaseM RC l ()
putGraph rg = modify Global $ \ls -> ls { lsGraph = rg }

-- | Modify the RG in the global state.
modifyGraph :: (G.Graph -> G.Graph) -> PhaseM RC l ()
modifyGraph k = modifyGraphM $ return . k

-- | Modify the RG in the global state using provided action.
modifyGraphM :: (G.Graph -> PhaseM RC l G.Graph) -> PhaseM RC l ()
modifyGraphM k = putGraph =<< k =<< getGraph

-- | Explicitly syncs the graph to all replicas. When graph will be
-- synchronized callback will be called.
-- Callback will block multimap process so only fast calls, that do
-- not throw exceptions should be used there.
registerSyncGraph :: Process () -> PhaseM RC l ()
registerSyncGraph callback = modifyGraphM $ \rg ->
  liftProcess $ G.sync rg callback

-- | Sync the graph and block the caller until this is complete. This
--   internally uses a wait for a hidden message type.
syncGraphBlocking :: PhaseM RC l ()
syncGraphBlocking = modifyGraphM $ \rg -> liftProcess $ do
  (sp, rp) <- newChan
  G.sync rg (sendChan sp ()) <* receiveChan rp

-- | 'syncGraph' wrapper that will notify EQ about message beign processed.
-- This wrapper could be used then graph synchronization is a last command
-- before commiting a graph.
registerSyncGraphProcessMsg :: UUID -> PhaseM RC l ()
registerSyncGraphProcessMsg uuid = do
  eqPid <- lsEQPid <$> get Global
  registerSyncGraph $ liftProcess (usend eqPid uuid)

-- | 'syncGraph' helper that passes current process id to the callback.
-- This method could be used when you want to send message to itself
-- in a callback.
registerSyncGraphProcess :: (ProcessId -> Process ()) -> PhaseM RC l ()
registerSyncGraphProcess action = do
  self <- liftProcess $ getSelfPid
  registerSyncGraph $ liftProcess (action self)

-- | 'syncGraph' helper that passes current process id and action to process
-- messages.
registerSyncGraphCallback :: (ProcessId -> (UUID -> Process ()) -> Process ()) -> PhaseM RC l ()
registerSyncGraphCallback action = do
  self  <- liftProcess getSelfPid
  eqPid <- lsEQPid <$> get Global
  registerSyncGraph $ action self (usend eqPid)

-- | Declare that we have finished handling a message to the EQ, meaning it can
--   delete it.
messageProcessed :: UUID -> PhaseM RC l ()
messageProcessed uuid = do
  eqPid <- lsEQPid <$> get Global
  liftProcess $ usend eqPid uuid

-- | Create function that will process message and can be called from
-- 'Process' context, is useful for marking message as processed from
-- spawned threads.
mkMessageProcessed :: PhaseM RC l (UUID -> Process ())
mkMessageProcessed = do
  eqPid <- lsEQPid <$> get Global
  return $ usend eqPid

-- | 'say' prefixed with RC header.
sayRC :: String -> Process ()
sayRC s = say $ "Recovery Coordinator: " ++ s

-- | 'when' over bool-producing action.
whenM :: Monad m => m Bool -> m () -> m ()
whenM cond act = cond >>= flip when act

-- | 'unless' over bool-producing action.
unlessM :: Monad m => m Bool -> m () -> m ()
unlessM cond act = cond >>= flip unless act

-- | Send message to RC. This message is sent bypassing event queue, this means
-- that message will be receive by RC as soon as possible without any overhead.
-- However such messages are not persisted thus will not be resend upon RC failure.
-- N.B. Because messages are send bypassing replicated storage they do not have 'HAEvent'
-- wrapper around them so rules should catch pure types, not 'HAEvent'.
selfMessage :: Serializable a => a -> PhaseM RC l ()
selfMessage msg = liftProcess $ do
  pid <- getSelfPid
  usend pid msg

-- | Lifted version of @send@ to @PhaseM@.
sendMsg :: Serializable a => ProcessId -> a -> PhaseM g l ()
sendMsg pid a = liftProcess $ usend pid a

-- | Lifted version of @decodeP@
decodeMsg :: ProcessEncode a => BinRep a -> PhaseM g l a
decodeMsg = liftProcess . decodeP

-- | Get the 'StoreChan' for the multimap replicating the graph.
getMultimapChan :: PhaseM RC l StoreChan
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
promulgateRC :: (MonadProcess m, SafeCopy msg, Typeable msg) => msg -> m ()
promulgateRC = liftProcess . promulgateWait

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
unsafePromulgateRC :: (SafeCopy msg, Typeable msg) => msg -> Process () -> PhaseM RC l ()
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
todo :: UUID -> PhaseM RC l ()
todo uuid = do
  Log.sysLog' $ Log.Todo uuid
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
done :: UUID -> PhaseM RC l ()
done uuid = do
  Log.sysLog' $ Log.Done uuid
  st <- get Global
  put Global st{ lsRefCount = Map.adjust (\x -> x - 1) uuid (lsRefCount st)}

-- | Check if no rule is already working on this message. Returns event if no
-- other rule is processing it, or processed not longer than 10 steps ago,
-- othwewise returns @Nothing@. This method is intended to be as a predicate
-- in 'setPhaseIf' family of functions.
isNotHandled :: HAEvent a -> LoopState -> l -> Process (Maybe (HAEvent a))
isNotHandled evt@(HAEvent eid _) ls _
    | Map.member eid $ lsRefCount ls = return Nothing
    | otherwise = return $ Just evt

-- | Wrap rule in 'todo' and 'done' calls. User should not mark message as
-- processed on it's own.
defineSimpleTask :: (SafeCopy a, Serializable a)
                 => String
                 -> (forall l . a -> PhaseM RC l ())
                 -> Definitions RC ()
defineSimpleTask n f = defineSimple n $ \(HAEvent uuid a) ->
   todo uuid >> f a >> done uuid

-- | Variant on `setPhaseIf` which will consume the message if it's not
--   needed. Messages are consumed using 'todo' and 'done' so should be
--   available for other rules.
--   Note that if the message passes the guard, `todo` will already have been
--   called.
setPhaseIfConsume :: (SafeCopy a, Serializable a)
                  => Jump PhaseHandle
                  -> (HAEvent a -> LoopState -> l -> Process (Maybe b))
                  -> (b -> PhaseM RC l ())
                  -> RuleM RC l ()
setPhaseIfConsume handle guard phase = setPhase handle $
  \msg@(HAEvent eid _) -> do
    todo eid
    g <- get Global
    l <- get Local
    liftProcess (guard msg g l) >>= \case
      Just b -> phase b
      Nothing -> done eid

-- | Notify about event. This event will be sent to the internal rules
-- in addition it will be broadcasted to all external listeners as
-- 'Published a'.
notify :: (Serializable a, Show a)
       => a
       -> PhaseM RC l ()
notify msg = do
  Log.rcLog' Log.DEBUG $ show msg
  selfMessage msg
  publish msg

-- | Handle incomming events in a loop.
mkLoop :: Serializable a
       => String
       -- ^ Rule name suffix.
       -> PhaseM RC l [Jump PhaseHandle]
       -- ^ Extra phases to 'switch' to along with message handler.
       -- For example, you can pass in @['timeout' t timeout_phase]@
       -- to fire @timeout_phase@ if @t@ seconds or more have passed
       -- since the last interesting message was received.
       -> (a -> l -> PhaseM RC l (Either (Jump PhaseHandle) l))
       -- ^ State update function.
       -> PhaseM RC l (Maybe [Jump PhaseHandle])
       -- ^ Check if loop is finished.
       -> RuleM RC l (Jump PhaseHandle)
mkLoop name extraPhases update check = do
  check_init <- phaseHandle $ "_loop:precheck:" ++ name
  loop <- phaseHandle $ "_loop:entry:" ++ name
  inner <- phaseHandle $ "_loop:inner:" ++ name

  -- Run a check at very first invocation: maybe we're finished
  -- straight away and no messages will actually come. Don't want to
  -- get stuck in that scenario so just finish early.
  directly check_init $ do
    check >>= maybe (continue loop) switch

  directly loop $ do
    phs <- extraPhases
    switch $ inner : phs
  setPhase inner $ \x -> do
    l <- get Local
    ex <- update x l
    case ex of
      Right l' -> do put Local l'
                     mph <- check
                     maybe (continue loop) switch mph
      Left e -> continue e
  return check_init

-- | Field containing Message UUID.
type FldUUID = '("uuid", Maybe UUID)

-- | Message UUID
fldUUID :: Proxy FldUUID
fldUUID = Proxy
