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
import Data.Foldable (for_)

import           Control.Distributed.Process
import           Control.Distributed.Process.Internal.Types (nullProcessId)
import           Network.CEP

import           HA.EventQueue.Types
import           HA.NodeAgent.Messages
import           HA.NodeUp
import           HA.RecoveryCoordinator.Mero
import           HA.RecoveryCoordinator.Rules.Castor
import           HA.Resources
import           HA.Resources.Castor
import           HA.Service
import qualified HA.EQTracker as EQT
#ifdef USE_MERO
import           HA.Services.Mero (meroRules)
#endif
import           HA.Services.Monitor (SaveProcesses(..), regularMonitor)
import           HA.Services.SSPL (ssplRules)

-- | RC node-up rule local state. It isn't used anywhere else.
data ServiceBoot
    = None
      -- ^ When no service is expected to be started. That's the inial value.
    | forall a. Configuration a => Starting UUID NodeId a (Service a) ProcessId
      -- ^ Indicates a service has been started and we are waiting for a
      --   'ServiceStarted' message of that same service.

-- | Used at RC node-up rule definition. Track the confirmation of a
--   service we've previously started by looking at 'Starting' fields. In any
--   other case, it refuses the message.
serviceBootStarted :: HAEvent ServiceStartedMsg
                   -> LoopState
                   -> ServiceBoot
                   -> Process (Maybe (HAEvent ServiceStartedMsg))
serviceBootStarted evt@(HAEvent _ msg _) ls l@(Starting _ _ _ psvc pid) = do
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

-- | Used at RC node-up rule definition. Returnes events that we are
-- not interested in
serviceBootStartedOther :: HAEvent ServiceStartedMsg
                        -> LoopState
                        -> ServiceBoot
                        -> Process (Maybe (HAEvent ServiceStartedMsg))
serviceBootStartedOther evt@(HAEvent _ msg _) _ _ = do
   ServiceStarted _ svc _ _ <- decodeP msg
   if serviceName svc == serviceName regularMonitor
      then return   Nothing
      else return $ Just evt

-- | Used at RC node-up rule definition. Returnes events that we are
-- not interested in
serviceBootCouldNotStartOther :: HAEvent ServiceCouldNotStartMsg
                              -> LoopState
                              -> ServiceBoot
                              -> Process (Maybe (HAEvent ServiceCouldNotStartMsg))
serviceBootCouldNotStartOther evt@(HAEvent _ msg _) _ _ = do
   ServiceCouldNotStart _ svc _ <- decodeP msg
   if serviceName svc == serviceName regularMonitor
      then return Nothing
      else return $ Just evt

-- | Used at RC node-up rule definition. Track the confirmation of a
--   service we've previously started by looking at 'Starting' fields. In any
--   other case, it refuses the message.
serviceBootCouldNotStart :: HAEvent ServiceCouldNotStartMsg
                   -> LoopState
                   -> ServiceBoot
                   -> Process (Maybe (HAEvent ServiceCouldNotStartMsg))
serviceBootCouldNotStart evt@(HAEvent _ msg _) ls l@(Starting _ nd _ psvc _) = do
    res <- notHandled evt ls l
    case res of
      Nothing -> return Nothing
      Just _  -> do
        ServiceCouldNotStart n svc _ <- decodeP msg
        if serviceName svc == serviceName psvc && Node nd == n
          then return $ Just evt
          else return Nothing
serviceBootCouldNotStart _ _ _ = return Nothing

-- | Used at RC service-start rule definition. Tracks the confirmation of a
--   service we've previously started by looking at the local state. In any
--   other case, it refuses the message.
serviceStarted :: HAEvent ServiceStartedMsg
               -> LoopState
               -> Maybe (UUID, Node, ServiceName, Int)
               -> Process (Maybe (HAEvent ServiceStartedMsg))
serviceStarted evt@(HAEvent _ msg _) ls l@(Just (_, n1, sname, _)) = do
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
                     -> Maybe (UUID, Node, ServiceName, Int)
                     -> Process (Maybe (HAEvent ServiceCouldNotStartMsg))
serviceCouldNotStart evt@(HAEvent _ msg _) ls l@(Just (_, n1, sname, _)) = do
    res <- notHandled evt ls l
    case res of
      Nothing -> return Nothing
      Just _  -> do
       ServiceCouldNotStart n svc _ <- decodeP msg
       if n == n1 && serviceName svc == sname
         then return $ Just evt
         else return Nothing
serviceCouldNotStart _ _ _ = return Nothing

