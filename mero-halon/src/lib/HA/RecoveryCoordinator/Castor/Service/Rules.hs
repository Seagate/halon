{-# LANGUAGE LambdaCase            #-}
-- |
-- Module    : HA.RecoveryCoordinator.Castor.Service.Rules
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Service related rules.
module HA.RecoveryCoordinator.Castor.Service.Rules
  ( rules
  ) where

import HA.EventQueue (HAEvent(..))
import HA.RecoveryCoordinator.RC.Actions
  ( RC
  , LoopState(..)
  , todo
  , done
  , getLocalGraph
  )
import HA.RecoveryCoordinator.Mero.Events (stateSet)
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import HA.RecoveryCoordinator.Mero.Notifications (setPhaseNotified)
import HA.RecoveryCoordinator.Mero.State (applyStateChanges)
import qualified HA.RecoveryCoordinator.Mero.Transitions as Tr
import qualified HA.ResourceGraph as G
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import qualified HA.Resources as R
import Mero.ConfC (ServiceType(..))
import Mero.Notification.HAState
  ( HAMsg(..)
  , HAMsgMeta(..)
  , ServiceEvent(..)
  , ServiceEventType(..)
  )

import Data.Foldable (for_)
import Data.Maybe (fromMaybe)
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
ruleNotificationHandler :: Definitions RC ()
ruleNotificationHandler = define "castor::service::notification-handler" $ do
  start_rule <- phaseHandle "start"
  service_notified <- phaseHandle "service-notified"
  timed_out <- phaseHandle "timed-out"
  finish <- phaseHandle "finish"

  let startState :: ClusterTransitionLocal
      startState = Nothing

      viewSrv :: ClusterTransitionLocal -> Maybe (M0.Service, M0.ServiceState -> Bool)
      viewSrv = maybe Nothing (\(_,srvi,_) -> fmap (fmap (==)) srvi)

      -- Check that the service has the given tag (predicate) and
      -- check that it's not in the given state in RG already.
      serviceTagged p typ (HAEvent eid (HAMsg (ServiceEvent se st _pid) m)) ls =
        let rg = lsGraph ls
            isStateChanged s = M0.getState s (lsGraph ls) /= typ
        in case M0.lookupConfObjByFid (_hm_fid m) rg of
            Just (s :: M0.Service) | p se && isStateChanged s -> Just (eid, s, typ, st)
            _ -> Nothing

      servicePidMatches (HAEvent _ (HAMsg (ServiceEvent _ _ spid) m)) ls =
        let rg = lsGraph ls
            msd = M0.lookupConfObjByFid (_hm_fid m) (lsGraph ls) :: Maybe M0.Service
        in case msd of
             Nothing -> False
             Just srv -> fromMaybe False $ do
               p :: M0.Process <- G.connectedFrom M0.IsParentOf srv rg
               is_m0t1fs <- Just $ all (\s -> M0.s_type s `notElem` [CST_IOS, CST_MDS, CST_MGS, CST_HA])
                                       (G.connectedTo p M0.IsParentOf rg)
               if spid == -1
               then return True -- if message is old and does not contain pid, we accept message.
               else if is_m0t1fs
                    then return (spid == 0)
                    else do M0.PID pid <- G.connectedTo p R.Has rg
                            return (spid == fromIntegral pid)

      isServiceOnline = serviceTagged (== TAG_M0_CONF_HA_SERVICE_STARTED) M0.SSOnline
      isServiceStopped = serviceTagged (== TAG_M0_CONF_HA_SERVICE_STOPPED) M0.SSOffline

      startOrStop msg@(HAEvent eid _) ls _ = return . Just . maybe (Left eid) Right $
        if servicePidMatches msg ls
        then case isServiceOnline msg ls of
               Nothing -> isServiceStopped msg ls
               Just x -> Just x
        else Nothing

  setPhaseIf start_rule startOrStop $ \case
    Left eid -> todo eid >> done eid -- XXX: just remove this guy?
    Right (eid, service, st, typ) -> do
      todo eid
      Log.tagContext Log.SM service Nothing
      phaseLog "begin" "Service transition"
      Log.tagContext Log.SM [
          ("transaction.id", show eid)
        , ("service.state", show st)
        , ("service.type", show typ)
        ] Nothing
      rg <- getLocalGraph
      let haSiblings =
            [ svc | Just (p :: M0.Process) <- [G.connectedFrom M0.IsParentOf service rg]
                  , svc <- G.connectedTo p M0.IsParentOf rg
                  , M0.s_type svc == CST_HA ]
      case haSiblings of
        -- This service is not process-co-located with any CST_HA
        -- service
        [] -> do
          put Local $ Just (eid, Just (service, st), Nothing)
          let tr = if st == M0.SSOnline then Tr.serviceOnline else Tr.serviceOffline
          applyStateChanges [stateSet service tr]
          switch [service_notified, timeout 30 timed_out]
        -- We're working with services for halon process: ignore these
        -- service message as
        --
        -- - we can't tell if the message is current
        --
        -- - without abnormal scenario, PROCESS_STOPPED will always be
        --   sent for this process too
        --
        -- - we don't want to fight with PROCESS_STOPPED for no reason
        --   and be subject to poor ordering
        _ -> phaseLog "warn" "Ignoring mero notification about a halon:m0d process service."

  setPhaseNotified service_notified viewSrv $ \(srv, st) -> do
    rg <- getLocalGraph
    let mproc = G.connectedFrom M0.IsParentOf srv rg :: Maybe M0.Process
    Just (eid, _, _) <- get Local
    Log.withLocalContext' $ do
      for_ mproc $ \proc ->
        Log.tagLocalContext proc $ Just "Process hosting service"
      Log.rcLog Log.DEBUG ("transaction.id", show eid)
      case (st, mproc) of
        (M0.SSOnline, Just p) -> case M0.getState p rg of
          M0.PSStopping -> do
            Log.rcLog Log.WARN "Service ONLINE received while process is stopping."
          M0.PSOffline -> do
            Log.rcLog Log.WARN "Service ONLINE received while process is offline."
          _ -> return ()
        (M0.SSOffline, Just p) -> case M0.getState p rg of
          M0.PSInhibited{} -> do
            Log.rcLog Log.DEBUG $ "Service offline, process inhibited."
          M0.PSOffline  -> do
            Log.rcLog Log.DEBUG $ "Service offline, process offline"
          M0.PSStopping -> do
            Log.rcLog Log.DEBUG $ "Service offline, process stopping"
          pst -> do
            Log.rcLog Log.DEBUG $ "Service for process failed, process state was " ++ show pst
            let failMsg = "Underlying service failed: " ++ show (M0.fid srv)
            applyStateChanges [stateSet p $ Tr.processFailed failMsg]
        err ->
          phaseLog "warn" $ "Couldn't handle bad state for " ++ M0.showFid srv
                          ++ ": " ++ show err
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

-- | Service rules.
rules :: Definitions RC ()
rules = sequence_
  [ ruleNotificationHandler ]
