-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeOperators              #-}

module HA.RecoveryCoordinator.Actions.Service
  ( -- * Querying services
    lookupRunningService
  , isServiceRunning
  , findRunningServiceProcesses
  , getRunningServices
  , getNodeRegularMonitors
    -- * Registering services in the graph
  , registerService
  , registerServiceName
  , registerServiceProcess
  , unregisterServiceProcess
  , writeConfiguration
    -- * Controlling services
  , startService
  , bounceServiceTo
  , killService
  ) where

import HA.EventQueue.Producer (promulgateEQ)
import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Hardware (nodesOnHost)
import qualified HA.ResourceGraph as G
import HA.Resources
import HA.Service
import HA.Services.Monitor (MonitorConf)

import Control.Category ((>>>))
import Control.Distributed.Process
  ( NodeId
  , Process
  , closure
  , exit
  , expectTimeout
  , getSelfNode
  , getSelfPid
  , spawnAsync
  , spawnLocal
  , link
  )
import Control.Distributed.Process.Closure ( mkClosure, staticDecode )
import Control.Distributed.Process.Internal.Types as DP ( remoteTable, processNode )
import Control.Distributed.Static (closureApply, unstatic)
import Control.Monad (void, join)
import Control.Monad.Reader (asks)

import Data.Binary (encode)
import Data.Maybe (catMaybes, mapMaybe, listToMaybe)
import Data.Typeable (Typeable, cast, gcast)


import Network.CEP hiding (get, put)

----------------------------------------------------------
-- Querying services                                    --
----------------------------------------------------------

-- | Lookup the ServiceProcess for a process on a node.
lookupRunningService :: Configuration a
                     => Node
                     -> Service a
                     -> PhaseM LoopState l (Maybe (ServiceProcess a))
lookupRunningService n svc = fmap (runningService n svc) getLocalGraph

-- | Test if a given service is running on a node.
isServiceRunning :: Configuration a
                 => Node
                 -> Service a
                 -> PhaseM LoopState l Bool
isServiceRunning n svc =
    fmap (maybe False (const True)) $ lookupRunningService n svc


-- | Given a 'Service', find all the corresponding 'ServiceProcess'es
-- across all the nodes.
findRunningServiceProcesses :: Configuration a
                   => Service a
                   -> PhaseM LoopState l [ServiceProcess a]
findRunningServiceProcesses svc = do
  phaseLog "rg-query" $ "Looking for all running services: " ++ show svc
  rg <- getLocalGraph
  nodes <- concat <$> mapM nodesOnHost (G.connectedTo Cluster Has rg)
  catMaybes <$> mapM (`lookupRunningService` svc) nodes

----------------------------------------------------------
-- Registering services in the graph                    --
----------------------------------------------------------

registerService :: Configuration a
                => Service a
                -> PhaseM LoopState l ()
registerService svc = modifyLocalGraph $ \rg -> do
    phaseLog "rg" $ "Registering service: "
                ++ (snString $ serviceName svc)
    let rg' = G.newResource svc >>>
              G.connect Cluster Supports svc $ rg
    return rg'

registerServiceName :: Configuration a
                    => Service a
                    -> PhaseM LoopState l ()
registerServiceName svc = modifyLocalGraph $ \rg -> do
    phaseLog "rg" $ "Registering service name: " ++ (snString $ serviceName svc)
    return $ G.newResource (serviceName svc) rg

registerServiceProcess :: Configuration a
                       => Node
                       -> Service a
                       -> a
                       -> ServiceProcess a
                       -> PhaseM LoopState l ()
registerServiceProcess n svc cfg sp = modifyLocalGraph $ \rg -> do
    phaseLog "rg" $ "Registering service process for service "
                ++ (snString $ serviceName svc)
                ++ " on node " ++ show n

    let rg' = G.newResource sp                    >>>
              G.connect n Runs sp                 >>>
              G.connect svc InstanceOf sp         >>>
              G.connect sp Owns (serviceName svc) >>>
              writeConfig sp cfg Current $ rg

    return rg'

-- | Unregister a service process from the resource graph.
--   This is typically called when a service dies to remove the
--   node representing it from the graph.
unregisterServiceProcess :: Configuration a
                                 => Node
                                 -> Service a
                                 -> ServiceProcess a
                                 -> PhaseM LoopState l ()
unregisterServiceProcess n svc sp = modifyLocalGraph $ \rg -> do
    phaseLog "rg" $ "Unregistering service process for service "
                ++ (snString $ serviceName svc)
                ++ " on node " ++ show n

    let rg' = G.disconnect sp Owns (serviceName svc) >>>
              disconnectConfig sp Current            >>>
              G.disconnect n Runs sp                 >>>
              G.disconnect svc InstanceOf sp $ rg

    return rg'

-- | Write the configuration into the resource graph.
writeConfiguration :: Configuration a
                   => ServiceProcess a
                   -> a
                   -> ConfigRole
                   -> PhaseM LoopState l ()
writeConfiguration sp c role = modifyLocalGraph $ \rg -> do
    let rg' = disconnectConfig sp role >>>
              writeConfig sp c role $ rg

    return rg'