rcRules :: IgnitionArguments -> ProcessId -> [Definitions LoopState ()] -> Definitions LoopState ()
rcRules argv eq additionalRules = do
    initRule $ rcInitRule argv eq

    let timeup = 30 -- secs

    define "node-up" $ do
      nodeup      <- phaseHandle "nodeup"
      nm_started  <- phaseHandle "node_monitor_started"
      nm_start    <- phaseHandle "node_monitor_start"
      nm_failed   <- phaseHandle "node_monitor_could_not_start"
      end         <- phaseHandle "end"

      setPhaseIf nodeup notHandled $ \(HAEvent uuid (NodeUp h pid) _) -> do
        startProcessingMsg uuid
        let nid  = processNodeId pid
            node = Node nid
        liftProcess . sayRC $ "New node contacted: " ++ show nid
        known <- knownResource node
        conf <- loadNodeMonitorConf (Node nid)
        if not known
          then do
            let host = Host h
            registerNode node
            registerHost host
            locateNodeOnHost node host
            fork NoBuffer $ do
              put Local (Starting uuid nid conf regularMonitor pid)
              continue nm_start
            continue nodeup
          else do
            -- Check if we already provision node with a monitor or not.
            msp  <- lookupRunningService (Node nid) regularMonitor
            case msp of
              Nothing -> do
                fork NoBuffer $ do
                  put Local (Starting uuid nid conf regularMonitor pid)
                  continue nm_start
                continue nodeup
              Just _  -> do liftProcess . sayRC $ "node is already provisioned: " ++ show nid
                            ack pid
                            sendMsg eq uuid
                            finishProcessingMsg uuid
                            continue nodeup

      directly nm_start $ do
        Starting _ nid conf svc _ <- get Local
        liftProcess $ nsendRemote nid EQT.name
          (nullProcessId nid, UpdateEQNodes $ stationNodes argv)
        registerService svc
        startService nid svc conf
        switch [nm_started, nm_failed]

      setPhaseIf nm_started serviceBootStarted $
          \(HAEvent msgid msg _) -> do
        ServiceStarted n svc cfg sp <- decodeMsg msg
        liftProcess $ sayRC $
          "started " ++ snString (serviceName svc) ++ " service on " ++ show sp
        Starting uuid _ _ _ npid <- get Local
        registerServiceName svc
        registerServiceProcess n svc cfg sp
        sendToMasterMonitor msg
        ack npid
        sendMsg eq msgid
        sendMsg eq uuid
        finishProcessingMsg uuid
        continue end

      setPhaseIf nm_failed serviceBootCouldNotStart $
          \(HAEvent msgid msg _) -> do
        ServiceCouldNotStart n svc _ <- decodeMsg msg
        liftProcess $ sayRC $
          "failed " ++ snString (serviceName svc) ++ " service on the node " ++ show n
        sendMsg eq msgid
        Starting uuid _ _ _ _ <- get Local
        finishProcessingMsg uuid
        continue end

      directly end stop

      start nodeup None

    -- Service Start
    define "service-start" $ do

      ph0 <- phaseHandle "pre-request"
      ph1 <- phaseHandle "start-request"
      ph1' <- phaseHandle "service-failed"
      ph2' <- phaseHandle "service-started"
      ph2 <- phaseHandle "start-success"
      ph3 <- phaseHandle "start-failed"
      ph4 <- phaseHandle "start-failed-totally"

      directly ph0 $ switch [ph1, ph1', ph2']

      setPhaseIf ph1 notHandled $ \(HAEvent uuid msg _) -> do
        startProcessingMsg uuid
        ServiceStartRequest sstart n@(Node nid) svc conf <- decodeMsg msg

        -- Store the service start request, and the failed retry count
        put Local $ Just (uuid, n, serviceName svc, 0 :: Int)

        known <- knownResource n
        msp   <- lookupRunningService n svc

        registerService svc
        case (known, msp, sstart) of
          (True, Nothing, HA.Service.Start) -> do
            startService nid svc conf
            switch [ph2, ph3, timeout timeup ph4]
          (True, Just sp, Restart) -> do
            writeConfiguration sp conf Intended
            bounceServiceTo Intended n svc
            switch [ph2, ph3, timeout timeup ph4]
          _ -> do finishProcessingMsg uuid
                  sendMsg eq uuid

      setPhaseIf ph1' notHandled $ \(HAEvent uuid msg _) -> do
        startProcessingMsg uuid
        ServiceFailed n svc pid <- decodeMsg msg
        res                     <- lookupRunningService n svc
        case res of
          Just (ServiceProcess spid) | spid == pid -> do
            -- Store the service failed message, and the failed retry count
            put Local $ Just (uuid, n, serviceName svc, 0)
            bounceServiceTo Current n svc
            switch [ph2, ph3, timeout timeup ph4]
          _ -> return ()

      -- It may be possible that previous invocation of RC was killed during
      -- service start, then it's perfectly ok to receive ServiceStarted
      -- message outside of the ServiceStart procedure. In this case the
      -- best we could do is to consult resource graph and check if we need
      -- this service running or not and proceed evaluation.
      setPhaseIf ph2' notHandled $ \evt@(HAEvent uuid msg _) -> do
        ServiceStarted n@(Node nodeId) svc cfg sp <- decodeMsg msg
        known <- knownResource n
        if known
           then do
            res <- lookupRunningService n svc
            case res of
              Just sp' -> unregisterServiceProcess n svc sp'
              Nothing  -> registerServiceName svc
            registerServiceProcess n svc cfg sp
            let vitalService = serviceName regularMonitor == serviceName svc
            if vitalService
              then do sendToMasterMonitor msg
                      liftProcess $
                        nsendRemote nodeId EQT.name (nullProcessId nodeId, UpdateEQNodes (stationNodes argv))
              else sendToMonitor n msg
            phaseLog "started" ("Service "
                                ++ (snString . serviceName $ svc)
                                ++ " started"
                               )
            liftProcess $ sayRC $
              "started " ++ snString (serviceName svc) ++ " service"
            sendMsg eq uuid
          else sendMsg eq uuid



      setPhaseIf ph2 serviceStarted $ \evt@(HAEvent _ msg _) -> do
        ServiceStarted n@(Node nodeId) svc cfg sp <- decodeMsg msg
        res <- lookupRunningService n svc
        case res of
          Just sp' -> unregisterServiceProcess n svc sp'
          Nothing  -> registerServiceName svc

        registerServiceProcess n svc cfg sp

        let vitalService = serviceName regularMonitor == serviceName svc

        if vitalService
          then do sendToMasterMonitor msg
                  liftProcess $ do
                    nsendRemote nodeId EQT.name (nullProcessId nodeId, UpdateEQNodes (stationNodes argv))
          else sendToMonitor n msg

        handled eq evt
        phaseLog "started" ("Service "
                            ++ (snString . serviceName $ svc)
                            ++ " started"
                           )

        Just (uuid, _, _, _) <- get Local
        finishProcessingMsg uuid
        sendMsg eq uuid
        liftProcess $ sayRC $
          "started " ++ snString (serviceName svc) ++ " service"

      setPhaseIf ph3 serviceCouldNotStart $ \evt@(HAEvent uuid msg _) -> do
        ServiceCouldNotStart (Node nid) svc cfg <- decodeMsg msg
        handled eq evt
        Just (_, n1, s1, count) <- get Local
        if count <= 4
          then do
            -- | Increment the failure count
            put Local $ Just (uuid, n1, s1, count+1)
            startService nid svc cfg
            switch [ph2, ph3, timeout timeup ph4]
          else continue ph4

      directly ph4 $ do
        Just (uuid, n1, s1, count) <- get Local
        phaseLog "error" ("Service "
                        ++ (snString s1)
                        ++ " on node "
                        ++ show n1
                        ++ " cannot start after "
                        ++ show count
                        ++ " attempts."
                         )
        finishProcessingMsg uuid
        sendMsg eq uuid

      start ph0 Nothing

    -- EpochRequest
    defineSimple "epoch-request" $
      \(HAEvent uuid (EpochRequest pid) _) -> do
      resp <- prepareEpochResponse
      sendMsg pid resp
      sendMsg eq uuid

    defineSimple "mm-pid" $
      \(HAEvent uuid (GetMultimapProcessId sender) _) -> do
         mmid <- getMultimapProcessId
         sendMsg sender mmid
         sendMsg eq uuid

    defineSimple "dummy-event" $
      \(HAEvent uuid (DummyEvent str) _) -> do
        i <- getNoisyPingCount
        liftProcess $ sayRC $ "received DummyEvent " ++ str
        liftProcess $ sayRC $ "Noisy ping count: " ++ show i
        sendMsg eq uuid

    defineSimple "stop-request" $ \(HAEvent uuid msg _) -> do
      ServiceStopRequest node svc <- decodeMsg msg
      res                         <- lookupRunningService node svc
      for_ res $ \sp ->
        killService sp UserStop
      sendMsg eq uuid

    defineSimple "save-processes" $
      \(HAEvent uuid (SaveProcesses sp ps) _) -> do
       writeConfiguration sp ps Current
       sendMsg eq uuid

    setLogger sendLogs
    ssplRules
    castorRules
#ifdef USE_MERO
    meroRules
#endif
    sequence_ additionalRules

sendLogs :: Logs -> LoopState -> Process ()
sendLogs logs ls = do
    nid <- getSelfNode
    for_ (lookupDLogServiceProcess nid ls) $ \(ServiceProcess pid) ->
      usend pid logs
