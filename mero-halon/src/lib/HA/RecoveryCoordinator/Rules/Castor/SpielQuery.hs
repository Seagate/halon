{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- When we receive an 'M0_NC_ONLINE' notification about a 'M0.Pool'
-- from mero, this is a sign that either repair or rebalance actions
-- are happening and we need to keep track of those and in the end
-- notify mero of completion. This module simply serves to deal
-- unclutter the "HA.RecoveryCoordinator.Rules.Castor" module by
-- moving the querying mechanism here.
--
-- Assumptions/quirks/TODOs/notes:
--
-- * Only one repair XOR rebalance happens on a pool at any one time.
-- That is, if the PRS is marked with certain 'M0.PoolRepairType', all
-- the status messages coming in until the repairs are done will be
-- precisely about that repair/rebalance.
--
-- * We won't enter here at all unless 'M0.PoolRepairStatus' was set
-- on the 'M0.Pool' already. This is ensured in the caller. The @PRS@
-- is set by the spiel helpers that start repair/rebalance.
--
-- * When a repair is finished, we have to unset the PRS from the pool
-- or things will get confusing if we need to repair it again in the
-- future.
--
-- * If we fail to get a message about status back from spiel, we stop
-- the repairs. Can we do anything more sensible? Similarly, we don't
-- currently have spiel queries on a time out.
--
-- * There are two similar rules instead of one for few reasons. We
-- could dispatch both hourly and five minute queries but hourly could
-- run spuriously or for wrong set of repairs. We could merge the
-- rules into one but it creates problems when RC restarts: oops,
-- which query were we in again? If either rule gets restarted on its
-- own, it should recover fine.
module HA.RecoveryCoordinator.Rules.Castor.SpielQuery
  ( querySpiel
  , querySpielHourly
  , queryStartHandling
  ) where

import           Control.Distributed.Process
import           Control.Exception (SomeException)
import           Control.Monad
import           Data.Binary (Binary)
import           Data.Foldable
import           Data.Typeable (Typeable)
import qualified Data.UUID as UUID
import           Data.List (nub)
import           GHC.Generics (Generic)
import           HA.EventQueue.Producer
import           HA.EventQueue.Types
import           HA.RecoveryCoordinator.Actions.Core
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Mero
import qualified HA.ResourceGraph as G
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero hiding (Enclosure, Process, Rack, Process)
import           HA.Resources.Mero.Note
import           HA.Services.Mero
import           Mero.ConfC (ServiceType(CST_IOS))
import           Mero.Notification hiding (notifyMero)
import qualified Mero.Spiel as Spiel
import           Network.CEP
import           Prelude hiding (id)

-- | Event sent when we want a 5 minute spiel query rule to fire
data SpielQuery = SpielQuery Pool M0.PoolRepairType
  deriving (Eq, Show, Generic, Typeable)

instance Binary SpielQuery

-- | Event sent when we want a 60 minute repeated query rule to fire
data SpielQueryHourly = SpielQueryHourly Pool M0.PoolRepairType
  deriving (Eq, Show, Generic, Typeable)

instance Binary SpielQueryHourly

-- | Handler for @M0_NC_ONLINE@ 'Pool' messages. Its main role is to
-- check whether we need to wait for more messages and if yes,
-- dispatch queries to SSPL after a period of time through
-- 'querySpiel'. As we do not receive information as to what type of
-- message this is about, we use previously stored 'M0.PoolRepairType'
-- to help us out.
queryStartHandling :: M0.Pool -> M0.PoolRepairType -> PhaseM LoopState l ()
queryStartHandling pool prt = do
  phaseLog "repair" $ show prt ++ " on pool " ++ show pool
  possiblyInitialisePRI pool
  iosvs <- length <$> getIOServices pool
  phaseLog "repair" $ "IO services count: " ++ show iosvs
  case prt of
    M0.Failure -> do -- repair
      withRepairStatus prt pool UUID.nil $ \sts -> do
        let onlines = length $ filterCompletedRepairs sts
        modifyPoolRepairInformation pool $ \pri ->
          pri { priOnlineNotifications = onlines }
        Just pri <- getPoolRepairInformation pool
        phaseLog "repair" $ "IO services done: " ++ show (priOnlineNotifications pri)
        if priOnlineNotifications pri >= iosvs 
           then do
             unsetPoolRepairStatus pool
             notifyMero [AnyConfObj pool] $ repairedNotificationMsg prt
           else do
             updatePoolRepairStatusTime pool
             selfMessage $ SpielQuery pool prt
    M0.Rebalance -> do
      incrementOnlinePRSResponse pool
      Just pri <- getPoolRepairInformation pool
      -- XXX: old procedure
      if -- This is the first and only notification, notify about finished
         -- repairs and unset PRS
        | priOnlineNotifications pri == 1 && iosvs == 1 -> do
             -- we don't know if this notification is from right repair or not
             notifyMero [AnyConfObj pool] $ repairedNotificationMsg prt
             unsetPoolRepairStatus pool
         -- This is the first of many notifications, start query in 5
         -- minutes.
         | priOnlineNotifications pri == 1 && iosvs > 1 -> do
             phaseLog "repair" "we were waiting only for one notification, waiting for other IO services."
             selfMessage $ SpielQuery pool prt
         -- This is not the first notification so we have already
         -- dispatched a query before, do nothing.
         | otherwise -> return ()

-- | This function does basic checking of whether we're done
-- repairing/rebalancing as well as handling time related matters.
--
-- Check if have received all online messages we were expecting.
--
-- If yes, notify about success and finish repair/rebalance.
--
-- If not, calculate the amount of time we have to wait until the next
-- query. Currently it's 5 minutes since the last query. Note that
-- when we enter this rule, the time since last query is the same as
-- the time that we received the first online notification, set by
-- 'incrementOnlinePRSResponse'. This ensure that we don't query
-- immediatelly after we receive the first status message. 'timeout'
-- for constant amount of time here is not good enough in case RC dies
-- in the middle of the wait.
--
-- This query is only ran once. If we're not finished repairing by
-- time we query spiel, we dispatch 'querySpielHourly' and finish the
-- rule.
querySpiel :: Specification LoopState ()
querySpiel = define "query-spiel" $ do
  dispatchQuery <- phaseHandle "dispatch-query"
  runQuery <- phaseHandle "run-query"

  setPhase dispatchQuery $ \(HAEvent uid (SpielQuery pool prt) _) -> do
    phaseLog "DEBUG" "request status"
    startProcessingMsg uid
    put Local $ Just (uid, pool, prt)
    getPoolRepairInformation pool >>= \case
      Nothing -> do
        unsetPoolRepairStatus pool
        messageProcessed uid
      Just pri -> do
        timeNow <- liftIO getTime
        let elapsed = timeNow - priTimeOfFirstCompletion pri
            untilTimeout = 60 - elapsed
        iosvs <- length <$> getIOServices pool
        phaseLog "repair" $ "IO services: " ++ show iosvs ++ " done: " ++ (show $ priOnlineNotifications pri)
        if priOnlineNotifications pri < iosvs
        then switch [timeout (timeSpecToSeconds untilTimeout) runQuery]
        else do notifyMero [AnyConfObj pool] $ repairedNotificationMsg prt
                unsetPoolRepairStatus pool
                messageProcessed uid

  directly runQuery $ do
    phaseLog "DEBUG" "request status"
    Just (uid, pool, prt) <- get Local
    iosvs <- length <$> getIOServices pool
    withRepairStatus prt pool uid $ \sts -> do
      let onlines = length $ filterCompletedRepairs sts
      modifyPoolRepairInformation pool $ \pri ->
        pri { priOnlineNotifications = onlines }
      updatePoolRepairStatusTime pool
      nid <- liftProcess getSelfNode
      phaseLog "repair" $ "IO services: " ++ (show iosvs) ++ " done: " ++ (show onlines)
      if onlines < iosvs
      then continue $ timeout 60 runQuery  -- liftProcess . void . promulgateEQ [nid] $ SpielQueryHourly pool prt
      else do notifyMero [AnyConfObj pool] $ repairedNotificationMsg prt
              unsetPoolRepairStatus pool
    messageProcessed uid

  start dispatchQuery Nothing

-- | This rule works in similar fashion to 'querySpiel' with the main difference
-- that:
--
-- * it runs hourly
-- * it runs until repairs complete
querySpielHourly :: Specification LoopState ()
querySpielHourly = define "query-spiel-hourly" $ do
  dispatchQueryHourly <- phaseHandle "dispatch-query-hourly"
  runQueryHourly <- phaseHandle "run-query-hourly"

  setPhase dispatchQueryHourly $ \(HAEvent uid (SpielQueryHourly pool prt) _) -> do
    t <- getTimeUntilQueryHourlyPRI pool
    put Local $ Just (uid, pool, prt)
    switch [timeout t runQueryHourly]

  directly runQueryHourly $ do
    Just (uid, pool, prt) <- get Local
    iosvs <- length <$> getIOServices pool
    Just pri <- getPoolRepairInformation pool
    let completeRepair = do notifyMero [AnyConfObj pool] $ repairedNotificationMsg prt
                            phaseLog "DEBUG" "complete repair"
                            unsetPoolRepairStatus pool
                            messageProcessed uid
    case priOnlineNotifications pri < iosvs of
      False -> completeRepair
      True -> withRepairStatus prt pool uid $ \sts -> do
        phaseLog "DEBUG" "request status"
        -- is 'filterCompletedRepairs' relevant for rebalancing too?
        -- If not, how do we handle this query?
        let onlines = length $ filterCompletedRepairs sts
        modifyPoolRepairInformation pool $ \pri' ->
          pri' { priOnlineNotifications = onlines }
        updatePoolRepairStatusTime pool
        if onlines < iosvs
        then do t <- getTimeUntilQueryHourlyPRI pool
                switch [timeout t runQueryHourly]
        else completeRepair

  start dispatchQueryHourly Nothing

-- | Try to fetch 'Spiel.SnsStatus' for the given 'Pool' and if that
-- fails, unset the @PRS@ and ack the message. Otherwise run the
-- user-supplied handler.
withRepairStatus :: PoolRepairType -> Pool -> UUID
                 -> ([Spiel.SnsStatus] -> PhaseM LoopState l ())
                 -> PhaseM LoopState l ()
withRepairStatus prt pool uid f = repairStatus prt pool >>= \case
  Left e -> do
    liftProcess . sayRC $ "repairStatus " ++ show prt ++ " failed: " ++ show e
    updatePoolRepairStatusTime pool
    messageProcessed uid
  Right sts -> f sts

-- | Covert 'M0.PoolRepairType' into a 'ConfObjectState' that mero
-- expects: it's different depending on whether we are rebalancing or
-- repairing.
repairedNotificationMsg :: M0.PoolRepairType -> ConfObjectState
repairedNotificationMsg M0.Rebalance = M0_NC_ONLINE
repairedNotificationMsg M0.Failure = M0_NC_REPAIRED

-- | Just like 'repairedNotificationMessage', dispatch the appropriate
-- status checking routine depending on whether we're rebalancing or
-- repairing.
repairStatus :: M0.PoolRepairType -> M0.Pool
             -> PhaseM LoopState l (Either SomeException [Spiel.SnsStatus])
repairStatus M0.Rebalance = statusOfRebalanceOperation
repairStatus M0.Failure = statusOfRepairOperation

-- | Given a 'Pool', retrieve all associated IO services ('CST_IOS').
getIOServices :: Pool -> PhaseM LoopState l [M0.Service]
getIOServices pool = getLocalGraph >>= \g -> return (nub 
  [ svc | pv <- G.connectedTo pool IsRealOf g :: [PVer]
        , rv <- G.connectedTo pv IsParentOf g :: [RackV]
        , ev <- G.connectedTo rv IsParentOf g :: [EnclosureV]
        , cv <- G.connectedTo ev IsParentOf g :: [ControllerV]
        , ct <- G.connectedFrom IsRealOf cv g :: [Controller]
        , nd <- G.connectedFrom IsOnHardware ct g :: [M0.Node]
        , pr <- G.connectedTo nd IsParentOf g :: [M0.Process]
        , svc@(M0.Service { M0.s_type = CST_IOS }) <- G.connectedTo pr IsParentOf g
        ])

-- | Find only those services that are in a state of finished (or not
-- started) repair.
filterCompletedRepairs :: [Spiel.SnsStatus] -> [Spiel.SnsStatus]
filterCompletedRepairs = filter p
  where
    p (Spiel.SnsStatus _ Spiel.M0_SNS_CM_STATUS_IDLE _) = True
    p (Spiel.SnsStatus _ Spiel.M0_SNS_CM_STATUS_FAILED _) = True
    p _ = False
