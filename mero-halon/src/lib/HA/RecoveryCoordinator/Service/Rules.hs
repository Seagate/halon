{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs            #-}
{-# LANGUAGE MultiWayIf       #-}
{-# LANGUAGE TypeOperators    #-}
{-# LANGUAGE ViewPatterns     #-}
-- |
-- Copyright : (C) 2015-2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Rules pertaining to the management of Halon internal services.
module HA.RecoveryCoordinator.Service.Rules
  ( rules ) where

import           Control.Distributed.Process
import           Control.Lens
import           Control.Monad (when, unless)
import           Data.Coerce (coerce)
import           Data.Foldable (for_)
import           Data.Foldable (traverse_)
import           Data.Functor (void)
import           Data.Proxy
import           Data.Serialize.Put (runPutLazy)
import           Data.Typeable ((:~:), eqT, Typeable, (:~:)(Refl))
import           Data.UUID (UUID)
import           Data.Vinyl hiding ((:~:))
import           HA.Encode (encodeP)
import           HA.EventQueue
import           HA.RecoveryCoordinator.Job.Actions
import           HA.RecoveryCoordinator.Mero
import           HA.RecoveryCoordinator.RC.Actions.Log (rcLog', tagContext)
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.RecoveryCoordinator.Service.Actions as Service
import           HA.RecoveryCoordinator.Service.Events
import           HA.ResourceGraph (Graph)
import           HA.Resources.HalonVars
import           HA.SafeCopy
import           HA.Service
  ( ServiceExit(..)
  , ServiceFailed(..)
  , ServiceUncaughtException(..)
  , ServiceCouldNotStart(..)
  , ServiceStopNotRunning(..)
  , ServiceInfo(..)
  , ServiceInfoMsg
  , Service(..)
  , serviceLabel
  , serviceName
  , HasInterface(..)
  )
import           HA.Service.Interface
import qualified HA.Services.DecisionLog as DLog
import qualified HA.Services.Dummy as Dummy
import qualified HA.Services.Ekg as Ekg
import qualified HA.Services.Mero as Mero
import qualified HA.Services.Noisy as Noisy
import qualified HA.Services.Ping as Ping
import qualified HA.Services.SSPL as SSPL
import qualified HA.Services.SSPLHL as SSPLHL
import           Network.CEP
import           Text.Printf (printf)

-- | Service rules.
rules :: Definitions RC ()
rules = sequence_
  [ serviceStart
  , serviceStop
  , serviceStatus
  , ruleServiceFailed
  , ruleServiceExit
  , ruleServiceUncaughtException
  , ruleServiceStarted
  , ruleServiceCouldNotStart
  , ruleServiceMessageReceived
  ]

serviceStartJob :: Job ServiceStartRequestMsg ServiceStartRequestResult
serviceStartJob = Job "rc::service::start"

-- | Register service on the node and request monitor to start that
-- service. Rule will exit when either service will be started on the
-- node, or request to stop service will arrive.
--
-- In case if node is not yet known - process will exit.
serviceStart :: Definitions RC ()
serviceStart = mkJobRule serviceStartJob  args $ \(JobHandle _ finish) -> do
   do_restart  <- phaseHandle "service restart attempt"
   do_register <- phaseHandle "register"
   do_start    <- phaseHandle "do_start"
   wait_cancel <- phaseHandle "wait_cancel"
   wait_reply  <- phaseHandle "wait_reply"
   wait_fail   <- phaseHandle "wait_stop"
   wait_exit   <- phaseHandle "wait_exit"
   wait_exc    <- phaseHandle "wait_exception"
   wait_not_running <- phaseHandle "wait_not_running"

   let -- This job is using old method to notify all interested proceses
       -- so we are just reusing this method, without porting all the code
       -- to new subscription mechanism.
       announce what whom = liftProcess $ traverse_ (`usend` what) whom
       eqTT :: (Typeable a, Typeable b) => a -> b -> Maybe (a :~: b)
       eqTT _ _ = eqT
   let route msg = do
         (ServiceStartRequest startType node svc conf listeners) <- decodeMsg msg
         known <- knownResource node
         if known
         then do
            is_registered <- Service.has node (ServiceInfo svc conf)
            if is_registered && startType == Restart
            then do announce AttemptingToRestart listeners
                    return $ Right (ServiceStartRequestCancelled, [do_restart])
            else do
              mcfg <- Service.lookupConfig node svc
              case mcfg of
                Just c | c /= conf -> do
                  announce AttemptingToRestart listeners
                  return $ Right (ServiceStartRequestCancelled, [do_restart])
                _ -> do
                  announce AttemptingToStart listeners
                  return $ Right (ServiceStartRequestCancelled, [do_register])
         else do
           announce NodeUnknown listeners
           return $ Left "unknown node"

   let loop = do
         next <- fromLocal fldNext
         switch (wait_cancel:next)

   directly do_restart $ do
     Just msg <- fromLocal fldReq
     ServiceStartRequest _ node svc a _ <- decodeMsg msg
     tagContext Log.SM node (Just "service.node")
     tagContext Log.SM [ ("service.name", serviceName svc)
                       , ("service.config", show a)
                       ] Nothing
     minfo <- Service.lookupInfoMsg node svc
     for_ minfo $ \cfg -> do
       Service.markStopping node cfg
       Service.stop node svc
       putLocalR fldNext [wait_exit,wait_fail,wait_exc, wait_not_running]
       loop
     continue do_register

   let service_died died_node _died_info = do
         Just msg <- fromLocal fldReq
         ServiceStartRequest _ stopping_node _ _ _ <- decodeMsg msg
         unless (died_node == stopping_node) loop
         continue do_register
   setPhase wait_exit $ \(HAEvent _ (ServiceExit node info _)) ->
     service_died  node info
   setPhase wait_fail $ \(HAEvent _ (ServiceFailed node info _)) ->
     service_died node info
   setPhase wait_exc $ \(HAEvent _ (ServiceUncaughtException node info _ _)) ->
     service_died node info
   setPhase wait_exc $ \(HAEvent _ (ServiceUncaughtException node info _ _)) ->
     service_died node info
   setPhase wait_not_running $ \(HAEvent _ (ServiceStopNotRunning tgtnode lbl)) -> do
     Just msg <- fromLocal fldReq
     ServiceStartRequest _ node svc _ _ <- decodeMsg msg
     unless (tgtnode == node && serviceLabel svc == lbl) loop
     continue do_register

   directly do_register $ do
     Just msg <- fromLocal fldReq
     ServiceStartRequest _ node svc conf _ <- decodeMsg msg
     tagContext Log.SM node (Just "service.node")
     tagContext Log.SM [ ("service.name", serviceName svc)
                       , ("service.config", show conf)
                       ] Nothing
     Service.declare svc
     Service.register node svc conf
     continue do_start

   directly do_start $ do
     Just msg <- fromLocal fldReq
     ServiceStartRequest _ node svc conf _ <- decodeMsg msg
     Service.start node  $ ServiceInfo svc conf
     putLocalR fldNext [wait_reply]
     loop

   -- We do not acknowledge this message, because it should be done by another
   -- rule. Ideal solution here will require introduction service rule that
   -- will control running jobs, so they will be isolated
   setPhase wait_cancel $ \(HAEvent _ msg) -> do
     ServiceStopRequest stoppingNode stoppingSvc <- decodeMsg msg
     Just mmsg <- fromLocal fldReq
     ServiceStartRequest _ startingNode startingSvc _ _ <- decodeMsg mmsg
     if stoppingNode == startingNode
     then do
       case eqTT stoppingSvc startingSvc of
         Just Refl -> do
           putLocal fldRep $ ServiceStartRequestCancelled
           rcLog' Log.DEBUG "Service start was cancelled."
           continue finish
         Nothing -> loop
     else loop

   -- We do not acknowledge this message, because it should be done by another
   -- rule. Ideal solution here will require introduction service rule that
   -- will control running jobs, so they will be isolated
   setPhase wait_reply $ \(HAEvent _ (ServiceStarted startedNode info pid)) -> do
     ServiceInfo svc startedConf <- decodeMsg info
     Just mmsg <- fromLocal fldReq
     ServiceStartRequest _ startingNode startingSvc conf _ <- decodeMsg mmsg
     if startedNode == startingNode
     then case eqTT svc startingSvc of
       Just Refl ->
         if runPutLazy (safePut startedConf) ==
            runPutLazy (safePut conf) -- XXX: why not keep encoded?
         then do
           putLocal fldRep $ ServiceStartRequestOk
           rcLog' Log.DEBUG ("service.pid", show pid)
           continue finish
         else loop
       Nothing -> loop
     else loop

   return route
   where
     takeField l = getField . rget l
     fromLocal l = takeField l <$> get Local
     putLocal l x = modify Local $ rlens l .~ Field (Just x)
     putLocalR l x = modify Local $ rlens l .~ Field x


     fldReq :: Proxy '("request", Maybe ServiceStartRequestMsg)
     fldReq = Proxy
     fldRep :: Proxy '("reply", Maybe ServiceStartRequestResult)
     fldRep = Proxy
     fldInfoMsg :: Proxy '("info", Maybe ServiceInfoMsg)
     fldInfoMsg = Proxy
     fldNext :: Proxy '("next", [Jump PhaseHandle])
     fldNext = Proxy
     args =  fldUUID =: Nothing
         <+> fldReq =: Nothing
         <+> fldRep =: Nothing
         <+> fldInfoMsg =: Nothing
         <+> fldNext =: []

serviceStopJob :: Job ServiceStopRequestMsg ServiceStopRequestResult
serviceStopJob = Job "rc::service::stop"

-- | Request to stop service on a given node - this code updates
-- RG and stops service.
serviceStop :: Definitions RC ()
serviceStop = mkJobRule serviceStopJob  args $ \(JobHandle _ finish) -> do
   do_stop     <- phaseHandle "stopping service"
   do_stop_only <- phaseHandle "try to stop service without checking success"
   wait_cancel <- phaseHandle "wait_cancel"
   wait_exit   <- phaseHandle "wait_reply"
   wait_fail   <- phaseHandle "wait_fail"
   wait_exc    <- phaseHandle "wait_exception"
   wait_not_running <- phaseHandle "wait_not_running"
   wait_timed_out <- phaseHandle "wait_timed_out"

   let route msg = do
         (ServiceStopRequest node svc) <- decodeMsg msg
         mcfg <- node & Service.lookupInfoMsg $ svc
         case mcfg of
           Just cfg -> do
             tagContext Log.SM [ ("service.name", serviceName svc)
                                , ("service.node", show node)
                                ] Nothing
             Service.markStopping node cfg
             return $ Right (ServiceStopRequestCancelled, [do_stop])
           Nothing -> return $ Right (ServiceStopRequestOk, [do_stop_only])

   let loop = do
         t <- getHalonVar _hv_service_stop_timeout
         switch [ wait_cancel, wait_exit, wait_fail, wait_exc, wait_not_running
                , timeout t wait_timed_out ]

   directly do_stop_only $ do
      Just msg <- fromLocal fldReq
      ServiceStopRequest node svc <- decodeMsg msg
      tagContext Log.SM [ ("service.name", serviceName svc)
                        , ("service.node", show node)
                        ] Nothing
      Service.stop node svc
      continue finish

   directly do_stop $ do
      Just msg <- fromLocal fldReq
      ServiceStopRequest node svc <- decodeMsg msg
      Service.stop node svc
      loop

   let eqTT :: (Typeable a, Typeable b) => a -> b -> Maybe (a :~: b)
       eqTT _ _ = eqT
   let service_died node info = do
         ServiceInfo died_srv _ <- decodeMsg info
         Just mmsg <- fromLocal fldReq
         ServiceStopRequest stoppingNode stoppingSrv <- decodeMsg mmsg
         if node == stoppingNode
         then case eqTT died_srv stoppingSrv of
           Just Refl -> do
             putLocal fldRep ServiceStopRequestOk
             continue finish
           Nothing -> loop
         else loop
   setPhase wait_exit $ \(HAEvent _ (ServiceExit node info _)) ->
     service_died node info
   setPhase wait_fail $ \(HAEvent _ (ServiceFailed node info _)) ->
     service_died node info
   setPhase wait_exc  $ \(HAEvent _ (ServiceUncaughtException node info _ _)) ->
     service_died node info
   setPhase wait_not_running $ \(HAEvent _ (ServiceStopNotRunning tgtnode lbl)) -> do
     Just msg <- fromLocal fldReq
     ServiceStopRequest node svc <- decodeMsg msg
     unless (tgtnode == node && serviceLabel svc == lbl) loop
     mcfg <- node & Service.lookupInfoMsg $ svc
     for_ mcfg $ \cfg -> do
       node & Service.unregisterIfStopping $ cfg
       putLocal fldRep $ ServiceStopRequestOk
     continue finish

   setPhase wait_cancel $ \(HAEvent _ msg) -> do
     ServiceStartRequest _ startingNode startingSvc _ _ <- decodeMsg msg
     Just mmsg <- fromLocal fldReq
     (ServiceStopRequest stoppingNode stoppingSvc) <- decodeMsg mmsg
     if stoppingNode == startingNode
     then do
       case eqTT stoppingSvc startingSvc of
         Just Refl -> do
           putLocal fldRep ServiceStopRequestCancelled
           rcLog' Log.DEBUG "service stop was cancelled."
           continue finish
         Nothing -> loop
     else loop

   directly wait_timed_out $ do
     putLocal fldRep ServiceStopTimedOut
     rcLog' Log.WARN "service stop timed out"
     continue finish

   return route
   where
     takeField l = getField . rget l
     fromLocal l = takeField l <$> get Local
     putLocal l x = modify Local $ rlens l .~ Field (Just x)

     fldReq :: Proxy '("request", Maybe ServiceStopRequestMsg)
     fldReq = Proxy
     fldRep :: Proxy '("reply", Maybe ServiceStopRequestResult)
     fldRep = Proxy
     args =  fldUUID =: Nothing
         <+> fldReq =: Nothing
         <+> fldRep =: Nothing

-- | Request service status.
serviceStatus :: Definitions RC ()
serviceStatus = defineSimple "rc::service::status" $ \(HAEvent uuid msg) -> do
  ServiceStatusRequest node svc listeners <- decodeMsg msg
  minfo <- node & Service.lookupInfoMsg $ svc
  case minfo of
    Nothing -> do
      let response = encodeP SrvStatNotRunning
      liftProcess $ traverse_ (`usend` response) listeners
    Just _ -> do -- XXX: use current config
      processMsg <- mkMessageProcessed
      Service.requestStatusAsync node svc
        (\p -> traverse_ (`usend` p) listeners)
        (processMsg uuid)

ruleServiceCouldNotStart :: Definitions RC ()
ruleServiceCouldNotStart = defineSimpleTask "rc::service::could-not-start" $
  \(ServiceCouldNotStart node info) -> do
    ServiceInfo svc config <- decodeMsg info
    rcLog' Log.DEBUG [ ("service.name", serviceName svc)
                      , ("service.node", show node)
                      , ("service.config", show config)
                      ]
    void $ node & Service.unregisterIfStopping $ info

-- | Log service exit.
ruleServiceExit :: Definitions RC ()
ruleServiceExit = defineSimpleTask "rc::service::exit" $
  \(ServiceExit node info pid) -> do
    ServiceInfo svc config <- decodeMsg info
    rcLog' Log.DEBUG [ ("service.name", serviceName svc)
                      , ("service.node", show node)
                      , ("service.pid", show pid)
                      , ("service.config", show config)
                      ]
    void $ node & Service.unregister $ info

-- | If service have failed - try if it's the one that is registered
-- and if so - restart it.
ruleServiceFailed :: Definitions RC ()
ruleServiceFailed = defineSimpleTask "rc::service::failed" $
  \(ServiceFailed node info pid) -> do
    ServiceInfo svc config <- decodeMsg info
    rcLog' Log.WARN "service failed"
    rcLog' Log.DEBUG [ ("service.name", serviceName svc)
                      , ("service.node", show node)
                      , ("service.pid", show pid)
                      , ("service.config", show config)
                      ]
    node & Service.unregisterIfStopping $ info
    isCurrent <- node & Service.has $ info
    -- XXX: currently we restart service by default, we may want to be
    -- more clever and have some service specific logic here.
    when isCurrent $ node & Service.start $ info

-- | If service have failed - try if it's the one that is registered
-- and if so - restart it.
ruleServiceUncaughtException :: Definitions RC ()
ruleServiceUncaughtException = defineSimpleTask "rc::service::uncaught-exception" $
  \(ServiceUncaughtException node info reason pid) -> do
    ServiceInfo svc config <- decodeMsg info
    rcLog' Log.ERROR "service failed because of exception"
    rcLog' Log.DEBUG [ ("service.name", serviceName svc)
                      , ("service.node", show node)
                      , ("service.pid", show pid)
                      , ("service.config", show config)
                      , ("exception.text", reason)
                      ]
    node & Service.unregister $ info

-- | If service have started - continue execution.
ruleServiceStarted :: Definitions RC ()
ruleServiceStarted = defineSimpleTask "rc::service::started" $
  \(ServiceStarted node info pid) -> do
    ServiceInfo svc config <- decodeMsg info
    rcLog' Log.DEBUG [ ("service.name", serviceName svc)
                      , ("service.node", show node)
                      , ("service.pid", show pid)
                      , ("service.config", show config)
                      ]
    notify (ServiceStartedInternal node config pid)

