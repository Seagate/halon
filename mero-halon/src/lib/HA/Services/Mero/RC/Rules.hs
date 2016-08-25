-- Copyright: (C) 2015 Seagate LLC
--

{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE RankNTypes                 #-}

module HA.Services.Mero.RC.Rules
  ( rules
  ) where

-- service dependencies
import HA.Services.Mero.Types
import HA.Services.Mero.RC.Actions
import HA.Services.Mero.RC.Events

-- RC dependencies
import           HA.RecoveryCoordinator.Actions.Core
import           HA.Resources.Mero.Note (getState)

-- halon dependencies
import qualified HA.Resources.Mero   as M0
import           HA.Service
import           HA.Services.Monitor
import           HA.EventQueue.Producer

import Control.Monad (unless)
import Data.Foldable (for_)
import Data.Typeable

import Network.CEP

import Prelude hiding (id)

-- | Rules that are needed to support halon:m0d service in RC.
rules :: Definitions LoopState ()
rules = sequence_
  [ ruleRegisterChannels
-- , ruleNotificationsDeliveredToHalonM0d
  , ruleNotificationsDeliveredToM0d
  , ruleNotificationsFailedToBeDeliveredToM0d
  , ruleHalonM0dFailed
  , ruleGenericNotification
  ]


-- | Register channels that can be used in order to communicate with halon:m0d
-- service.
ruleRegisterChannels :: Definitions LoopState ()
ruleRegisterChannels = defineSimpleTask "service::m0d::declare-mero-channel" $
  \(DeclareMeroChannel sp c cc) -> do
      registerChannel sp c
      registerChannel sp cc
      -- XXX: use notify
      registerSyncGraph $ do
        promulgateWait $ MeroChannelDeclared sp c cc

-- | Rule that allow old interface that was listening to internal message to be
-- used.
ruleGenericNotification :: Definitions LoopState ()
ruleGenericNotification = defineSimpleTask "service::m0d::notification" $
   \(Notified epoch msg oks fails) -> do
      promulgateRC msg
      unless (null fails) $ do
        ps <- (\rg -> filter (\p ->
                  case getState p rg of
                    M0.PSOnline -> True
                    _        -> False) fails) <$> getLocalGraph
        unless (null ps) $ do
          phaseLog "warning" "some services were marked online but notifications failed to be delivered"
          phaseLog "warning" $ "epoch = " ++ show epoch
          for_ ps $ \p -> phaseLog "warning" $ "fid = " ++ show (M0.fid p)


-- | When notification Set was delivered to some process we should mark that
-- in graph and check if there are some other pending processes, if not -
-- announce set as beign sent.
ruleNotificationsDeliveredToM0d :: Definitions LoopState ()
ruleNotificationsDeliveredToM0d = defineSimpleTask "service::m0d::notification::delivered-to-mero" $
  \(NotificationAck epoch fid) -> do
      mdiff <- getStateDiffByEpoch epoch
      for_ mdiff $ \diff -> do
        mp <- M0.lookupConfObjByFid fid <$> getLocalGraph
        for_ mp $ markNotificationDelivered diff

-- | When notification was failed to be delivered to mero we mark it as not
-- delivered, so other services who rely on that notification could see that.
ruleNotificationsFailedToBeDeliveredToM0d :: Definitions LoopState ()
ruleNotificationsFailedToBeDeliveredToM0d = defineSimpleTask "service::m0d::notification::delivery-failed" $
  \(NotificationFailure epoch fid) -> do
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
ruleHalonM0dFailed :: Definitions LoopState ()
ruleHalonM0dFailed = defineSimpleTask "service::m0d::notification::halon-m0d-failed" $ \msg -> do
  ServiceFailed node svc _pid <- decodeMsg msg
  for_ (cast svc) $ \(_ :: Service MeroConf) -> failNotificationsOnNode node
  for_ (cast svc) $ \(_ :: Service MonitorConf) -> failNotificationsOnNode node

-- $outdated
-- When we can't guarantee that halon:m0d have delivered all notifications that
-- were sent to it to all local processes, we can't guarantee that processes are
-- up to data. In this case we mark halon:m0d as outdated, this means that all
-- services that were co-located with halon:m0d should requery cluster state.
-- All restarted services will do that anyway, however if services didn't die,
-- they may be outdates still, in this case halon:m0d should either send
-- notifications explicitly or ask m0d to request status.
