-- |
-- Module    : HA.Services.Mero.RC.Rules
-- Copyright : (C) 2015-2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Rule definitions for interacting with @halon:m0d@ service.
module HA.Services.Mero.RC.Rules
  ( rules
  ) where

-- service dependencies
import HA.Service (getInterface)
import HA.Services.Mero (lookupM0d)
import HA.Services.Mero.Types
import HA.Services.Mero.RC.Actions
import HA.Services.Mero.RC.Events

-- RC dependencies
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import           HA.Resources.Mero.Note (getState, NotifyFailureEndpoints(..))

-- halon dependencies
import           HA.EventQueue.Types (HAEvent(..))
import qualified HA.ResourceGraph as G
import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Mero   as M0
import           HA.Service
  ( Service
  , ServiceInfo(..)
  , ServiceFailed(..)
  , ServiceExit(..)
  , ServiceUncaughtException(..))
import           HA.Service.Interface

import Control.Monad (unless)
import Data.Foldable (for_)
import Data.Typeable (cast)

import Network.CEP

import Prelude hiding (id)

-- | Rules that are needed to support halon:m0d service in RC.
rules :: Definitions RC ()
rules = sequence_
  [ ruleCheckCleanup
  , ruleNotificationsDeliveredToM0d
  , ruleNotificationsFailedToBeDeliveredToM0d
  , ruleNotificationTimeoutReached
  , ruleHalonM0dFailed
  , ruleHalonM0dExit
  , ruleHalonM0dException
  , ruleGenericNotification
  , ruleAnnounceEvent
  ]

ruleCheckCleanup :: Definitions RC ()
ruleCheckCleanup = define "service::m0d::check-cleanup" $ do
  check_cleanup <- phaseHandle "check_cleanup"

  setPhaseIf check_cleanup g $ \(uid, nid) -> do
    todo uid
    rg <- getGraph
    let msg = Cleanup . null $
          [ ()
          | Just (host :: R.Host) <- [G.connectedFrom R.Runs (R.Node nid) rg]
          , m0node :: M0.Node <- G.connectedTo host R.Runs rg
          , p :: M0.Process <- G.connectedTo m0node M0.IsParentOf rg
          , G.isConnected p R.Is M0.ProcessBootstrapped rg
          ]
    -- Cleanup check is issued during bootstrap so the service is very
    -- likely not online yet; use the interface directly.
    sendSvc (getInterface $ lookupM0d rg) nid msg
    done uid

  start check_cleanup ()
  where
    g (HAEvent uid (CheckCleanup nid)) _ _ = return $! Just (uid, nid)
    g _ _ _ = return Nothing

-- | Rule that allow old interface that was listening to internal message to be
-- used.
--
-- This rule unconditionally sends out 'InternalStateChangeMsg' around
-- the RC, even if the notification failed to deliver to every
-- involved process. 'tryCompleteStateDiff' is what guards the entry
-- into this rule.
--
-- Any rules that depend on a state transition should wait for the
-- internal state change notification: if they do not, we expose a
-- possible race. Consider 'ruleProcessStart': if it did not wait for
-- 'PSStarting' internal notification and 'Notified' was delayed,
-- following could happen.
--
-- * 'PSStarting' notification fails (as the process is not started yet)
--
-- * Rule continues and starts the process, process gets into 'PSOnline'
--
-- * 'ruleGenericNotification' for the failed 'PSStarting' fires
--
-- * The process is 'PSOnline' so we 'NotifyFailureEndpoints' and fail
--   the process.
ruleGenericNotification :: Definitions RC ()
ruleGenericNotification = defineSimpleTask "service::m0d::notification" $
  \(Notified epoch msg _ fails timeouts) -> do
    Log.tagContext Log.SM [("epoch", show epoch)] Nothing
    promulgateRC msg
    unless (null fails && null timeouts) $ do
      psF <- (\rg -> filter (\p -> getState p rg == M0.PSOnline) fails) <$> getGraph
      psT <- (\rg -> filter (\p -> getState p rg == M0.PSOnline) timeouts) <$> getGraph
      unless (null psF && null psT) $ do
        for_ psF $ \p -> Log.rcLog' Log.WARN $ "Delivery failed to: " ++ show (M0.fid p)
        for_ psT $ \p -> Log.rcLog' Log.WARN $ "Delivery timed out to: " ++ show (M0.fid p)
        promulgateRC $ NotifyFailureEndpoints (M0.r_endpoint <$> psF ++ psT)

-- | When notification Set was delivered to some process we should mark that
-- in graph and check if there are some other pending processes, if not -
-- announce set as beign sent.
ruleNotificationsDeliveredToM0d :: Definitions RC ()
ruleNotificationsDeliveredToM0d = define "service::m0d::notification::delivered-to-mero" $ do
  notification_delivered <- phaseHandle "notification_delivered"

  setPhaseIf notification_delivered g $ \(uid, epoch, fid) -> do
    todo uid
    Log.tagContext Log.SM [ ("epoch", show epoch)
                          , ("fid", show fid)
                          ] Nothing
    mdiff <- getStateDiffByEpoch epoch
    for_ mdiff $ \diff -> do
      mp <- M0.lookupConfObjByFid fid <$> getGraph
      for_ mp $ \p -> do
        Log.tagContext Log.SM p Nothing
        markNotificationDelivered diff p
    done uid

  start notification_delivered ()
  where
    g (HAEvent uid (NotificationAck epoch fid)) _ _ = return $! Just (uid, epoch, fid)
    g _ _ _ = return Nothing

