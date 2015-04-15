{-# LANGUAGE TypeOperators #-}
-- |
-- Copyright : (C) 2013,2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- * Recovery coordinator
--
-- LEGEND: RC - recovery coordinator, R - replicator, RG - resource graph.
--
-- Behaviour of RC is determined by the state of RG and incoming HA events that
-- are posted by R from the event queue maintained by R. After recovering an HA
-- event, RC instructs R to drop the event, using a globally unique identifier.

{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE CPP                        #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}

{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module HA.RecoveryCoordinator.Mero
       ( IgnitionArguments(..)
       , LoopState(..)
       , ReconfigureCmd(..)
       , ReconfigureMsg
       , GetMultimapProcessId(..)
       , sayRC
       , knownResource
       , registerNode
       , startEQTracker
       , ack
       , lookupRunningService
       , isServiceRunning
       , registerService
       , startService
       , getSelfProcessId
       , sendMsg
       , unregisterPreviousServiceProcess
       , registerServiceName
       , registerServiceProcess
       , makeRecoveryCoordinator
       , prepareEpochResponse
       , updateServiceConfiguration
       , getEpochId
       , decodeMsg
       , bounceServiceTo
       , lookupDLogServiceProcess
         -- * Host related functions
       , locateNodeOnHost
       , registerHost
       , registerInterface
       , nodesOnHost
       , findHosts
         -- * Drive related functions
       , driveStatus
       , registerDrive
       , updateDriveStatus
       , getMultimapProcessId
       , getNoisyPingCount
       , killService
       ) where

import Prelude hiding ((.), id, mapM_)
import HA.Resources
import HA.Service
import HA.Services.DecisionLog
import HA.Services.Empty
import HA.Services.Noisy

import HA.Resources.Mero

import HA.NodeAgent.Messages
import qualified HA.Services.EQTracker as EQT

import HA.EventQueue.Producer (promulgateEQ)
import qualified HA.ResourceGraph as G

import Control.Distributed.Process hiding (send)
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Internal.Types ( remoteTable, processNode )
import Control.Distributed.Process.Serializable
import Control.Distributed.Static (closureApply, unstatic)
import Control.Monad.Reader (ask)
import qualified Control.Monad.State.Strict as State

import Control.Monad
import Control.Wire hiding (when)

import Data.Binary (Binary, Get, encode, get, put)
import Data.Binary.Put (runPut)
import Data.Binary.Get (runGet)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BS
import Data.Dynamic
import Data.List (intersect, foldl')
import qualified Data.Map.Strict as Map
#ifdef USE_RPC
import Data.Maybe (isJust)
#endif
import Data.Word

import GHC.Generics (Generic)

import Network.CEP

import Text.Regex.TDFA ((=~))

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

-- | Initial configuration data.
data IgnitionArguments = IgnitionArguments
  { -- | The names of all tracking station nodes.
    stationNodes :: [NodeId]
  } deriving (Generic,Typeable)

instance Binary IgnitionArguments

-- | An internal message type.
data NodeAgentContacted = NodeAgentContacted ProcessId
         deriving (Typeable, Generic)

instance Binary NodeAgentContacted

data GetMultimapProcessId =
    GetMultimapProcessId ProcessId deriving (Typeable, Generic)

instance Binary GetMultimapProcessId

reconfFailureLimit :: Int
reconfFailureLimit = 3

knownResource :: G.Resource a => a -> CEP LoopState Bool
knownResource res = do
    ls <- State.get
    return $ G.memberResource res (lsGraph ls)

-- | Register a new satellite node in the cluster.
registerNode :: Node -> CEP LoopState ()
registerNode node = do
    cepLog "rg" $ "Registering satellite node: " ++ show node
    rg <- State.gets lsGraph

    let rg' = G.newResource node                       >>>
              G.connect Cluster Has node $ rg

    State.modify $ \ls -> ls { lsGraph = rg' }

startEQTracker :: NodeId -> CEP LoopState ()
startEQTracker nid = do
    cepLog "action" $ "Starting " ++ EQT.name ++ " on node " ++ show nid
    State.gets lsGraph >>= \rg -> liftProcess $ do
      sayRC $ "New node contacted: " ++ show nid
      _startService nid EQT.eqTracker EmptyConf rg

ack :: ProcessId -> CEP LoopState ()
ack pid = liftProcess $ usend pid ()

lookupRunningService :: Configuration a
                     => Node
                     -> Service a
                     -> CEP LoopState (Maybe (ServiceProcess a))
lookupRunningService n svc =
    fmap (runningService n svc . lsGraph) State.get

isServiceRunning :: Configuration a
                 => Node
                 -> Service a
                 -> CEP LoopState Bool
isServiceRunning n svc =
    fmap (maybe False (const True)) $ lookupRunningService n svc

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

startService :: Configuration a
             => NodeId
             -> Service a
             -> a
             -> CEP LoopState ()
startService n svc conf = do
    cepLog "action" $ "Starting " ++ (snString $ serviceName svc) ++ " on node "
                    ++ show n
    liftProcess . _startService n svc conf . lsGraph =<< State.get

unregisterPreviousServiceProcess :: Configuration a
                                 => Node
                                 -> Service a
                                 -> ServiceProcess a
                                 -> CEP LoopState ()
unregisterPreviousServiceProcess n svc sp = do
    cepLog "rg" $ "Unregistering previous service process for service "
                ++ (snString $ serviceName svc)
                ++ " on node " ++ show n
    ls <- State.get
    let rg' = G.disconnect sp Owns (serviceName svc) >>>
              G.disconnect n Runs sp                 >>>
              G.disconnect svc InstanceOf sp $ lsGraph ls
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

getSelfProcessId :: CEP s ProcessId
getSelfProcessId = liftProcess getSelfPid

-- | Register a new drive in the system.
registerDrive :: Enclosure
              -> StorageDevice
              -> CEP LoopState ()
registerDrive enc dev = do
  cepLog "rg" $ "Registering storage device: "
              ++ show dev
              ++ " in enclosure "
              ++ show enc
  ls <- State.get
  let rg' = G.newResource enc
        >>> G.newResource dev
        >>> G.connect Cluster Has enc
        >>> G.connect enc Has dev
          $ lsGraph ls
  State.put ls { lsGraph = rg' }

-- | Register a new host in the system.
registerHost :: Host
             -> CEP LoopState ()
registerHost host = do
  cepLog "rg" $ "Registering host: "
              ++ show host
  ls <- State.get
  let rg' = G.newResource host
        >>> G.connect Cluster Has host
          $ lsGraph ls
  State.put ls { lsGraph = rg' }

findHosts :: String
          -> CEP LoopState [Host]
findHosts regex = do
  cepLog "rg-query" $ "Looking for hosts matching regex " ++ regex
  g <- State.gets lsGraph
  return $ [ host | host@(Host hn) <- G.connectedTo Cluster Has g
                  , hn =~ regex]

-- | Find all nodes running on the given host.
nodesOnHost :: Host
            -> CEP LoopState [Node]
nodesOnHost host = do
  cepLog "rg-query" $ "Looking for nodes on host " ++ show host
  State.gets $ G.connectedTo host Runs . lsGraph

-- | Register an interface on a host.
registerInterface :: Host -- ^ Host on which the interface resides.
                  -> Interface
                  -> CEP LoopState ()
registerInterface host int = do
  cepLog "rg" $ "Registering interface on host " ++ show host
  ls <- State.get
  let rg' = G.newResource host
        >>> G.newResource int
        >>> G.connect host Has int
          $ lsGraph ls
  State.put ls { lsGraph = rg' }

-- | Record that a node is running on a host.
locateNodeOnHost :: Node
                 -> Host
                 -> CEP LoopState ()
locateNodeOnHost node host = do
  cepLog "rg" $ "Locating node " ++ (show node) ++ " on host "
              ++ show host
  ls <- State.get
  let rg' = G.connect host Runs node
          $ lsGraph ls
  State.put ls { lsGraph = rg' }

-- | Get the status of a storage device.
driveStatus :: StorageDevice
            -> CEP LoopState (Maybe StorageDeviceStatus)
driveStatus dev = do
  cepLog "rg-query" $ "Querying status of device " ++ show dev
  ls <- State.get
  return $ case G.connectedTo dev Is (lsGraph ls) of
    [a] -> Just a
    _ -> Nothing

-- | Update the status of a storage device.
updateDriveStatus :: StorageDevice
                  -> String
                  -> CEP LoopState ()
updateDriveStatus dev status = do
  cepLog "rg" $ "Updating status for device " ++ show dev ++ " to " ++ status
  ls <- State.get
  ds <- driveStatus dev
  cepLog "rg" $ "Old status was " ++ show ds
  let statusNode = StorageDeviceStatus status
      removeOldNode = case ds of
        Just f -> G.disconnect dev Is f
        Nothing -> id
      rg' = G.newResource statusNode
        >>> G.connect dev Is statusNode
        >>> removeOldNode
          $ lsGraph ls
  State.put ls { lsGraph = rg' }

getNoisyPingCount :: CEP LoopState Int
getNoisyPingCount = do
    cepLog "rg-query" $ ("Querying noisy ping count." :: BS.ByteString)
    ls <- State.get
    let rg       = lsGraph ls
        (rg', i) =
          case G.connectedTo noisy HasPingCount rg of
            [] ->
              let nrg = G.connect noisy HasPingCount (NoisyPingCount 0) $
                        G.newResource (NoisyPingCount 0) rg in
              (nrg, 0)
            pc@(NoisyPingCount iPc) : _ ->
              let newPingCount = NoisyPingCount (iPc + 1)
                  nrg = G.connect noisy HasPingCount newPingCount $
                        G.newResource newPingCount $
                        G.disconnect noisy HasPingCount pc rg in
              (nrg, iPc)
    State.put ls { lsGraph = rg' }
    return i

lookupDLogServiceProcess :: LoopState -> Maybe (ServiceProcess DecisionLogConf)
lookupDLogServiceProcess ls =
    case G.connectedFrom Owns decisionLogServiceName $ lsGraph ls of
        [sp] -> Just sp
        _    -> Nothing

sayRC :: String -> Process ()
sayRC s = say $ "Recovery Coordinator: " ++ s

sendMsg :: Serializable a => ProcessId -> a -> CEP s ()
sendMsg pid a = liftProcess $ usend pid a

decodeMsg :: ProcessEncode a => BinRep a -> CEP s a
decodeMsg = liftProcess . decodeP

initialize :: ProcessId -> Process G.Graph
initialize mm = do
    rg <- G.getGraph mm
    if G.null rg then say "Starting from empty graph."
                 else say "Found existing graph."
    -- Empty graph means cluster initialization.
    let rg' | G.null rg =
            G.newResource Cluster >>>
            G.newResource (Epoch 0 "y = x^2" :: Epoch ByteString) >>>
            G.connect Cluster Has (Epoch 0 "y = x^2" :: Epoch ByteString) $ rg
            | otherwise = rg
    return rg'


----------------------------------------------------------
-- Reconfiguration                                      --
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

-- | Kill a service on a remote node
killService :: ServiceProcess a
            -> ExitReason
            -> CEP s ()
killService (ServiceProcess pid) reason = do
  cepLog "action" $ "Killing service with pid " ++ show pid
                  ++ " because of " ++ show reason
  liftProcess $ exit pid reason

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
          Nothing -> error "Cannot find current configuation"

prepareEpochResponse :: CEP LoopState EpochResponse
prepareEpochResponse = do
    rg <- State.gets lsGraph

    let edges :: [G.Edge Cluster Has (Epoch ByteString)]
        edges = G.edgesFromSrc Cluster rg
        G.Edge _ Has target = head edges

    return $ EpochResponse $ epochId target

updateServiceConfiguration :: Configuration a
                           => a
                           -> Service a
                           -> NodeFilter
                           -> CEP LoopState ()
updateServiceConfiguration opts svc nodeFilter = do
    cepLog "rg" $ "Updating configuration for service "
                ++ (snString $ serviceName svc)
                ++ " on nodes "
                ++ show nodeFilter
    ls <- State.get
    liftProcess $ sayRC $ "Request to reconfigure service "
                        ++ snString (serviceName svc)
                        ++ " on nodes " ++ (show nodeFilter)

    let rg       = lsGraph ls
        svcs     = filterServices nodeFilter svc rg
        fns      = fmap (\(_, nsvc) -> writeConfig nsvc opts Intended) svcs
        rgUpdate = foldl' (flip (.)) id fns
        rg'      = rgUpdate rg

    liftProcess $ do
      self <- getSelfPid
      mapM_ (usend self . encodeP . (flip ReconfigureCmd) svc . fst) svcs

    State.put ls { lsGraph = rg' }

getEpochId :: CEP LoopState Word64
getEpochId = do
    rg <- State.gets lsGraph

    let edges :: [G.Edge Cluster Has (Epoch ByteString)]
        edges = G.edgesFromSrc Cluster rg
        G.Edge _ Has target = head edges

    return $ epochId target

getMultimapProcessId :: CEP LoopState ProcessId
getMultimapProcessId = State.gets lsMMPid

-- | Starting from the root node, find nodes and services matching the given
--   ConfigurationFilter (not really important how this is specified) and
--   the type of the configuration.
filterServices :: forall a. Configuration a
               => NodeFilter
               -> Service a
               -> G.Graph
               -> [(Node, ServiceProcess a)]
filterServices (NodeFilter nids) (Service name _ _) rg = do
  node <- filter (\(Node nid) -> nid `elem` nids) $
              G.connectedTo Cluster Has rg :: [Node]
  svc <- filter (\(Service n _ _) -> n == name) $
              (G.connectedTo Cluster Supports rg :: [Service a])
  sp <- intersect
          (G.connectedTo svc InstanceOf rg :: [ServiceProcess a])
          (G.connectedTo node Runs rg :: [ServiceProcess a])
  return (node, sp)

----------------------------------------------------------
-- Recovery Co-ordinator                                --
----------------------------------------------------------

data LoopState = LoopState {
    lsGraph   :: G.Graph -- ^ Graph
  , lsFailMap :: Map.Map (ServiceName, Node) Int -- ^ Failed reconfiguration count
  , lsMMPid   :: ProcessId -- ^ Replicated Multimap pid
}

-- | The entry point for the RC.
--
-- Before evaluating 'recoveryCoordinator', the global network variable needs
-- to be initialized with 'HA.Network.Address.writeNetworkGlobalIVar'. This is
-- done automatically if 'HA.Network.Address.startNetwork' is used to create
-- the transport.
makeRecoveryCoordinator :: ProcessId -- ^ pid of the replicated multimap
                        -> RuleM LoopState ()
                        -> Process ()
makeRecoveryCoordinator mm rm = do
    rg    <- HA.RecoveryCoordinator.Mero.initialize mm
    start <- G.sync rg
    runProcessor (LoopState start Map.empty mm) $ do
      rm
      addRuleFinalizer $ \ls -> do
        newGraph <- G.sync $ lsGraph ls
        return ls { lsGraph = newGraph }

-- remotable [ 'recoveryCoordinator ]