ruleServiceMessageReceived :: Definitions RC ()
ruleServiceMessageReceived = defineSimple "rc::service::msg-received" $
  \(HAEvent uid wf) -> do
    rg <- getGraph
    lookupIfaceAndSend wf uid rg
  where
    -- Technically we could just find the interface without going
    -- through typeclass here.
    lookupIfaceAndSend :: WireFormat () -> UUID -> Graph -> PhaseM RC l ()
    lookupIfaceAndSend wf uid rg = if
      | serviceName (Mero.lookupM0d rg) == wfServiceName wf ->
          decodeAndSend wf (Mero.lookupM0d rg) uid
      | serviceName DLog.decisionLog == wfServiceName wf ->
          decodeAndSend wf DLog.decisionLog uid
      | serviceName SSPL.sspl == wfServiceName wf ->
          decodeAndSend wf SSPL.sspl uid
      | serviceName Ekg.ekg == wfServiceName wf ->
          decodeAndSend wf Ekg.ekg uid
      | serviceName Ping.ping == wfServiceName wf ->
          decodeAndSend wf Ping.ping uid
      | serviceName Noisy.noisy == wfServiceName wf ->
          decodeAndSend wf Noisy.noisy uid
      | serviceName SSPLHL.sspl == wfServiceName wf ->
          decodeAndSend wf SSPLHL.sspl uid
      | serviceName Dummy.dummy == wfServiceName wf ->
          decodeAndSend wf Dummy.dummy uid
      | otherwise -> do
          let msg :: String
              msg = printf "No interface found for %s" (wfServiceName wf)
          Log.rcLog' Log.WARN msg

    decodeAndSend (coerce -> wf) svc uid = case wfReceiverVersion wf of
      -- We got a message with wfReceiverVersion set which means it's
      -- a message we previously sent. Try to re-encode and send it
      -- back.
      Just{} -> do
        -- We have to coerce to toSvc because it turned out to be our
        -- message returned to us.
        returnToSvc (getInterface svc) (coerce wf)
        -- TODO: It's a bug that we have this here. We should add
        -- UUIDs of undecoded messages back into WireFormat so that we
        -- can acknowledge them when their correction comes. Otherwise
        -- we can lose messages if we acknowledge the message here and
        -- RC dies before message is actually sent. In general it's a
        -- hard problem because we can't rely on a service to ack a
        -- message nor are we replicating our send. Acking doesn't
        -- work without hooking up extra stuff to monitoring &c. too…
        messageProcessed uid
      Nothing -> do
        -- TODO: We should be able to rely on interface performing this
        -- check. See TODO on 'Interface'.
        if ifVersion (getInterface svc) >= wfSenderVersion wf
        then case ifDecodeFromSvc (getInterface svc) wf of
          -- We send an non-persisted HAEvent. This is okay because it
          -- uses the UUID of persisted HAEvent WireFormat: if RC
          -- restarts, this rule will re-run and we'll resend service
          -- message. If message gets processed, the WireFormat gets
          -- processed. It also means SafeCopy can be bypassed: the
          -- sender is not required to give instances for the types it
          -- uses if it doesn't wish to do so.
          DecodeOk msg -> selfMessage $! HAEvent uid msg
          DecodeVersionMismatch -> returnSvcMsg (getInterface svc) wf
          DecodeFailed err -> do
            let msg :: String
                msg = printf "%s interface failed to decode %s: %s"
                             (wfServiceName wf) (show wf) err
            Log.rcLog' Log.ERROR msg
        else returnSvcMsg (getInterface svc) wf
