{-# LANGUAGE LambdaCase            #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Service related rules.
module HA.RecoveryCoordinator.Castor.Service.Rules
  ( rules
    -- * Individual rules exported for test purposes
  , ruleNotificationHandler
  ) where

import HA.EventQueue.Types (HAEvent(..))
import HA.RecoveryCoordinator.Actions.Core
  ( LoopState(..)
  , todo
  , done
  , getLocalGraph
  )
import HA.RecoveryCoordinator.Events.Mero (stateSet)
import HA.RecoveryCoordinator.Rules.Mero.Conf
  ( applyStateChanges
  , setPhaseNotified
  )
import qualified HA.ResourceGraph as G
import qualified HA.Resources as R
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0

import Mero.Notification.HAState
  ( HAMsgMeta(..)
  , ServiceEvent(..)
  , ServiceEventType(..)
  )

import Control.Monad (when)

import Data.Maybe (listToMaybe)
import Data.UUID (UUID)

import Network.CEP

-- | Local state used in 'ruleServiceNotificationHandler'.
type ClusterTransitionLocal =
  Maybe ( UUID
        , Maybe (M0.Service, M0.ServiceState)
        , Maybe (M0.Process, M0.ProcessState)
        )

-- | Handle notification for service states. This rule is responsible
-- for logic that sets service states, decides what to do with the
-- parent process based on the service states and on unblocking the
-- cluster bootstrap barrier if bootstrap is happening.
ruleNotificationHandler :: Definitions LoopState ()
ruleNotificationHandler = define "castor::service::notification-handler" $ do
   start_rule <- phaseHandle "start"
   service_notified <- phaseHandle "service-notified"
   process_notified <- phaseHandle "process-notified"
   timed_out <- phaseHandle "timed-out"
   finish <- phaseHandle "finish"

   let startState :: ClusterTransitionLocal
       startState = Nothing

       viewProc :: ClusterTransitionLocal -> Maybe (M0.Process, M0.ProcessState)
       viewProc = maybe Nothing (\(_, _, proci) -> proci)

       viewSrv :: ClusterTransitionLocal -> Maybe (M0.Service, M0.ServiceState)
       viewSrv = maybe Nothing (\(_,srvi,_) -> srvi)

       -- Check that the service has the given tag (predicate) and
       -- check that it's not in the given state in RG already.
       serviceTagged p typ (HAEvent eid (m@HAMsgMeta{}, ServiceEvent se st) _) ls _ = do
         let rg = lsGraph ls
             isStateChanged s = M0.getState s (lsGraph ls) /= typ
         return $ case M0.lookupConfObjByFid (_hm_fid m) rg of
           Just (s :: M0.Service) | p se && isStateChanged s -> Just (eid, s, typ, st)
           _ -> Nothing

       isServiceOnline = serviceTagged (== TAG_M0_CONF_HA_SERVICE_STARTED) M0.SSOnline
       isServiceStopped = serviceTagged (== TAG_M0_CONF_HA_SERVICE_STOPPED) M0.SSOffline

       startOrStop msg ls g = isServiceOnline msg ls g >>= \case
         Nothing -> isServiceStopped msg ls g
         Just x -> return $ Just x

   setPhaseIf start_rule startOrStop $ \(eid, service, st, typ) -> do
     todo eid
     phaseLog "begin" "Service transition"
     phaseLog "info" $ "transaction.id = " ++ show eid
     phaseLog "info" $ "service.fid    = " ++ show (M0.fid service)
     phaseLog "info" $ "service.state  = " ++ show st
     phaseLog "info" $ "service.type   = " ++ show typ -- XXX: remove
     put Local $ Just (eid, Just (service, st), Nothing)
     applyStateChanges [stateSet service st]
     switch [service_notified, timeout 30 timed_out]

   setPhaseNotified service_notified viewSrv $ \(srv, st) -> do
     rg <- getLocalGraph
     let mproc = listToMaybe $ G.connectedFrom M0.IsParentOf srv rg :: Maybe M0.Process
     Just (eid, _, _) <- get Local
     phaseLog "action" $ "Check if all services for process are online"
     phaseLog "info" $ "transaction.id = " ++ show eid
     phaseLog "info" $ "process.fid = " ++ show (fmap M0.fid mproc)
     case (st, mproc) of
       (M0.SSOnline, Just p) -> case M0.getState p rg of
         M0.PSStopping -> do
           phaseLog "warning" "Service ONLINE received while process is stopping."
         M0.PSOffline -> do
           phaseLog "warning" "Service ONLINE received while process is offline."
         _ -> return ()
       (M0.SSOffline, Just p) -> case M0.getState p rg of
         M0.PSInhibited{} -> do
           phaseLog "info" $ "Service offline, process inhibited."
         M0.PSOffline  -> do
           phaseLog "info" $ "Service offline, process offline"
         M0.PSStopping -> do
           phaseLog "info" $ "Service offline, process stopping"
         pst -> do
           phaseLog "info" $ "Service for process failed, process state was " ++ show pst
           let failMsg = "Underlying service failed: " ++ show (M0.fid srv)
           applyStateChanges [stateSet p . M0.PSFailed $ failMsg]
       err ->
         phaseLog "warn" $ "Couldn't handle bad state for " ++ M0.showFid srv
                        ++ ": " ++ show err
     continue finish

   setPhaseNotified process_notified viewProc $ \(p, pst) -> do
     Just (eid, srvi, _) <- get Local
     phaseLog "info" $ "transaction.eid = " ++ show eid
     phaseLog "info" $ "process.fid    = " ++ show (M0.fid p)
     phaseLog "info" $ "process.status = " ++ show pst
     rg <- getLocalGraph
     when (G.isConnected R.Cluster R.Has M0.OFFLINE rg) $
      phaseLog "warn" $
         unwords [ "Received service start notification about", show srvi
                 , "but cluster disposition is OFFLINE" ]
     continue finish

   directly timed_out $ do
     phaseLog "warn" $ "Waited too long for a notification ack"
     continue finish

   directly finish $ get Local >>= \case
       Just (eid, _, _) -> do
         done eid
         phaseLog "info" $ "transaction.idg = " ++ show eid
         phaseLog "end" "Service transition."
       lst -> phaseLog "warn" $ "In finish with strange local state: " ++ show lst

   startFork start_rule startState

rules :: Definitions LoopState ()
rules = sequence_
  [ ruleNotificationHandler ]
