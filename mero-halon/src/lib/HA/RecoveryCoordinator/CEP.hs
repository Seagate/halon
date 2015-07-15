-- |
-- Copyright : (C) 2013,2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Recovery coordinator CEP rules
--

{-# LANGUAGE CPP                       #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RecordWildCards           #-}

module HA.RecoveryCoordinator.CEP where

import Prelude hiding ((.), id)
import Control.Category
import Control.Monad
import Data.Foldable (for_)

import           Control.Distributed.Process
import           Network.CEP

import           HA.EventQueue.Consumer
import           HA.NodeAgent.Messages
import           HA.NodeUp
import           HA.RecoveryCoordinator.Mero
import           HA.Resources
import           HA.Resources.Mero
import           HA.Service
import           HA.Services.Empty
import qualified HA.Services.EQTracker as EQT
#ifdef USE_MERO
import           HA.Services.Mero (meroRules)
#endif
import           HA.Services.Monitor (SaveProcesses(..), regularMonitor)
import           HA.Services.SSPL (ssplRules)

-- | RC node-up rule local state. It isn't used anywhere else.
data ServiceBoot
    = None
      -- ^ When no service is expected to be started. That's the inial value.
    | forall a. Configuration a => Starting (Service a) ProcessId
      -- ^ Indicates a service has been started and we are waiting for a
      --   'ServiceStarted' message of that same service.

-- | Used at RC node-up rule definition. Track the confirmation of a
--   service we've previously started by looking at 'Starting' fields. In any
--   other case, it refuses the message.
serviceBootStarted :: HAEvent ServiceStartedMsg
                   -> LoopState
                   -> ServiceBoot
                   -> Process (Maybe (HAEvent ServiceStartedMsg))
serviceBootStarted evt@(HAEvent _ msg _) ls l@(Starting psvc pid) = do
    res <- notHandled evt ls l
    case res of
      Nothing -> return Nothing
      Just _  -> do
        let pn = Node $ processNodeId pid
        ServiceStarted n svc _ _ <- decodeP msg
        if serviceName svc == serviceName psvc && n == pn
          then return $ Just evt
          else return Nothing
serviceBootStarted _ _ _ = return Nothing

-- | Used at RC service-start rule definition. Tracks the confirmation of a
--   service we've previously started by looking at the local state. In any
--   other case, it refuses the message.
serviceStarted :: HAEvent ServiceStartedMsg
               -> LoopState
               -> Maybe (Node, ServiceName, Int)
               -> Process (Maybe (HAEvent ServiceStartedMsg))
serviceStarted evt@(HAEvent _ msg _) ls l@(Just (n1, sname, _)) = do
    res <- notHandled evt ls l
    case res of
      Nothing -> return Nothing
      Just _  -> do
       ServiceStarted n svc _ _ <- decodeP msg
       if n == n1 && serviceName svc == sname
         then return $ Just evt
         else return Nothing
serviceStarted _ _ _ = return Nothing

-- | Used at RC service-start rule definition. Tracks an issue encountered when
--   we tried to start a service by looking at the local state. In any
--   other case, it refuses the message.
serviceCouldNotStart :: HAEvent ServiceCouldNotStartMsg
                     -> LoopState
                     -> Maybe (Node, ServiceName, Int)
                     -> Process (Maybe (HAEvent ServiceCouldNotStartMsg))
serviceCouldNotStart evt@(HAEvent _ msg _) ls l@(Just (n1, sname, _)) = do
    res <- notHandled evt ls l
    case res of
      Nothing -> return Nothing
      Just _  -> do
       ServiceCouldNotStart n svc _ <- decodeP msg
       if n == n1 && serviceName svc == sname
         then return $ Just evt
         else return Nothing
serviceCouldNotStart _ _ _ = return Nothing

rcRules :: IgnitionArguments -> ProcessId -> Definitions LoopState ()
rcRules argv eq = do
    initRule $ rcInitRule argv eq

    define "node-up" $ do
      boot        <- phaseHandle "boot"
      eqt_started <- phaseHandle "eqt_started"
      start_nm    <- phaseHandle "start_node_monitor"
      nm_started  <- phaseHandle "node_monitor_started"

      setPhase boot $ \evt@(HAEvent _ (NodeUp h pid) _) -> do
        let nid  = processNodeId pid
            node = Node nid
        known <- knownResource node
        handled eq evt
        if not known
          then do
            let host = Host h
            liftProcess . sayRC $ "New node contacted: " ++ show nid
            registerService EQT.eqTracker
            registerNode node
            registerHost host
            locateNodeOnHost node host
            startService nid EQT.eqTracker EmptyConf
            put Local (Starting EQT.eqTracker pid)
            continue eqt_started
          else ack pid

      setPhaseIf eqt_started serviceBootStarted $
          \evt@(HAEvent _ msg _) -> do
        ServiceStarted n svc cfg sp@(ServiceProcess pid) <- decodeMsg msg
        liftProcess $ sayRC $
          "started " ++ snString (serviceName svc) ++ " service"
        True <- liftProcess $ updateEQNodes pid (stationNodes argv)
        registerServiceName svc
        registerServiceProcess n svc cfg sp
        handled eq evt
        sendToMasterMonitor msg
        continue start_nm

      directly start_nm $ do
        Starting _ npid <- get Local
        let nid = processNodeId npid
        registerService regularMonitor
        conf <- loadNodeMonitorConf (Node nid)
        startService nid regularMonitor conf
        put Local (Starting regularMonitor npid)
        continue nm_started

      setPhaseIf nm_started serviceBootStarted $
          \evt@(HAEvent _ msg _) -> do
        ServiceStarted n svc cfg sp <- decodeMsg msg
        liftProcess $ sayRC $
          "started " ++ snString (serviceName svc) ++ " service"
        Starting _ npid <- get Local
        registerServiceName svc
        registerServiceProcess n svc cfg sp
        handled eq evt
        sendToMasterMonitor msg
        ack npid

      start boot None

    -- Service Start
    define "service-start" $ do

      ph0 <- phaseHandle "pre-request"
      ph1 <- phaseHandle "start-request"
      ph1' <- phaseHandle "service-failed"
      ph2 <- phaseHandle "start-success"
      ph3 <- phaseHandle "start-failed"
      ph4 <- phaseHandle "start-failed-totally"

      directly ph0 $ switch [ph1, ph1']

      setPhaseIf ph1 notHandled $ \evt@(HAEvent _ msg _) -> do
        ServiceStartRequest sstart n@(Node nid) svc conf <- decodeMsg msg
        handled eq evt

        -- Store the service start request, and the failed retry count
        put Local $ Just (n, serviceName svc, 0 :: Int)

        known <- knownResource n
        msp   <- lookupRunningService n svc

        registerService svc
        case (known, msp, sstart) of
          (True, Nothing, HA.Service.Start) -> do
            startService nid svc conf
            switch [ph2, ph3]
          (True, Just sp, Restart) -> do
            writeConfiguration sp conf Intended
            bounceServiceTo Intended n svc
            switch [ph2, ph3]
          _ -> continue ph0

      setPhaseIf ph1' notHandled $ \evt@(HAEvent _ msg _) -> do
        ServiceFailed n svc pid <- decodeMsg msg
        res                     <- lookupRunningService n svc
        handled eq evt
        case res of
          Just (ServiceProcess spid) | spid == pid -> do
            -- Store the service failed message, and the failed retry count
            put Local $ Just (n, serviceName svc, 0)
            bounceServiceTo Current n svc
            switch [ph2, ph3]
          _ -> continue ph0

      setPhaseIf ph2 serviceStarted $ \evt@(HAEvent _ msg _) -> do
        ServiceStarted n svc cfg sp <- decodeMsg msg
        handled eq evt

        res <- lookupRunningService n svc
        case res of
          Just sp' -> unregisterServiceProcess n svc sp'
          Nothing  -> registerServiceName svc

        registerServiceProcess n svc cfg sp

        let vitalService = serviceName EQT.eqTracker == serviceName svc ||
                           serviceName regularMonitor == serviceName svc

        if vitalService
          then do
            sendToMasterMonitor msg
            when (serviceName EQT.eqTracker == serviceName svc) $ do
              let ServiceProcess eqt_pid = sp
              True <- liftProcess $ updateEQNodes eqt_pid (stationNodes argv)
              return ()
          else sendToMonitor n msg

        phaseLog "started" ("Service "
                            ++ (snString . serviceName $ svc)
                            ++ " started"
                           )

        liftProcess $ sayRC $
          "started " ++ snString (serviceName svc) ++ " service"
        continue ph0

      setPhaseIf ph3 serviceCouldNotStart $ \evt@(HAEvent _ msg _) -> do
        ServiceCouldNotStart (Node nid) svc cfg <- decodeMsg msg
        handled eq evt
        Just (n1, s1, count) <- get Local
        if count <= 4
          then do
            -- | Increment the failure count
            put Local $ Just (n1, s1, count+1)
            startService nid svc cfg
            switch [ph2, ph3]
          else continue ph4

      directly ph4 $ do
        Just (n1, s1, count) <- get Local
        phaseLog "error" ("Service "
                        ++ (snString s1)
                        ++ " on node "
                        ++ show n1
                        ++ " cannot start after "
                        ++ show count
                        ++ " attempts."
                         )
        continue ph0

      start ph0 Nothing

    -- EpochRequest
    defineSimple "epoch-request" $
      \evt@(HAEvent _ (EpochRequest pid) _) -> do
      resp <- prepareEpochResponse
      sendMsg pid resp
      handled eq evt

    defineSimple "mm-pid" $
      \evt@(HAEvent _ (GetMultimapProcessId sender) _) -> do
         mmid <- getMultimapProcessId
         sendMsg sender mmid
         handled eq evt

    defineSimple "dummy-event" $ \evt@(HAEvent _ DummyEvent _) -> do
      i <- getNoisyPingCount
      liftProcess $ sayRC $ "Noisy ping count: " ++ show i
      handled eq evt

    defineSimple "stop-request" $ \evt@(HAEvent _ msg _) -> do
      ServiceStopRequest node svc <- decodeMsg msg
      res                         <- lookupRunningService node svc
      for_ res $ \sp ->
        killService sp UserStop
      handled eq evt

    defineSimple "save-processes" $
      \evt@(HAEvent _ (SaveProcesses sp ps) _) -> do
       writeConfiguration sp ps Current
       handled eq evt

    setLogger sendLogs
    ssplRules
#ifdef USE_MERO
    meroRules
#endif

sendLogs :: Logs -> LoopState -> Process ()
sendLogs logs ls =
    for_ (lookupDLogServiceProcess ls) $ \(ServiceProcess pid) -> do
      usend pid logs
