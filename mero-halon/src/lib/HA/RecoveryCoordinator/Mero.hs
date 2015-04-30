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
       , requeue
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
       , sendToMonitor
       , registerMasterMonitor
       , getMultimapProcessId
       , getNoisyPingCount
       , killService
       , writeConfiguration
       , sendToMasterMonitor
         -- * Host related functions
       , locateNodeOnHost
       , registerHost
       , registerInterface
         -- * Drive related functions
       , driveStatus
       , registerDrive
       , updateDriveStatus
       ) where

import Prelude hiding ((.), id, mapM_)
import HA.NodeUp (nodeUp)
import HA.Resources
import HA.Service
import HA.Services.DecisionLog
import HA.Services.Monitor
import HA.Services.Empty
import HA.Services.Noisy

import HA.Resources.Mero
#ifdef USE_MERO_NOTE
import HA.Resources.Mero.Note
#endif
import HA.NodeAgent.Messages
import qualified HA.Services.EQTracker as EQT

import HA.EventQueue.Consumer (HAEvent(..), matchHAEvent)
import HA.EventQueue.Producer (promulgateEQ)
import qualified HA.ResourceGraph as G

import Network.HostName
#ifdef USE_MERO_NOTE
import qualified Mero.Notification
import Mero.Notification.HAState
#endif

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
import Data.Maybe (fromMaybe)
#ifdef USE_RPC
import Data.Maybe (isJust)
#endif
import Data.Word

import GHC.Generics (Generic)

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

data InitState = InitNodeUp
               | InitMasterMonitor
               | InitDone

rcInit :: InitState -> G.Graph -> Process G.Graph
rcInit InitNodeUp rg = do
    nodeId <- getSelfNode
    h      <- liftIO getHostName
    let node = Node nodeId
        host = Host h
        rg' = G.newResource node                       >>>
              G.newResource EQT.eqTracker              >>>
              G.connect Cluster Supports EQT.eqTracker >>>
              G.connect Cluster Has node               >>>
              G.newResource host                       >>>
              G.connect Cluster Has host               >>>
              G.connect host Runs node $ rg
    _startService nodeId EQT.eqTracker EmptyConf rg'
    say "<-------------- WAINTING eqTracker"
    waitingForEQT
    say "---------------> Tracker is up"
    rcInit InitMasterMonitor rg'
  where
    waitingForEQT = do
        r <- receiveWait [
          matchHAEvent $ \(HAEvent _ msg _) -> do
            ServiceStarted _ svc _ _ <- decodeP msg
            if serviceName svc == serviceName EQT.eqTracker
              then return True
              else return False
          ]
        when (not r) waitingForEQT
rcInit InitMasterMonitor rg = do
    rg' <- startMasterMonitor rg
    say "<------------ WAITING Master monitor !!!"
    rg'' <- receiveWait [
        matchHAEvent $ \(HAEvent _ (SetMasterMonitor sp) _) ->
          return $ G.connect Cluster MasterMonitor sp rg'
        ]
    say "-------------> Master monitor is up !!!!"
    rcInit InitDone rg''
rcInit InitDone rg = do
    nodeId <- getSelfNode
    let rg' = G.newResource regularMonitor >>>
              G.connect Cluster Supports regularMonitor $ rg
    _startService nodeId regularMonitor emptyMonitorConf rg'
    return rg'

-- rcHasStarted :: G.Graph -> Process G.Graph
-- rcHasStarted rg = do
--     self <- getSelfPid
--     let selfNid  = processNodeId self

--     -- | RC automatically is a satellite node (supports services)
--     _ <- spawnLocal $ nodeUp ([selfNid], 1000000)

--     (rg2, psm) <- case prevMasterMonitor rg of
--                     Just sp@(ServiceProcess mpid) -> do
--                       exit mpid Shutdown
--                       let conf =
--                             case readConfig sp Current rg of
--                               Just x -> x
--                               _      -> error "impossible: rcHasStarted"

--                       return $ ( disconnectConfig sp Current >>>
--                                  G.disconnect Cluster MasterMonitor sp $ rg
--                                , Just conf
--                                )
--                     _ -> return (rg, Nothing)

--     let masterConf = fromMaybe emptyMonitorConf psm
--     _startService selfNid masterMonitor masterConf rg2
--     return rg2

