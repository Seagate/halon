{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies     #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
module HA.Services.Mero.RC.Actions
   ( -- * Notifications system
     mkStateDiff
   , getStateDiffByEpoch
   , markNotificationDelivered
   , markNotificationFailed
   , tryCompleteStateDiff
   , failNotificationsOnNode
   , notifyMeroAsync
   , orderSet
   ) where

import           Control.Category
import           Control.Distributed.Process
import           Control.Monad (when, unless)
import           Control.Monad.Trans.State (execState)
import qualified Control.Monad.Trans.State as State
import           Data.Foldable (for_)
import           Data.Function (on)
import           Data.List (sortBy)
import           Data.Maybe (catMaybes)
import           Data.Proxy (Proxy(..))
import           Data.Traversable (for)
import           Data.Word (Word64)
import           HA.EventQueue (promulgateWait)
import           HA.RecoveryCoordinator.Mero.Events
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.ResourceGraph as G
import           HA.ResourceGraph (Graph)
import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           HA.Service.Interface
import           HA.Services.Mero
import           HA.Services.Mero.RC.Events
import           HA.Services.Mero.RC.Resources
import           Mero.ConfC (Fid(..))
import qualified Mero.Notification
import           Mero.Notification.HAState (Note(..))
import           Network.CEP
import           Prelude hiding ((.), id)

-- | Return the set of processes that should be notified together with channels
-- that could be used for notifications.
--
-- Only 'PSOnline' processes are used as recepients for notifications:
-- starting processes should request state themselves. Stopping
-- processes shouldn't need any further updates.
getNotificationNodes :: PhaseM RC l [(R.Node, [M0.Process])]
getNotificationNodes = do
  rg <- getLocalGraph
  let nodes = [ (node, m0node)
              | host <- G.connectedTo R.Cluster R.Has rg :: [R.Host]
              , node <- G.connectedTo host R.Runs rg
              , Just m0node <- [M0.nodeToM0Node node rg]
              ]
  things <- for nodes $ \(node, m0node) -> do
     let procs = [ p | p <- G.connectedTo m0node M0.IsParentOf rg
                     , M0.getState p rg == M0.PSOnline ]
     case procs of
       [] -> return Nothing
       _ -> return $! Just (node, procs)
       -- TODO: recover service missing warning
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
  isDelivered <- G.isConnected diff DeliveredTo process <$> getLocalGraph
  isNotSent   <- G.isConnected diff ShouldDeliverTo process <$> getLocalGraph
  unless (isDelivered) $ do
    modifyGraph $ G.disconnect diff ShouldDeliverTo process
              >>> G.disconnect diff DeliveryFailedTo process -- success after failure - counts.
              >>> G.connect    diff DeliveredTo process
    when isNotSent $ tryCompleteStateDiff diff

-- | Mark any notifications that weren't already delivered and haven't
-- already failed, as failed.
markNotificationFailed :: StateDiff -> M0.Process -> PhaseM RC l ()
markNotificationFailed diff process = do
  isFailed    <- G.isConnected diff DeliveryFailedTo process <$> getLocalGraph
  isDelivered <- G.isConnected diff DeliveredTo process <$> getLocalGraph
  isNotSent   <- G.isConnected diff ShouldDeliverTo process <$> getLocalGraph
  unless (isDelivered && isFailed) $ do
    modifyGraph $ G.disconnect diff ShouldDeliverTo process
              >>> G.connect    diff DeliveryFailedTo process
    when isNotSent $ tryCompleteStateDiff diff

-- | Check if 'StateDiff' is already completed, i.e. there are no processes
-- that we are waiting for. If it's completed, we disconnect 'StateDiff' from
-- RG and announce it to halon.
--
-- Note that 'Notified' ('ruleGenericNotification') and therefore
-- 'InternalStateChangesMsg' is sent out once we have no more
-- processes to send the notification set to: this means that even if
-- we failed to send the notifications to every process, the internal
-- state change is still sent out throughout RC.
tryCompleteStateDiff :: StateDiff -> PhaseM RC l ()
tryCompleteStateDiff diff = do
  rc <- getCurrentRC
  -- If the diff is connected it means we haven't entered past the
  -- guard below yet: this ensures we only send result of
  -- notifications once.
  notSent <- G.isConnected rc R.Has diff <$> getLocalGraph
  -- Processes we haven't heard success/failure from yet
  pendingPs <- G.connectedTo diff ShouldDeliverTo <$> getLocalGraph
  phaseLog "tryCompleteStateDiff.epoch" $ show (stateEpoch diff)
  phaseLog "tryCompleteStateDiff.remaining" $ show (map M0.fid pendingPs)

  when (notSent && null (pendingPs :: [M0.Process])) $ do
    modifyGraph $ G.disconnect rc R.Has diff
    okProcesses <- G.connectedTo diff DeliveredTo <$> getLocalGraph
    failProcesses <- G.connectedTo diff DeliveryFailedTo <$> getLocalGraph
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
    for_ (G.connectedFrom ShouldDeliverTo p rg) $ \diff -> do
      modifyGraph $ G.disconnect diff ShouldDeliverTo p
                >>> G.connect    diff DeliveryFailedTo p
      -- XXX: try all nodes at once in the end. (optimization)
      tryCompleteStateDiff diff

-- | Populate a state diff with a list of mero services that halon should
-- send notification to. Only 'Online' processes on online nodes will be
-- notified. because other procesees should request state on their own.
notifyMeroAsync :: StateDiff -> Mero.Notification.Set -> PhaseM RC l ()
notifyMeroAsync diff s = do
  nodes <- getNotificationNodes
  rg <- getLocalGraph
  let iface = getInterface $ lookupM0d rg
  phaseLog "notifyMeroAsynch.epoch" $ show (stateEpoch diff)
  phaseLog "notifyMeroAsynch.nodes" $ show (map (\(n, p) -> (n, map M0.fid p)) nodes)
  for_ nodes $ \(R.Node nid, recipients) -> do
    modifyGraph $ execState $ for recipients $
      State.modify . G.connect diff ShouldDeliverTo
    registerSyncGraph $
      sendSvc iface nid . PerformNotification $!
        NotificationMessage (stateEpoch diff) (orderSet notifyOrdering s) (map M0.fid recipients)
  -- there are no processes to send notification to: no notifications
  -- will be acked or failed so we have to explicitly trigger state
  -- diff completion
  when (null nodes) $ do
    tryCompleteStateDiff diff

-- | There are cases where mero cares about the order of elements
-- inside the NVec. We impose the ordering by the first argument. See
-- 'notifyOrdering' for an example.
orderSet :: [Word64] -> Mero.Notification.Set -> Mero.Notification.Set
orderSet ordering (Mero.Notification.Set nvec q) = Mero.Notification.Set (sortBy (sorter `on` no_id) nvec) q
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
