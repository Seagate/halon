-- Copyright: (C) 2015 Seagate LLC
--
module HA.Services.Mero.RC.Rules
  ( rules
  ) where

-- service dependencies
import HA.Services.Mero.Types
import HA.Services.Mero.RC.Actions
import HA.Services.Mero.RC.Events

-- RC dependencies
import           HA.RecoveryCoordinator.RC.Actions
import           HA.RecoveryCoordinator.RC.Actions.Log
import           HA.Resources.Mero.Note (getState, NotifyFailureEndpoints(..))

-- halon dependencies
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
import           HA.EventQueue

import Control.Monad (unless)
import Control.Distributed.Process (usend)
import Control.Distributed.Process.Internal.Types (processNodeId)
import Data.Foldable (for_)
import Data.Typeable (cast)

import Network.CEP

import Prelude hiding (id)

-- | Rules that are needed to support halon:m0d service in RC.
rules :: Definitions RC ()
rules = sequence_
  [ ruleCheckCleanup
  , ruleRegisterChannels
-- , ruleNotificationsDeliveredToHalonM0d
  , ruleNotificationsDeliveredToM0d
  , ruleNotificationsFailedToBeDeliveredToM0d
  , ruleHalonM0dFailed
  , ruleHalonM0dExit
  , ruleHalonM0dException
  , ruleGenericNotification
  ]

ruleCheckCleanup :: Definitions RC ()
ruleCheckCleanup = defineSimpleTask "service::m0d::check-cleanup" $ do
  \(CheckCleanup sp) -> do
    rg <- getLocalGraph
    let node = R.Node (processNodeId sp)
        cleanup = null $
          [ ()
          | Just (host :: R.Host) <- [G.connectedFrom R.Runs node rg]
          , m0node :: M0.Node <- G.connectedTo host R.Runs rg
          , proc :: M0.Process <- G.connectedTo m0node M0.IsParentOf rg
          , G.isConnected proc R.Is M0.ProcessBootstrapped rg
          ]
    liftProcess $ usend sp cleanup

-- | Register channels that can be used in order to communicate with halon:m0d
-- service.
ruleRegisterChannels :: Definitions RC ()
ruleRegisterChannels = defineSimpleTask "service::m0d::declare-mero-channel" $
  \(DeclareMeroChannel sp c cc) -> do
      let node = R.Node (processNodeId sp)
      registerChannel node c
      registerChannel node cc
      registerSyncGraph $ do -- XXX: use notificaion meachanism
        promulgateWait $ MeroChannelDeclared sp c cc

-- | Rule that allow old interface that was listening to internal message to be
-- used.
ruleGenericNotification :: Definitions RC ()
ruleGenericNotification = defineSimpleTask "service::m0d::notification" $
  \(Notified epoch msg _ fails) -> do
    promulgateRC msg
    unless (null fails) $ do
      ps <- (\rg -> filter (\p ->
                  case getState p rg of
                    M0.PSOnline -> True
                    _        -> False) fails) <$> getLocalGraph
      unless (null ps) $ do
        phaseLog "warning" "Some services were marked online but notifications failed to be delivered"
        phaseLog "warning" $ "epoch = " ++ show epoch
        for_ ps $ \p -> phaseLog "warning" $ "fid = " ++ show (M0.fid p)
        promulgateRC $ NotifyFailureEndpoints (M0.r_endpoint <$> ps)

-- | When notification Set was delivered to some process we should mark that
-- in graph and check if there are some other pending processes, if not -
-- announce set as beign sent.
ruleNotificationsDeliveredToM0d :: Definitions RC ()
ruleNotificationsDeliveredToM0d = defineSimpleTask "service::m0d::notification::delivered-to-mero" $
  \(NotificationAck epoch fid) -> do
      mdiff <- getStateDiffByEpoch epoch
      for_ mdiff $ \diff -> do
        mp <- M0.lookupConfObjByFid fid <$> getLocalGraph
        for_ mp $ markNotificationDelivered diff

-- | When notification was failed to be delivered to mero we mark it as not
-- delivered, so other services who rely on that notification could see that.
ruleNotificationsFailedToBeDeliveredToM0d :: Definitions RC ()
ruleNotificationsFailedToBeDeliveredToM0d = defineSimpleTask "service::m0d::notification::delivery-failed" $
  \(NotificationFailure epoch fid) -> do
      tagContext SM [("epoch", show epoch), ("fid", show fid)] Nothing
      mdiff <- getStateDiffByEpoch epoch
      for_ mdiff $ \diff -> do
        mp <- M0.lookupConfObjByFid fid <$> getLocalGraph
        for_ mp $ markNotificationFailed diff

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
       unregisterMeroChannelsOn node

-- | Handle normal exit from service.
-- (See 'ruleHalonM0dFailed' for more explations)
ruleHalonM0dExit :: Definitions RC ()
ruleHalonM0dExit = defineSimpleTask "service::m0d::notification::halon-m0d-exit" $
  \(ServiceExit node info _) -> do
     ServiceInfo svc _ <- decodeMsg info
     for_ (cast svc) $ \(_ :: Service MeroConf) -> do
       failNotificationsOnNode node
       unregisterMeroChannelsOn node

-- | Handle exceptional exit from service.
-- (See 'ruleHalonM0dFailed' for more explations)
ruleHalonM0dException :: Definitions RC ()
ruleHalonM0dException = defineSimpleTask "service::m0d::notification::halon-m0d-exception" $
  \(ServiceUncaughtException node info _ _) -> do
     ServiceInfo svc _ <- decodeMsg info
     for_ (cast svc) $ \(_ :: Service MeroConf) -> do
       failNotificationsOnNode node
       unregisterMeroChannelsOn node

-- $outdated
-- When we can't guarantee that halon:m0d have delivered all notifications that
-- were sent to it to all local processes, we can't guarantee that processes are
-- up to data. In this case we mark halon:m0d as outdated, this means that all
-- services that were co-located with halon:m0d should requery cluster state.
-- All restarted services will do that anyway, however if services didn't die,
-- they may be outdates still, in this case halon:m0d should either send
-- notifications explicitly or ask m0d to request status.
