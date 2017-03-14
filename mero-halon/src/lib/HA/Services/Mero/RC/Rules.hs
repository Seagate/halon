-- |
-- Module    : HA.Services.Mero.RC.Rules
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Rule definitions for interacting with @halon:m0d@ service.
module HA.Services.Mero.RC.Rules
  ( rules
  ) where

-- service dependencies
import HA.Services.Mero (lookupM0d)
import HA.Services.Mero.Types
import HA.Services.Mero.RC.Actions
import HA.Services.Mero.RC.Events

-- RC dependencies
import           HA.RecoveryCoordinator.RC.Actions
import           HA.RecoveryCoordinator.RC.Actions.Log
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
  , ruleHalonM0dFailed
  , ruleHalonM0dExit
  , ruleHalonM0dException
  , ruleGenericNotification
  ]

ruleCheckCleanup :: Definitions RC ()
ruleCheckCleanup = define "service::m0d::check-cleanup" $ do
  check_cleanup <- phaseHandle "check_cleanup"

  setPhaseIf check_cleanup g $ \(uid, nid) -> do
    todo uid
    rg <- getLocalGraph
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
  \(Notified epoch msg _ fails) -> do
    promulgateRC msg
    unless (null fails) $ do
      ps <- (\rg -> filter (\p -> getState p rg == M0.PSOnline) fails) <$> getLocalGraph
      unless (null ps) $ do
        phaseLog "warning" "Some services were marked online but notifications failed to be delivered"
        phaseLog "warning" $ "epoch = " ++ show epoch
        for_ ps $ \p -> phaseLog "warning" $ "fid = " ++ show (M0.fid p)
        promulgateRC $ NotifyFailureEndpoints (M0.r_endpoint <$> ps)

-- | When notification Set was delivered to some process we should mark that
-- in graph and check if there are some other pending processes, if not -
-- announce set as beign sent.
ruleNotificationsDeliveredToM0d :: Definitions RC ()
ruleNotificationsDeliveredToM0d = define "service::m0d::notification::delivered-to-mero" $ do
  notification_delivered <- phaseHandle "notification_delivered"

  setPhaseIf notification_delivered g $ \(uid, epoch, fid) -> do
    todo uid
    mdiff <- getStateDiffByEpoch epoch
    for_ mdiff $ \diff -> do
      mp <- M0.lookupConfObjByFid fid <$> getLocalGraph
      for_ mp $ markNotificationDelivered diff
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
ruleNotificationsFailedToBeDeliveredToM0d = define "service::m0d::notification::delivery-failed" $ do
  notification_failed <- phaseHandle "notification_failed"

  setPhaseIf notification_failed g $ \(uid, epoch, fid) -> do
    todo uid
    tagContext SM [("epoch", show epoch), ("fid", show fid)] Nothing
    mdiff <- getStateDiffByEpoch epoch
    for_ mdiff $ \diff -> do
      mp <- M0.lookupConfObjByFid fid <$> getLocalGraph
      for_ mp $ markNotificationFailed diff
    done uid

  start notification_failed ()
  where
    g (HAEvent uid (NotificationFailure epoch fid)) _ _ = return $! Just (uid, epoch, fid)
    g _ _ _ = return Nothing

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
