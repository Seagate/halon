-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}

module HA.RecoveryCoordinator.Actions.Service
  ( ReconfigureCmd(..)
    -- * Querying services
  , lookupRunningService
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
  , reconfigureService
    -- * Temporary internals
  , _startService
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
  , RemoteTable
  , closure
  , exit
  , getSelfNode
  , getSelfPid
  , matchIf
  , receiveTimeout
  , spawnAsync
  , spawnLocal
  , usend
  )
import Control.Distributed.Process.Closure ( mkClosure, staticDecode )
import Control.Distributed.Process.Internal.Types ( processNode, remoteTable )
import Control.Distributed.Static (closureApply, unstatic)
import Control.Monad (void)
import Control.Monad.Reader (ask)
import qualified Control.Monad.State.Strict as State

import Data.Binary (Binary, Get, encode, get, put)
import Data.Binary.Put (runPut)
import Data.Binary.Get (runGet)
import qualified Data.ByteString.Lazy as BS
import Data.List (intersect, foldl')
import Data.Typeable

import Network.CEP

-- | Reconfiguration message
data ReconfigureCmd = forall a. Configuration a => ReconfigureCmd Node (Service a)
  deriving (Typeable)

newtype ReconfigureMsg = ReconfigureMsg BS.ByteString
  deriving (Typeable, Binary)

instance ProcessEncode ReconfigureCmd where
  type BinRep ReconfigureCmd = ReconfigureMsg

  decodeP (ReconfigureMsg bs) = let
      get_ :: RemoteTable -> Get ReconfigureCmd
      get_ rt = do
        d <- get
        case unstatic rt d of
          Right (SomeConfigurationDict (G.Dict :: G.Dict (Configuration s))) -> do
            rest <- get
            let (node, svc) = extract rest
                extract :: (Node, Service s) -> (Node, Service s)
                extract = id
            return $ ReconfigureCmd node svc
          Left err -> error $ "decode ReconfigureCmd: " ++ err
    in do
      rt <- fmap (remoteTable . processNode) ask
      return $ runGet (get_ rt) bs

  encodeP (ReconfigureCmd node svc@(Service _ _ d)) =
    ReconfigureMsg . runPut $ put d >> put (node, svc)

----------------------------------------------------------
-- Querying services                                    --
----------------------------------------------------------

-- | Lookup the ServiceProcess for a process on a node.
lookupRunningService :: Configuration a
                     => Node
                     -> Service a
                     -> CEP LoopState (Maybe (ServiceProcess a))
lookupRunningService n svc = State.gets (runningService n svc . lsGraph)

-- | Test if a given service is running on a node.
isServiceRunning :: Configuration a
                 => Node
                 -> Service a
                 -> CEP LoopState Bool
isServiceRunning n svc =
    fmap (maybe False (const True)) $ lookupRunningService n svc

----------------------------------------------------------
-- Registering services in the graph                    --
----------------------------------------------------------

registerService :: Configuration a
                => Service a
                -> CEP LoopState ()
registerService svc = do
    cepLog "rg" $ "Registering service: "
                ++ (snString $ serviceName svc)
    ls <- State.get
    let rg' = G.newResource svc >>>
              G.connect Cluster Supports svc $ lsGraph ls
    State.put ls { lsGraph = rg' }

registerServiceName :: Configuration a
                    => Service a
                    -> CEP LoopState ()
registerServiceName svc = do
    cepLog "rg" $ "Registering service name: " ++ (snString $ serviceName svc)
    ls <- State.get
    let rg' = G.newResource (serviceName svc) $ lsGraph ls
    State.put ls { lsGraph = rg' }

registerServiceProcess :: Configuration a
                       => Node
                       -> Service a
                       -> a
                       -> ServiceProcess a
                       -> CEP LoopState ()
registerServiceProcess n svc cfg sp = do
    cepLog "rg" $ "Registering service process for service "
                ++ (snString $ serviceName svc)
                ++ " on node " ++ show n
    ls <- State.get
    let rg' = G.newResource sp                    >>>
              G.connect n Runs sp                 >>>
              G.connect svc InstanceOf sp         >>>
              G.connect sp Owns (serviceName svc) >>>
              writeConfig sp cfg Current $ lsGraph ls

    State.put ls { lsGraph = rg' }

-- | Unregister a service process from the resource graph.
--   This is typically called when a service dies to remove the
--   node representing it from the graph.
unregisterServiceProcess :: Configuration a
                                 => Node
                                 -> Service a
                                 -> ServiceProcess a
                                 -> CEP LoopState ()
unregisterServiceProcess n svc sp = do
    cepLog "rg" $ "Unregistering service process for service "
                ++ (snString $ serviceName svc)
                ++ " on node " ++ show n
    ls <- State.get
    let rg' = G.disconnect sp Owns (serviceName svc) >>>
              disconnectConfig sp Current            >>>
              G.disconnect n Runs sp                 >>>
              G.disconnect svc InstanceOf sp $ lsGraph ls
    State.put ls { lsGraph = rg' }

-- | Write the configuration into the resource graph.
writeConfiguration :: Configuration a
                   => ServiceProcess a
                   -> a
                   -> ConfigRole
                   -> CEP LoopState ()
writeConfiguration sp c role = do
    ls <- State.get
    let rg' =   disconnectConfig sp role
            >>> writeConfig sp c role $ lsGraph ls
    State.put ls { lsGraph = rg' }

----------------------------------------------------------
-- Controlling services                                 --
----------------------------------------------------------

-- | Start a service with the given configuration on the specified node.
startService :: Configuration a
             => NodeId
             -> Service a
             -> a
             -> CEP LoopState ()
startService n svc conf = do
    cepLog "action" $ "Starting " ++ (snString $ serviceName svc) ++ " on node "
                    ++ show n
    liftProcess . _startService n svc conf . lsGraph =<< State.get

-- | Bounce a service directly to the given configuration.
--   Fails with an error if the service is not currently running,
--   or if the specified configuration cannot be found in the
--   graph.
bounceServiceTo :: Configuration a
                => ConfigRole
                -> Node
                -> Service a
                -> CEP LoopState ()
bounceServiceTo role n@(Node nid) s = do
    cepLog "action" $ "Bouncing service " ++ show s
                    ++ " on node " ++ show nid
    _bounceServiceTo . lsGraph =<< State.get
  where
    _bounceServiceTo g = case runningService n s g of
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
            -> CEP s ()
killService (ServiceProcess pid) reason = do
  cepLog "action" $ "Killing service with pid " ++ show pid
                  ++ " because of " ++ show reason
  liftProcess $ exit pid reason

-- | Reconfigure a service.
--   This records the new configuration in the resource graph, and then sends
--   an additional message to the recovery coordinator asking it to perform
--   the actual reconfiguration.
-- TODO rewrite this to be more composable.
reconfigureService :: Configuration a
                   => a
                   -> Service a
                   -> NodeFilter
                   -> CEP LoopState ()
reconfigureService opts svc nodeFilter = do
    cepLog "rg" $ "Updating configuration for service "
                ++ (snString $ serviceName svc)
                ++ " on nodes "
                ++ show nodeFilter
    ls <- State.get

    let rg       = lsGraph ls
        svcs     = _filterServices nodeFilter svc rg
        fns      = fmap (\(_, nsvc) -> writeConfig nsvc opts Intended) svcs
        rgUpdate = foldl' (flip (.)) id fns
        rg'      = rgUpdate rg

    liftProcess $ do
      self <- getSelfPid
      mapM_ (usend self . encodeP . (flip ReconfigureCmd) svc . fst) svcs

    State.put ls { lsGraph = rg' }

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

-- | Starting from the root node, find nodes and services matching the given
--   ConfigurationFilter (not really important how this is specified) and
--   the type of the configuration.
_filterServices :: forall a. Configuration a
                => NodeFilter
                -> Service a
                -> G.Graph
                -> [(Node, ServiceProcess a)]
_filterServices (NodeFilter nids) (Service name _ _) rg = do
  node <- filter (\(Node nid) -> nid `elem` nids) $
              G.connectedTo Cluster Has rg :: [Node]
  svc <- filter (\(Service n _ _) -> n == name) $
              (G.connectedTo Cluster Supports rg :: [Service a])
  sp <- intersect
          (G.connectedTo svc InstanceOf rg :: [ServiceProcess a])
          (G.connectedTo node Runs rg :: [ServiceProcess a])
  return (node, sp)
