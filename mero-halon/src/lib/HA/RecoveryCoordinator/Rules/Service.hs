-- |
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- CEP Rules pertaining to the management of Halon internal services.
--

{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE TypeOperators             #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE FlexibleContexts          #-}

module HA.RecoveryCoordinator.Rules.Service
  ( rules ) where

import Prelude hiding ((.), id)
import Control.Category
import Control.Lens
import Data.Foldable (traverse_)

import           Control.Distributed.Process
import           Network.CEP

import           HA.EventQueue.Types
import           HA.RecoveryCoordinator.Mero
import           HA.Encode (encodeP)
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
  )

import HA.RecoveryCoordinator.Events.Service
import HA.RecoveryCoordinator.Job.Actions
import qualified HA.RecoveryCoordinator.Actions.Service as Service

import Control.Monad (when, unless)
import Data.Functor (void)
import Data.Proxy
import Data.Vinyl hiding ((:~:))
import Data.SafeCopy
import Data.Serialize.Put (runPutLazy)
import Data.Typeable ((:~:), eqT, Typeable, (:~:)(Refl))
import Data.Foldable (for_)

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
  ]

serviceStartJob :: Job ServiceStartRequestMsg ServiceStartRequestResult
serviceStartJob = Job "rc::service::start"

-- | Register service on the node and request monitor to start that
-- service. Rule will exit when either service will be started on the
-- node, or request to stop service will arrive.
--
-- In case if node is not yet known - process will exit.
serviceStart :: Definitions RC ()
serviceStart = mkJobRule serviceStartJob  args $ \finish -> do
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
                    return $ Just [do_restart]
            else do
              mcfg <- Service.lookupConfig node svc
              case mcfg of
                Just c | c /= conf -> do
                  announce AttemptingToRestart listeners
                  return $ Just [do_restart]
                _ -> do
                  announce AttemptingToStart listeners
                  return $ Just [do_register]
         else do
           phaseLog "warning" "Unknown node - ignoring."
           announce NodeUnknown listeners
           return Nothing

   let loop = do
         next <- fromLocal fldNext
         switch (wait_cancel:next)

   directly do_restart $ do
     Just msg <- fromLocal fldReq
     ServiceStartRequest _ node svc a _ <- decodeMsg msg
     phaseLog "service.node" $ show node
     phaseLog "service.name" $ serviceName svc
     phaseLog "service.config" $ show a
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
     phaseLog "info" "service start"
     phaseLog "service.node"   $ show node
     phaseLog "service.name"   $ serviceName svc
     phaseLog "service.config" $ show conf
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
           phaseLog "info" "service start was cancelled."
           phaseLog "end" "service start"
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
           phaseLog "info" "Service started"
           phaseLog "info" $ "service.pid = " ++ show pid
           phaseLog "end"  $ "service start"
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
serviceStop = mkJobRule serviceStopJob  args $ \finish -> do
   do_stop     <- phaseHandle "stopping service"
   do_stop_only <- phaseHandle "try to stop service without checking success"
   wait_cancel <- phaseHandle "wait_cancel"
   wait_exit   <- phaseHandle "wait_reply"
   wait_fail   <- phaseHandle "wait_fail"
   wait_exc    <- phaseHandle "wait_exception"
   wait_not_running <- phaseHandle "wait_not_running"

   let route msg = do
         (ServiceStopRequest node svc) <- decodeMsg msg
         mcfg <- node & Service.lookupInfoMsg $ svc
         case mcfg of
           Just cfg -> do
             phaseLog "info" "service stop"
             phaseLog "service.name" $ serviceName svc
             phaseLog "service.node" $ show node
             Service.markStopping node cfg
             return $ Just [do_stop]
           Nothing -> return $ Just [do_stop_only]

   let loop = switch [wait_cancel, wait_exit, wait_fail, wait_exc, wait_not_running]

   directly do_stop_only $ do
      Just msg <- fromLocal fldReq
      ServiceStopRequest node svc <- decodeMsg msg
      phaseLog "service.name" $ serviceName svc
      phaseLog "service.node" $ show node
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
             putLocal fldRep $ ServiceStopRequestOk
             phaseLog "end"  $ "service stop"
             continue finish
           Nothing -> loop
         else loop
   setPhase wait_exit $ \(HAEvent _ (ServiceExit node info _)) ->
     service_died  node info
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
           putLocal fldRep $ ServiceStopRequestCancelled
           phaseLog "info" "service stop was cancelled."
           phaseLog "end" "service stop"
           continue finish
         Nothing -> loop
     else loop

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
    phaseLog "service.name" $ serviceName svc
    phaseLog "service.node" $ show node
    phaseLog "service.config" $ show config
    void $ node & Service.unregisterIfStopping $ info

-- | Log service exit.
ruleServiceExit :: Definitions RC ()
ruleServiceExit = defineSimpleTask "rc::service::exit" $
  \(ServiceExit node info pid) -> do
    ServiceInfo svc config <- decodeMsg info
    phaseLog "info" $ "service exit"
    phaseLog "service.name" $ serviceName svc
    phaseLog "service.node" $ show node
    phaseLog "service.pid"  $ show pid
    phaseLog "service.config" $ show config
    void $ node & Service.unregister $ info

-- | If service have failed - try if it's the one that is registered
-- and if so - restart it.
ruleServiceFailed :: Definitions RC ()
ruleServiceFailed = defineSimpleTask "rc::service::failed" $
  \(ServiceFailed node info pid) -> do
    ServiceInfo svc config <- decodeMsg info
    phaseLog "warning" $ "service failed"
    phaseLog "service.name" $ serviceName svc
    phaseLog "service.node" $ show node
    phaseLog "service.pid"  $ show pid
    phaseLog "service.config" $ show config
    node & Service.unregisterIfStopping $ info
    isCurrent <- node & Service.has $ info
    -- XXX: currently we restart service by default, we may want to be
    -- more clever and have some service specific logic here.
    when isCurrent $ node & Service.start $ info

-- | If service have failed - try if it's the one that is registered
-- and if so - restart it.
ruleServiceUncaughtException :: Definitions RC ()
ruleServiceUncaughtException = defineSimpleTask "rc::service::uncaugh-exception" $
  \(ServiceUncaughtException node info reason pid) -> do
    ServiceInfo svc config <- decodeMsg info
    phaseLog "error" $ "service failed because of exception"
    phaseLog "service.name"   $ serviceName svc
    phaseLog "service.node"   $ show node
    phaseLog "service.pid"    $ show pid
    phaseLog "service.config" $ show config
    phaseLog "exception.text" $ reason
    node & Service.unregister $ info

-- | If service have started - continue execution.
ruleServiceStarted :: Definitions RC ()
ruleServiceStarted = defineSimpleTask "rc::service::started" $
  \(ServiceStarted node info pid) -> do
    ServiceInfo svc config <- decodeMsg info
    phaseLog "service.name"   $ serviceName svc
    phaseLog "service.node"   $ show node
    phaseLog "service.pid"    $ show pid
    phaseLog "service.config" $ show config
    notify (ServiceStartedInternal node config pid)
