{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies     #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
module HA.Services.Mero.RC.Actions
   ( -- * Service channels
     registerChannel
   , unregisterChannel
   , meroChannel
   , meroChannels
   , unregisterMeroChannelsOn
   , lookupMeroChannelByNode
     -- * Notifications system
   , mkStateDiff
   , getStateDiffByEpoch
   , markNotificationDelivered
   , markNotificationFailed
   , getNotificationChannels
   , tryCompleteStateDiff
   , failNotificationsOnNode
   , notifyMeroAsync
   , orderSet
   ) where

-- Mero service
import           HA.Services.Mero
import           HA.Services.Mero.RC.Events
import           HA.Services.Mero.RC.Resources

-- Halon
import           HA.ResourceGraph (Graph, Resource, Relation)
import qualified HA.ResourceGraph    as G
import qualified HA.Resources        as R
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Mero   as M0
import qualified HA.Resources.Mero.Note as M0

-- RC dependencies
import HA.RecoveryCoordinator.RC.Actions
import HA.RecoveryCoordinator.RC.Actions.Log (actLog)
import HA.RecoveryCoordinator.Mero.Events

import HA.EventQueue (promulgateWait)
import Control.Distributed.Process
import Network.CEP

import qualified Mero.Notification
import Mero.Notification.HAState (Note(..))
import Mero.ConfC (Fid(..))

import Control.Category
import Control.Monad (when, unless)
import Control.Monad.Trans.State (execState)
import qualified Control.Monad.Trans.State as State
import Data.Traversable (for)
import Data.List (sortBy)
import Data.Maybe (listToMaybe, catMaybes)
import Data.Function (on)
import Data.Foldable (for_)
import Data.Word (Word64)
import Data.Proxy (Proxy(..))
import Prelude hiding ((.), id)

-- | Register new mero channel inside RG.
registerChannel :: ( Resource (TypedChannel a)
                   , Relation MeroChannel R.Node (TypedChannel a)
                   )
                => R.Node
                -> TypedChannel a
                -> PhaseM RC l ()
registerChannel node chan = modifyGraph $ G.connect node MeroChannel chan

-- | Unregister mero channel inside RG.
unregisterChannel :: forall a l proxy .
   ( Resource (TypedChannel a)
   , G.CardinalityTo MeroChannel R.Node (TypedChannel a) ~ 'G.Unbounded
   , Relation MeroChannel R.Node (TypedChannel a)
   ) => R.Node -> proxy a -> PhaseM RC l ()
unregisterChannel node _ = modifyGraph $ \rg ->
  let res = G.connectedTo node MeroChannel rg :: [TypedChannel a]
  in foldr (G.disconnect node MeroChannel) rg res

-- | Find mero channel.
meroChannel :: ( Resource (TypedChannel a)
               , G.CardinalityTo MeroChannel R.Node (TypedChannel a) ~ 'G.Unbounded
               , Relation MeroChannel R.Node (TypedChannel a)
               )
            => Graph
            -> R.Node
            -> Maybe (TypedChannel a)
meroChannel rg sp = listToMaybe $ G.connectedTo sp MeroChannel rg


-- | Fetch all Mero notification channels.
meroChannels :: R.Node -> Graph -> [TypedChannel NotificationMessage]
meroChannels node rg = G.connectedTo node MeroChannel rg

-- | Find mero channel registered on the given node.
lookupMeroChannelByNode :: R.Node -> PhaseM RC l (Maybe (TypedChannel NotificationMessage))
lookupMeroChannelByNode node = do
   rg <- getLocalGraph
   return $ listToMaybe $ G.connectedTo node MeroChannel rg

-- | Unregister all channels.
unregisterMeroChannelsOn :: R.Node -> PhaseM RC l ()
unregisterMeroChannelsOn node = do
   actLog "unregisterMeroChannelsOn" [("node", show node)]
   unregisterChannel node (Proxy :: Proxy NotificationMessage)
   unregisterChannel node (Proxy :: Proxy ProcessControlMsg)

-- | Return the set of processes that should be notified together with channels
-- that could be used for notifications.
getNotificationChannels :: PhaseM RC l [(SendPort NotificationMessage, [M0.Process])]
getNotificationChannels = do
  rg <- getLocalGraph
  let nodes = [ (node, m0node)
              | host <- G.connectedTo R.Cluster R.Has rg :: [R.Host]
              , node <- G.connectedTo host R.Runs rg
              , Just m0node <- [M0.nodeToM0Node node rg]
              ]
  things <- for nodes $ \(node, m0node) -> do
     mchan <- lookupMeroChannelByNode node
     let procs = filter (\p -> case M0.getState p rg of
                                 M0.PSOnline  -> True
                                 M0.PSStarting -> True
                                 M0.PSStopping -> True
                                 _ -> False)
               $ (G.connectedTo m0node M0.IsParentOf rg :: [M0.Process])
     case (mchan, procs) of
       (_, []) -> return Nothing
       (Nothing, r) -> do
         phaseLog "warning" $ "HA.Service.Mero.notifyMero: can't find remote service for "
                              ++ show node
                              ++ "Recipients: "
                              ++ show r
         return Nothing
       (Just (TypedChannel chan), r) -> return $ Just (chan, r)
  return $ catMaybes things

-- | Create state diff.
mkStateDiff :: (Graph -> Graph)             -- ^ Graph modification.
            -> InternalObjectStateChangeMsg -- ^ Binary form of the state updates.
            -> [OnCommit]                   -- ^ Actions to run when state will be announced.
            -> PhaseM RC l StateDiff
mkStateDiff f msg onCommit = do
  epoch <- updateEpoch
  let idx  = StateDiffIndex epoch
      diff = StateDiff epoch msg onCommit
  rc    <- getCurrentRC
  modifyGraph $ G.connect idx R.Is diff
            >>> G.connect rc R.Has diff
            >>> f
  return diff

-- | Find 'StateDiff' by it's index. This function can find not yet garbage
-- collected diff.
getStateDiffByEpoch :: Word64 -> PhaseM RC l (Maybe StateDiff)
getStateDiffByEpoch idx = G.connectedTo epoch R.Is <$> getLocalGraph
  where
    epoch = StateDiffIndex idx

-- | Mark that notification was delivered to process.
markNotificationDelivered :: StateDiff -> M0.Process -> PhaseM RC l ()
markNotificationDelivered diff process = do
  isWaiting   <- G.isConnected diff WaitingFor process <$> getLocalGraph
  isDelivered <- G.isConnected diff DeliveredTo process <$> getLocalGraph
  isNotSent   <- G.isConnected diff ShouldDeliverTo process <$> getLocalGraph
  unless (isDelivered) $ do
    modifyGraph $ G.disconnect diff WaitingFor process
              >>> G.disconnect diff ShouldDeliverTo process
              >>> G.disconnect diff DeliveryFailedTo process -- success after failure - counts.
              >>> G.connect    diff DeliveredTo process
    when (isWaiting || isNotSent) $ tryCompleteStateDiff diff

markNotificationFailed :: StateDiff -> M0.Process -> PhaseM RC l ()
markNotificationFailed diff process = do
  isWaiting   <- G.isConnected diff WaitingFor process <$> getLocalGraph
  isFailed    <- G.isConnected diff DeliveryFailedTo process <$> getLocalGraph
  isDelivered <- G.isConnected diff DeliveredTo process <$> getLocalGraph
  isNotSent   <- G.isConnected diff ShouldDeliverTo process <$> getLocalGraph
  unless (isDelivered && isFailed) $ do
    modifyGraph $ G.disconnect diff WaitingFor process
              >>> G.disconnect diff ShouldDeliverTo process
              >>> G.connect    diff DeliveryFailedTo process
    when (isWaiting || isNotSent) $ tryCompleteStateDiff diff

-- | Check if 'StateDiff' is already completed, i.e. there are no processes
-- that we are waiting for. If it's completed, we disconnect 'StateDiff' from
-- RG and announce it to halon.
tryCompleteStateDiff :: StateDiff -> PhaseM RC l ()
tryCompleteStateDiff diff = do
  rc <- getCurrentRC
  notSent <- G.isConnected rc R.Has diff <$> getLocalGraph
  ps <- G.connectedTo diff WaitingFor <$> getLocalGraph
  when (null (ps :: [M0.Process]) && notSent) $ do
    modifyGraph $ G.disconnect rc R.Has diff
    okProcesses <- G.connectedTo diff DeliveredTo <$> getLocalGraph
    failProcesses <- G.connectedTo diff WaitingFor  <$> getLocalGraph
    phaseLog "epoch" $ show (stateEpoch diff)
    registerSyncGraph $ do
      for_ (stateDiffOnCommit diff) applyOnCommit
      promulgateWait $ Notified (stateEpoch diff) (stateDiffMsg diff) okProcesses failProcesses

-- | Mark all notifications for processes on the given node as failed.
--
-- This code process node even in case if it was disconnected from cluster.
failNotificationsOnNode :: R.Node -> PhaseM RC l ()
failNotificationsOnNode node = do
  -- Find all processes on the current target node.
  ps <- (\rg ->
           [ m0process
           | Just m0node <- [M0.nodeToM0Node node rg]
           , m0process <- G.connectedTo m0node M0.IsParentOf rg :: [M0.Process]
           ])
        <$> getLocalGraph
  -- For each notification to the target process mark all notifications
  -- as failed.
  for_ ps $ \p -> do
    rg <- getLocalGraph
    let diffs = (++) <$> G.connectedFrom WaitingFor p
                     <*> G.connectedFrom ShouldDeliverTo p
                      $ rg
    for_ diffs $ \diff -> do
      modifyGraph $ G.disconnect diff WaitingFor p
                >>> G.disconnect diff ShouldDeliverTo p
                >>> G.connect    diff DeliveryFailedTo p
      -- XXX: try all nodes at once in the end. (optimization)
      tryCompleteStateDiff diff

-- | Populate a state diff with a list of mero services that halon should
-- send notification to. Only 'Online' processes on online nodes will be
-- notified. because other procesees should request state on their own.
notifyMeroAsync :: StateDiff -> Mero.Notification.Set -> PhaseM RC l ()
notifyMeroAsync diff s = do
  chans <- getNotificationChannels :: PhaseM RC l [(SendPort NotificationMessage, [M0.Process])]
  for_ chans $ \(chan, recipients) -> do
    modifyGraph $ execState $ for recipients $
      State.modify . G.connect diff ShouldDeliverTo
    registerSyncGraph $
      sendChan chan $ NotificationMessage (stateEpoch diff) (orderSet notifyOrdering s) (map M0.fid recipients)
  -- there are no processes to send notification to - just try no accomplish
  -- notification delivery.
  when (null chans) $ do
    tryCompleteStateDiff diff

-- | There are cases where mero cares about the order of elements
-- inside the NVec. We impose the ordering by the first argument. See
-- 'notifyOrdering' for an example.
orderSet :: [Word64] -> Mero.Notification.Set -> Mero.Notification.Set
orderSet ordering (Mero.Notification.Set nvec) = Mero.Notification.Set $ sortBy (sorter `on` no_id) nvec
  where
    sorter :: Fid -> Fid -> Ordering
    sorter f1 f2
      -- fids of same type, end it here without lookup
      | M0.fidToFidType f1 == M0.fidToFidType f2 = compare f1 f2
      -- we have f1 in list, check if it's in front of f2
      | M0.fidToFidType f1 `elem` ordering =
          if M0.fidToFidType f2 `elem` takeWhile (/= M0.fidToFidType f1) ordering
          then GT
          else LT
      -- f1 wasn't in the list to begin with, if f2 is then f2 > f1
      | M0.fidToFidType f2 `elem` ordering = GT
      -- neither type was interesting, just sort them however
      | otherwise = compare f1 f2


-- | Default ordering used in 'notifyMeroAsync' for 'orderSet'. The
-- fid types appearing earlier in the list take precedence over any
-- appearing later in the list which in turn take precedence over any
-- unmentioned types.
notifyOrdering :: [Word64]
notifyOrdering = [ M0.confToFidType (Proxy :: Proxy M0.Controller)
                 , M0.confToFidType (Proxy :: Proxy M0.Disk)
                 , M0.confToFidType (Proxy :: Proxy M0.SDev)
                 ]

-- | Apply on commit actions for the state diff.
applyOnCommit :: OnCommit -> Process ()
applyOnCommit _ = return ()  -- FIXME
