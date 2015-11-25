-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- CEP Rules pertaining to the management of Halon internal services.
--

{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE TemplateHaskell           #-}

module HA.RecoveryCoordinator.Rules.Service where

import Prelude hiding ((.), id)
import Control.Category
import Control.Monad (void)

import           Control.Distributed.Process
import           Control.Distributed.Process.Closure (mkClosure)
import           Network.CEP

import           HA.EventQueue.Producer (promulgateEQ)
import           HA.EventQueue.Types
import           HA.RecoveryCoordinator.Mero
import           HA.RecoveryCoordinator.Actions.Monitor
import           HA.Resources
import           HA.Service
import           HA.EQTracker (updateEQNodes__static, updateEQNodes__sdict)
import qualified HA.EQTracker as EQT
import           HA.Services.Monitor (regularMonitor)

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

serviceRules :: IgnitionArguments -> Definitions LoopState ()
serviceRules argv = do
  let timeup = 30 -- secs
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
      ServiceStartRequest sstart n@(Node nid) svc conf lis <- decodeMsg msg
      phaseLog "input" $ unwords [ "ServiceStartRequest:"
                                 , "name=" ++ (snString $ serviceName svc)
                                 , "type=" ++ show sstart
                                 , "nid=" ++ show nid
                                 , "listeners=" ++ show lis
                                 ]
      phaseLog "thread-id" (show uuid)
      -- Store the service start request, and the failed retry count
      put Local $ Just (uuid, n, serviceName svc, 0 :: Int)

      known <- knownResource n
      msp   <- lookupRunningService n svc

      registerService svc
      case (known, msp, sstart) of
        (True, Nothing, HA.Service.Start) -> do
          startService nid svc conf
          liftProcess $ mapM_ (flip usend AttemptingToStart) lis
          switch [ph2, ph3, timeout timeup ph4]
        (True, Just sp, Restart) -> do
          writeConfiguration sp conf Intended
          bounceServiceTo Intended n svc
          switch [ph2, ph3, timeout timeup ph4]
        (True, Just _, HA.Service.Start) -> do
          phaseLog "info" $ unwords [ snString $ serviceName svc
                                    , "already running on"
                                    , show nid]
          liftProcess $ mapM_ (flip usend AlreadyRunning) lis
          finishProcessingMsg uuid
          messageProcessed uuid
        (True, Nothing, HA.Service.Restart) -> do
          phaseLog "info" $ unwords [ snString $ serviceName svc
                                    , "not already running on"
                                    , show nid]
          liftProcess $ mapM_ (flip usend NotAlreadyRunning) lis
          finishProcessingMsg uuid
          messageProcessed uuid
        (False, _, _) -> do
          phaseLog "info" $ unwords [ "Cannot start service on unknown node:"
                                    , show nid
                                    ]
          liftProcess $ mapM_ (flip usend NodeUnknown) lis
          finishProcessingMsg uuid
          messageProcessed uuid

    setPhaseIf ph1' notHandled $ \(HAEvent uuid msg _) -> do
      startProcessingMsg uuid
      ServiceFailed n svc pid <- decodeMsg msg
      res                     <- lookupRunningService n svc
      phaseLog "input" $ unwords [ "ServiceFailed:"
                                 , "name=" ++ (snString $ serviceName svc)
                                 , "nid=" ++ show n
                                 ]
      phaseLog "thread-id" $ show uuid
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
    setPhaseIf ph2' notHandled $ \(HAEvent uuid msg _) -> do
      ServiceStarted n@(Node nodeId) svc cfg sp@(ServiceProcess spid)
        <- decodeMsg msg
      phaseLog "input" $ unwords [ "ServiceStarted:"
                                 , "name=" ++ (snString $ serviceName svc)
                                 , "nid=" ++ show nodeId
                                 ]
      phaseLog "thread-id" $ show uuid
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
            then do startNodesMonitoring [msg]
                    -- EQT may not be spawn at the moment so we create a special
                    -- process that will update EQT as soon as it will see that.
                    _ <- liftProcess $ spawnAsync nodeId $
                        $(mkClosure 'EQT.updateEQNodes) (stationNodes argv)
                    startProcessMonitoring n =<< getRunningServices n
            else startProcessMonitoring n [msg]
          phaseLog "info" ("Service "
                              ++ (snString . serviceName $ svc)
                              ++ " started"
                             )
          liftProcess $ sayRC $
            "started " ++ snString (serviceName svc) ++ " service on " ++
              show (processNodeId spid)
          messageProcessed uuid
        else messageProcessed uuid

    setPhaseIf ph2 serviceStarted $ \(HAEvent uuid msg _) -> do
      ServiceStarted n@(Node nodeId) svc cfg sp@(ServiceProcess spid)
        <- decodeMsg msg
      Just (thread, _, _, _) <- get Local
      phaseLog "input" $ unwords [ "ServiceStarted:"
                                 , "name=" ++ (snString $ serviceName svc)
                                 , "nid=" ++ show nodeId
                                 ]
      phaseLog "thread-id" $ show thread
      res <- lookupRunningService n svc
      case res of
        Just sp' -> unregisterServiceProcess n svc sp'
        Nothing  -> registerServiceName svc

      registerServiceProcess n svc cfg sp

      let vitalService = serviceName regularMonitor == serviceName svc

      if vitalService
        then do startNodesMonitoring [msg]
                _ <- liftProcess $ spawnAsync nodeId $
                       $(mkClosure 'EQT.updateEQNodes) (stationNodes argv)
                startProcessMonitoring n =<< getRunningServices n
        else startProcessMonitoring n [msg]

      phaseLog "info" ("Service "
                          ++ (snString . serviceName $ svc)
                          ++ " started"
                         )

      finishProcessingMsg thread
      messageProcessed uuid
      messageProcessed thread
      liftProcess $ sayRC $
        "started " ++ snString (serviceName svc) ++ " service on " ++
        show (processNodeId spid)

    setPhaseIf ph3 serviceCouldNotStart $ \(HAEvent uuid msg _) -> do
      ServiceCouldNotStart (Node nid) svc cfg <- decodeMsg msg
      messageProcessed uuid
      Just (thread, n1, s1, count) <- get Local
      phaseLog "input" $ unwords [ "ServiceCouldNotStart:"
                                 , "name=" ++ (snString $ serviceName svc)
                                 , "nid=" ++ show nid
                                 ]
      phaseLog "thread-id" $ show thread
      if count <= 4
        then do
          phaseLog "debug"
            $ unwords [ snString $ serviceName svc , "did not start on node"
                      , show nid ++ ".", "Retrying another"
                      , show (4 - count) , "times."
                      ]
          -- | Increment the failure count
          put Local $ Just (thread, n1, s1, count+1)
          startService nid svc cfg
          switch [ph2, ph3, timeout timeup ph4]
        else continue ph4

    directly ph4 $ do
      Just (uuid, n1, s1, count) <- get Local
      phaseLog "thread-id" $ show uuid
      phaseLog "error" ("Service "
                      ++ (snString s1)
                      ++ " on node "
                      ++ show n1
                      ++ " cannot start after "
                      ++ show count
                      ++ " attempts."
                       )
      self <- liftProcess getSelfNode
      void . liftProcess $ promulgateEQ [self] $ RecoverNode uuid n1
      -- Message announced as processed inside RecoverNode handler

    start ph0 Nothing

  defineSimple "service-status" $ \(HAEvent uuid msg _) -> do
    ServiceStatusRequest node svc@(Service _ _ d) listeners <- decodeMsg msg
    response <- lookupRunningService node svc >>= \case
      Nothing -> return SrvStatNotRunning
      Just sp@(ServiceProcess pid) -> do
        rg <- getLocalGraph
        let currentConf = readConfig sp Current rg
            wantsConf = readConfig sp Intended rg
        return $ case (currentConf, wantsConf) of
          (Just a, Nothing) -> SrvStatRunning d pid a
          (Just a, Just b) -> SrvStatRestarting d pid a b
          _ -> SrvStatError $ "Wrong config profiles found."
    liftProcess $ mapM_ (flip usend (encodeP response)) listeners
    messageProcessed uuid
