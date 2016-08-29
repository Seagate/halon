{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -Werror #-}
module HA.Services.Mero.RC.Actions
   ( -- * Service channels
     registerChannel
   , meroChannel
   , meroChannels
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
   ) where

-- Mero service
import           HA.Services.Mero.Types
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
import HA.RecoveryCoordinator.Events.Mero

import HA.EventQueue.Producer (promulgateWait)
import HA.Service
import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Mero.Conf (nodeToM0Node)
import Control.Distributed.Process
import Network.CEP

import qualified Mero.Notification

import Control.Category
import Control.Monad (when, unless)
import Control.Monad.Trans.State (execState)
import qualified Control.Monad.Trans.State as State
import Data.Traversable (for)
import Data.Maybe (isJust, listToMaybe, catMaybes)
import Data.Foldable (for_)
import Data.Word (Word64)
import Prelude hiding ((.), id)

-- | Regisger new mero channel inside RG.
registerChannel :: ( Resource (TypedChannel a)
                   , Relation MeroChannel (ServiceProcess MeroConf) (TypedChannel a)
                   )
                => ServiceProcess MeroConf
                -> TypedChannel a
                -> PhaseM LoopState l ()
registerChannel sp chan =
  modifyGraph $ G.newResource sp
            >>> G.newResource chan
            >>> G.connectUniqueTo sp MeroChannel chan

-- | Find mero channel.
meroChannel :: ( Resource (TypedChannel a)
               , Relation MeroChannel (ServiceProcess MeroConf) (TypedChannel a)
               )
            => Graph
            -> ServiceProcess MeroConf
            -> Maybe (TypedChannel a)
meroChannel rg sp = listToMaybe [ chan | chan <- G.connectedTo sp MeroChannel rg ]


-- | Fetch all Mero notification channels.
meroChannels :: Service MeroConf -> Graph -> [TypedChannel NotificationMessage]
meroChannels m0d rg =
  [ chan
  | node <- G.connectedTo R.Cluster R.Has rg
  , isJust $ runningService node m0d rg
  , sp   <- G.connectedTo node R.Runs rg :: [ServiceProcess MeroConf]
  , chan <- G.connectedTo sp MeroChannel rg ]

-- | Find mero channel registered on the given node.
lookupMeroChannelByNode :: R.Node -> PhaseM LoopState l (Maybe (TypedChannel NotificationMessage))
lookupMeroChannelByNode node = do
   rg <- getLocalGraph
   let mlchan = listToMaybe
         [ chan | sp   <- G.connectedTo node R.Runs rg :: [ServiceProcess MeroConf]
                , chan <- G.connectedTo sp MeroChannel rg ]
   return mlchan

-- | Return the set of processes that should be notified together with channels
-- that could be used for notifications.
getNotificationChannels :: PhaseM LoopState l [(SendPort NotificationMessage, [M0.Process])]
getNotificationChannels = do
  rg <- getLocalGraph
  let nodes = [ (node, m0node)
              | host <- G.connectedTo R.Cluster R.Has rg :: [R.Host]
              , node <- G.connectedTo host R.Runs rg
              , m0node <- nodeToM0Node node rg
              ]
  things <- for nodes $ \(node, m0node) -> do
     mchan <- lookupMeroChannelByNode node
     let procs = filter (\p -> case M0.getState p rg of
                                 M0.PSUnknown -> True
                                 M0.PSOnline  -> True
                                 M0.PSStarting -> True
                                 M0.PSStopping -> True
                                 _ -> False)
               $ (G.connectedTo m0node M0.IsParentOf rg :: [M0.Process])
     case (mchan, procs) of
       (_, []) -> return Nothing
       (Nothing, r) -> do
         phaseLog "warning" $ "HA.Service.Mero.notifyMero: can't find remote service for"
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
            -> PhaseM LoopState l StateDiff
mkStateDiff f msg onCommit = do
  epoch <- updateEpoch
  let idx  = StateDiffIndex epoch
      diff = StateDiff epoch msg onCommit
  rc    <- getCurrentRC
  modifyGraph $ G.newResource diff
            >>> G.newResource idx
            >>> G.connect idx R.Is diff
            >>> G.connect rc R.Has diff
            >>> f
  return diff

-- | Find 'StateDiff' by it's index. This function can find not yet garbage
-- collected diff.
getStateDiffByEpoch :: Word64 -> PhaseM LoopState l (Maybe StateDiff)
getStateDiffByEpoch idx = listToMaybe . G.connectedTo epoch R.Is <$> getLocalGraph
  where
    epoch = StateDiffIndex idx

-- | Mark that notification was delivered to process.
markNotificationDelivered :: StateDiff -> M0.Process -> PhaseM LoopState l ()
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

markNotificationFailed :: StateDiff -> M0.Process -> PhaseM LoopState l ()
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
tryCompleteStateDiff :: StateDiff -> PhaseM LoopState l ()
tryCompleteStateDiff diff = do
  ps <- G.connectedTo diff WaitingFor <$> getLocalGraph
  when (null (ps :: [M0.Process])) $ do
    rc <- getCurrentRC
    modifyGraph $ G.disconnect rc R.Has diff
    okProcesses <- G.connectedTo diff DeliveredTo <$> getLocalGraph
    failProcesses <- G.connectedTo diff WaitingFor  <$> getLocalGraph
    registerSyncGraph $ do
      for_ (stateDiffOnCommit diff) applyOnCommit
      promulgateWait $ Notified (stateEpoch diff) (stateDiffMsg diff) okProcesses failProcesses

-- | Mark all notifications for processes on the given node as failed.
--
-- This code process node even in case if it was disconnected from cluster.
failNotificationsOnNode :: R.Node -> PhaseM LoopState l ()
failNotificationsOnNode node = do
  -- Find all processes on the current target node.
  ps <- (\rg ->
           [ m0process
           | m0node <- nodeToM0Node node rg :: [M0.Node]
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
notifyMeroAsync :: StateDiff -> Mero.Notification.Set -> PhaseM LoopState l ()
notifyMeroAsync diff s = do
  chans <- getNotificationChannels :: PhaseM LoopState l [(SendPort NotificationMessage, [M0.Process])]
  for_ chans $ \(chan, recipients) -> do
    modifyGraph $ execState $ for recipients $
      State.modify . G.connect diff ShouldDeliverTo
    registerSyncGraph $
      sendChan chan $ NotificationMessage (stateEpoch diff) s (map M0.fid recipients)

-- | Apply on commit actions for the state diff.
applyOnCommit :: OnCommit -> Process ()
applyOnCommit _ = return ()  -- FIXME