-- | When notification was failed to be delivered to mero we mark it
-- as not delivered, so other services who rely on that notification
-- could see that. The flow from here to the relevant process actually
-- being failed is as follows:
--
-- * 'markNotificationFailed' marks the notification as failed to
--   deliver to the process
--
-- * 'tryCompleteStateDiff' sends a 'Notified' message with list of
--   processes that have so far delivered or failed to deliver
--
-- * 'ruleGenericNotification' receives the message and examines the
--   failed processes. Inf any of the failed processes are in
--   'PSOnline' state, 'NotifyFailureEndpoints' is sent out for that
--   process endpoint
--
-- * 'ruleFailedNotificationFailsProcess' fails every process that
--   shares the endpoint
ruleNotificationsFailedToBeDeliveredToM0d :: Definitions RC ()
ruleNotificationsFailedToBeDeliveredToM0d = defineSimpleIf "service::m0d::notification::delivery-failed" g $ do
  \(uid, epoch, fid) -> do
    todo uid
    Log.tagContext Log.SM [("epoch", show epoch), ("fid", show fid)] Nothing
    mdiff <- getStateDiffByEpoch epoch
    for_ mdiff $ \diff -> do
      mp <- M0.lookupConfObjByFid fid <$> getGraph
      for_ mp $ markNotificationFailed diff
    done uid
  where
    g (HAEvent uid (NotificationFailure epoch fid)) _ = return $! Just (uid, epoch, fid)
    g _ _ = return Nothing

-- | Unpack 'AnnounceEvent' sent by @halon:m0d@ and send it to rest of RC.
ruleAnnounceEvent :: Definitions RC ()
ruleAnnounceEvent = defineSimpleIf "service::m0d::notification::announce" g $
  \(uid, ev) -> do
    todo uid
    promulgateRC ev
    done uid
  where
    g (HAEvent uid (AnnounceEvent v)) _ = return $! Just (uid, v)
    g _ _ = return Nothing

-- | Fired when the period of time for notifications to be sent has elapsed.
--   This does not necessarily indicate a problem, since this will fire for every
--   notification.
ruleNotificationTimeoutReached :: Definitions RC ()
ruleNotificationTimeoutReached = defineSimple "service::m0d::notification::timeout" $ \(EpochTimeout epoch) -> do
  Log.tagContext Log.SM [("epoch", show epoch)] Nothing
  mdiff <- getStateDiffByEpoch epoch
  for_ mdiff $ \diff -> do
    Log.rcLog' Log.WARN "Epoch timed out with unhandled notifications."
    forceCompleteStateDiff diff


-- | Handle event from regular monitor about halon:m0d service death.
-- This means that there is some problem with halon service (possibly non fatal
-- failure in service). If this event happens this means that all internal state
-- could be lost, and halon requested connection close, and close of the
-- ha_interface.
--
-- As a result of such event RC should mark all pending messages as
-- non-delivered and mark halon:m0d on the node as 'Outdated', (see $outdated)
ruleHalonM0dFailed :: Definitions RC ()
ruleHalonM0dFailed = defineSimpleTask "service::m0d::notification::halon-m0d-failed" $
  \(ServiceFailed node info _) -> do
     ServiceInfo svc _ <- decodeMsg info
     for_ (cast svc) $ \(_ :: Service MeroConf) -> do
       failNotificationsOnNode node

-- | Handle normal exit from service.
-- (See 'ruleHalonM0dFailed' for more explations)
ruleHalonM0dExit :: Definitions RC ()
ruleHalonM0dExit = defineSimpleTask "service::m0d::notification::halon-m0d-exit" $
  \(ServiceExit node info _) -> do
     ServiceInfo svc _ <- decodeMsg info
     for_ (cast svc) $ \(_ :: Service MeroConf) -> do
       failNotificationsOnNode node

-- | Handle exceptional exit from service.
-- (See 'ruleHalonM0dFailed' for more explations)
ruleHalonM0dException :: Definitions RC ()
ruleHalonM0dException = defineSimpleTask "service::m0d::notification::halon-m0d-exception" $
  \(ServiceUncaughtException node info _ _) -> do
     ServiceInfo svc _ <- decodeMsg info
     for_ (cast svc) $ \(_ :: Service MeroConf) -> do
       failNotificationsOnNode node

-- $outdated
-- When we can't guarantee that halon:m0d have delivered all notifications that
-- were sent to it to all local processes, we can't guarantee that processes are
-- up to data. In this case we mark halon:m0d as outdated, this means that all
-- services that were co-located with halon:m0d should requery cluster state.
-- All restarted services will do that anyway, however if services didn't die,
-- they may be outdates still, in this case halon:m0d should either send
-- notifications explicitly or ask m0d to request status.
