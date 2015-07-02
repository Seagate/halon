-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}

module HA.RecoveryCoordinator.Actions.Service
  ( -- * Querying services
    lookupRunningService
  , isServiceRunning
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
import HA.NodeAgent.Messages (ExitReason(..))
import HA.RecoveryCoordinator.Actions.Core
import qualified HA.ResourceGraph as G
import HA.Resources
import HA.Service

import Control.Category ((>>>))
import Control.Distributed.Process
  ( DidSpawn(..)
  , NodeId
  , Process
  , closure
  , exit
  , getSelfNode
  , matchIf
  , receiveTimeout
  , spawnAsync
  , spawnLocal
  )
import Control.Distributed.Process.Closure ( mkClosure, staticDecode )
import Control.Distributed.Static (closureApply)
import Control.Monad (void)

import Data.Binary (encode)

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
            killService sp Shutdown
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
_startService node svc cfg _ = void $ spawnLocal $ do
    spawnRef <- spawnAsync node $
              $(mkClosure 'remoteStartService) (serviceName svc)
            `closureApply`
              (serviceProcess svc
                 `closureApply` closure (staticDecode sDict) (encode cfg))
    mpid <- receiveTimeout 1000000
              [ matchIf (\(DidSpawn r _) -> r == spawnRef)
                        (\(DidSpawn _ pid) -> return pid)
              ]
    mynid <- getSelfNode
    case mpid of
      Nothing -> do
        void . promulgateEQ [mynid] . encodeP $
          ServiceCouldNotStart (Node node) svc cfg
      Just pid -> do
        void . promulgateEQ [mynid] . encodeP $
          ServiceStarted (Node node) svc cfg (ServiceProcess pid)