startMasterMonitor :: G.Graph -> Process G.Graph
startMasterMonitor rg = do
    nodeId     <- getSelfNode
    (rg2, psm) <- case prevMasterMonitor rg of
                    Just sp@(ServiceProcess mpid) -> do
                      exit mpid Shutdown
                      let conf =
                            case readConfig sp Current rg of
                              Just x -> x
                              _      -> error "impossible: rcHasStarted"

                      return $ ( disconnectConfig sp Current >>>
                                 G.disconnect Cluster MasterMonitor sp $ rg
                               , Just conf
                               )
                    _ -> return (rg, Nothing)
    let masterConf = fromMaybe emptyMonitorConf psm
    _startService nodeId masterMonitor masterConf rg2
    return rg2

registerMasterMonitor :: ServiceProcess MonitorConf -> CEP LoopState ()
registerMasterMonitor sp = do
    ls <- State.get
    let rg' = G.connect Cluster MasterMonitor sp $ lsGraph ls
    State.put ls { lsGraph = rg' }

prevMasterMonitor :: G.Graph -> Maybe (ServiceProcess MonitorConf)
prevMasterMonitor rg =
    case G.connectedTo Cluster MasterMonitor rg of
      [sp] -> Just sp
      _    -> Nothing

prevEQTracker :: Node -> G.Graph -> Maybe (ServiceProcess EmptyConf)
prevEQTracker node rg =
    case action of
      [sp] -> Just sp
      _    -> Nothing
  where
    action = [sp | sp <- G.connectedTo node Runs rg
                 , G.isConnected EQT.eqTracker InstanceOf sp rg
                 ]

knownResource :: G.Resource a => a -> CEP LoopState Bool
knownResource res = do
    ls <- State.get
    return $ G.memberResource res (lsGraph ls)

registerNode :: Node -> CEP LoopState ()
registerNode node = do
    rg <- State.gets lsGraph

    let rg' = G.newResource node                       >>>
              G.newResource EQT.eqTracker              >>>
              G.connect Cluster Supports EQT.eqTracker >>>
              G.connect Cluster Has node $ rg

    State.modify $ \ls -> ls { lsGraph = rg' }

startEQTracker :: NodeId -> CEP LoopState ()
startEQTracker nid = State.gets lsGraph >>= \rg -> liftProcess $ do
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
    ls <- State.get
    let rg' = G.newResource svc >>>
              G.connect Cluster Supports svc $ lsGraph ls
    State.put ls { lsGraph = rg' }

startService :: Configuration a
             => NodeId
             -> Service a
             -> a
             -> CEP LoopState ()
startService n svc conf =
    liftProcess . _startService n svc conf . lsGraph =<< State.get

unregisterPreviousServiceProcess :: Configuration a
                                 => Node
                                 -> Service a
                                 -> ServiceProcess a
                                 -> CEP LoopState ()
unregisterPreviousServiceProcess n svc sp = do
    ls <- State.get
    let rg = lsGraph ls
        rg' = G.disconnect sp Owns (serviceName svc) >>>
              disconnectConfig sp Current            >>>
              G.disconnect n Runs sp                 >>>
              G.disconnect svc InstanceOf sp $ lsGraph ls
    State.put ls { lsGraph = rg' }

registerServiceName :: Configuration a
                    => Service a
                    -> CEP LoopState ()
registerServiceName svc = do
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
  ls <- State.get
  let rg' = G.newResource host
        >>> G.connect Cluster Has host
          $ lsGraph ls
  State.put ls { lsGraph = rg' }

-- | Register an interface on a host.
registerInterface :: Host -- ^ Host on which the interface resides.
                  -> Interface
                  -> CEP LoopState ()
registerInterface host int = do
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
  ls <- State.get
  let rg' = G.connect host Runs node
          $ lsGraph ls
  State.put ls { lsGraph = rg' }

-- | Get the status of a storage device.
driveStatus :: StorageDevice
            -> CEP LoopState (Maybe StorageDeviceStatus)
driveStatus dev = do
  ls <- State.get
  return $ case G.connectedTo dev Is (lsGraph ls) of
    [a] -> Just a
    _ -> Nothing

-- | Update the status of a storage device.
updateDriveStatus :: StorageDevice
                  -> String
                  -> CEP LoopState ()
updateDriveStatus dev status = do
  ls <- State.get
  ds <- driveStatus dev
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

lookupLocalMonitor :: Node -> CEP LoopState (Maybe (ServiceProcess MonitorConf))
lookupLocalMonitor node = fmap go $ State.gets lsGraph
  where
    go rg =
      let sp = [ x | x <- G.connectedTo node Runs rg
                   , G.isConnected x Owns monitorServiceName rg
                   ]
      in case sp of
        [mon] -> Just mon
        _    -> Nothing

sendToMonitor :: Serializable a => Node -> a -> CEP LoopState ()
sendToMonitor node a = do
    res <- lookupLocalMonitor node
    forM_ res $ \(ServiceProcess pid) ->
      liftProcess $ usend pid a

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

lookupMasterMonitor :: CEP LoopState (Maybe (ServiceProcess MonitorConf))
lookupMasterMonitor = do
    ls   <- State.get
    self <- getSelfProcessId
    let node   = Node $ processNodeId self
        rg     = lsGraph ls
        action :: [ServiceProcess MonitorConf]
        action = [ sp | sp <- G.connectedTo node Runs rg
                      , G.isConnected sp Owns masterMonitorServiceName rg
                      ]
    case action of
      [sp] -> return $ Just sp
      _    -> return Nothing

-- | Sends a message to the Master Monitor.
sendToMasterMonitor :: Serializable a => a -> CEP LoopState ()
sendToMasterMonitor a = do
    spm <- lookupMasterMonitor
    forM_ spm $ \(ServiceProcess mpid) ->
      liftProcess $ usend mpid a

sayRC :: String -> Process ()
sayRC s = say $ "Recovery Coordinator: " ++ s

sendMsg :: Serializable a => ProcessId -> a -> CEP s ()
sendMsg pid a = liftProcess $ usend pid a

requeue :: Serializable a => a -> CEP s ProcessId
requeue msg = liftProcess $ do
  sayRC "Requeuing unprocessed message."
  nid <- getSelfNode
  promulgateEQ [nid] msg

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
        sayRC $ "Sending ss message for service " ++ (snString . serviceName $ svc)
        void . promulgateEQ [mynid] . encodeP $
          ServiceStarted (Node node) svc cfg (ServiceProcess pid)

-- | Kill a service on a remote node
killService :: ServiceProcess a
            -> ExitReason
            -> CEP s ()
killService (ServiceProcess pid) reason =
  liftProcess $ exit pid reason

bounceServiceTo :: Configuration a
                => ConfigRole
                -> Node
                -> Service a
                -> CEP LoopState ()
bounceServiceTo role n@(Node nid) s = do
    _bounceServiceTo . lsGraph =<< State.get
  where
    _bounceServiceTo g = case runningService n s g of
        Just sp -> go sp
        Nothing -> error "Cannot bounce non-existent service."
      where
        go sp = case readConfig sp role g of
          Just cfg -> do
            killService sp Shutdown
            liftProcess $ _startService nid s cfg g
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
    lsGraph    :: G.Graph -- ^ Graph
  , lsFailMap  :: Map.Map (ServiceName, Node) Int
    -- ^ Failed reconfiguration count
  , lsMMPid    :: ProcessId -- ^ Replicated Multimap pid
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
    rg    <- HA.RecoveryCoordinator.Mero.initialize mm >>= rcInit InitNodeUp
    start <- G.sync rg
    runProcessor (LoopState start Map.empty mm) $ do
      rm
      addRuleFinalizer $ \ls -> do
        newGraph <- G.sync $ lsGraph ls
        return ls { lsGraph = newGraph }

#ifdef USE_MERO_NOTE
meroGetNotification :: ProcessId
                    -> ComplexEvent LoopState Input LoopState
meroGetNotification eq = repeatedly go . decoded
  where
    go ls@(LoopState rg _) (HAEvent eid (Mero.Notification.Get pid objs) _) =
        liftProcess $ do
          let f oid = Note oid $ head $ G.connectedTo (ConfObject oid) Is rg
              nvec  = map f objs
          usend pid $ Mero.Notification.GetReply nvec
          usend eq eid
          return ls

meroSetNotification :: ProcessId
                    -> ComplexEvent LoopState Input LoopState
meroSetNotification eq = repeatedly go . decoded
  where
    go ls@(LoopState rg _) (HAEvent eid (Mero.Notification.Set nvec) _) =
        liftProcess $ do
          let f rg1 (Note oid st) =
                let edges :: [G.Edge ConfObject Is ConfObjectState]
                    edges = G.edgesFromSrc (ConfObject oid) rg
                    -- Disconnect object from any existing state and reconnect
                    -- it to a new one.
                in G.connect (ConfObject oid) Is st $
                     foldr G.deleteEdge rg1 edges
              rg'      = foldl' f rg nvec
              m0dNodes = [ node | node <- G.connectedTo Cluster Has rg'
                                , isJust $ runningService node m0d rg' ]
          forM_ m0dNodes $ \(Node them) ->
            nsendRemote them (snString $ serviceName m0d) $
              Mero.Notification.Set nvec
          usend eq eid
          newGraph <- G.sync rg'
          return ls { lsGraph = newGraph }

#endif

-- remotable [ 'recoveryCoordinator ]