-- | Get all services running on a node, for each service create
-- a 'ServiceStartedMsg' that could be sent further to monitor.
getRunningServices :: Node -> PhaseM LoopState l [ServiceStartedMsg]
getRunningServices node = do
  rg <- getLocalGraph
  rt <- liftProcess $ asks (remoteTable . processNode)

  let spMatch :: (Typeable a, Typeable b) => a -> b -> Maybe (ServiceProcess a)
      spMatch _ = cast

      srvMatch :: (Typeable a, Typeable b) => a -> b -> Maybe (Service a)
      srvMatch _ = cast

      dictMatch :: (Typeable a, Typeable b) => a -> G.Dict (Configuration b)
                -> Maybe (G.Dict (Configuration a))
      dictMatch _ = gcast

      dynMkMessage :: G.Res -> G.Res -> G.Res -> Maybe ServiceStartedMsg
      dynMkMessage (G.Res dsp) (G.Res cfg) (G.Res srv) = join $
        mkMessage cfg <$> (spMatch cfg dsp) <*> (srvMatch cfg srv)

      mkMessage :: Typeable a => a -> ServiceProcess a -> Service a
                -> Maybe ServiceStartedMsg
      mkMessage cfg sp srv = case unstatic rt (configDict srv) of
        Right (SomeConfigurationDict d@G.Dict) ->
          (\G.Dict -> encodeP (ServiceStarted node srv cfg sp))
             <$> (dictMatch cfg d)
        Left _ -> Nothing

  return $ flip mapMaybe (G.anyConnectedTo node Runs rg) $ \r@(G.Res dsp) ->
    let mcfg  = listToMaybe $ G.anyConnectedTo dsp HasConf rg
        msrv  = listToMaybe $ G.anyConnectedFrom InstanceOf dsp rg
    in (join $ dynMkMessage r <$> mcfg <*> msrv :: Maybe ServiceStartedMsg)


-- | Get Monitor Service for each running node.
getNodeRegularMonitors :: PhaseM LoopState l [ServiceStartedMsg]
getNodeRegularMonitors = do
  rg <- getLocalGraph
  return [ encodeP (ServiceStarted node srv cfg sp)
         | node <- G.connectedTo Cluster Has rg
         , sp   <- G.connectedTo node Runs rg :: [ServiceProcess MonitorConf]
         , Just cfg <- return $ listToMaybe $ G.connectedTo sp HasConf rg
         , Just srv <- return $ listToMaybe $ G.connectedFrom InstanceOf sp rg
         ]

----------------------------------------------------------
-- Controlling services                                 --
----------------------------------------------------------

-- | Start a service with the given configuration on the specified node.
startService :: Configuration a
             => NodeId
             -> Service a
             -> a
             -> PhaseM LoopState l ()
startService n svc conf = do
    phaseLog "action" $ "Starting " ++ (snString $ serviceName svc)
                    ++ " on node "
                    ++ show n
    liftProcess . _startService n svc conf =<< getLocalGraph

-- | Bounce a service directly to the given configuration.
--   Fails with an error if the service is not currently running,
--   or if the specified configuration cannot be found in the
--   graph.
bounceServiceTo :: Configuration a
                => ConfigRole
                -> Node
                -> Service a
                -> PhaseM LoopState l ()
bounceServiceTo role n@(Node nid) s = do
    phaseLog "action" $ "Bouncing service " ++ show s
                    ++ " on node " ++ show nid
    _bounceServiceTo =<< getLocalGraph
  where
    _bounceServiceTo g =
        case runningService n s g of
            Just sp -> go sp
            Nothing -> error "Cannot bounce non-existent service."
      where
        go sp = case readConfig sp role g of
          Just cfg -> do
            killService sp Fail
            startService nid s cfg
          Nothing -> error "Cannot find specified configuation"

-- | Kill a service.
killService :: ServiceProcess a
            -> ExitReason
            -> PhaseM g l ()
killService (ServiceProcess pid) reason = do
  phaseLog "action" $ "Killing service with pid " ++ show pid
                  ++ " because of " ++ show reason
  liftProcess $ exit pid reason

----------------------------------------------------------
-- Utility functions (unexported)                       --
----------------------------------------------------------

_startService :: forall a. Configuration a
             => NodeId -- ^ Node to start service on
             -> Service a -- ^ Service
             -> a
             -> G.Graph
             -> Process ()
_startService node svc cfg _ = void $ do
  caller <- getSelfPid
  spawnLocal $ do
    link caller
    self <- getSelfPid
    _ <- spawnAsync node $
              $(mkClosure 'remoteStartService) (self, serviceName svc)
            `closureApply`
              (serviceProcess svc
                 `closureApply` closure (staticDecode sDict) (encode cfg))
    mpid <- expectTimeout 1000000
    mynid <- getSelfNode
    case mpid of
      Nothing ->
        void . promulgateEQ [mynid] . encodeP $
          ServiceCouldNotStart (Node node) svc cfg
      Just pid ->
        void . promulgateEQ [mynid] . encodeP $
          ServiceStarted (Node node) svc cfg (ServiceProcess pid)
