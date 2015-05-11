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

module HA.RecoveryCoordinator.Mero
       ( module HA.RecoveryCoordinator.Actions.Core
       , module HA.RecoveryCoordinator.Actions.Hardware
       , module HA.RecoveryCoordinator.Actions.Service
       , IgnitionArguments(..)
       , GetMultimapProcessId(..)
       , sayRC
       , startEQTracker
       , ack
       , getSelfProcessId
       , sendMsg
       , makeRecoveryCoordinator
       , prepareEpochResponse
       , getEpochId
       , decodeMsg
       , lookupDLogServiceProcess
       , sendToMonitor
       , registerMasterMonitor
       , getMultimapProcessId
       , getNoisyPingCount
       , sendToMasterMonitor
       ) where

import Prelude hiding ((.), id, mapM_)
import HA.NodeUp (nodeUp)
import HA.Resources
import HA.Service
import HA.Services.DecisionLog
import HA.Services.Monitor
import HA.Services.Empty
import HA.Services.Noisy

import HA.NodeAgent.Messages
import qualified HA.Services.EQTracker as EQT

import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Hardware
import HA.RecoveryCoordinator.Actions.Service
import qualified HA.ResourceGraph as G

import Control.Distributed.Process hiding (send)
import Control.Distributed.Process.Serializable
import qualified Control.Monad.State.Strict as State

import Control.Monad
import Control.Wire hiding (when)

import Data.Binary (Binary)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BS
import Data.Dynamic
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
#ifdef USE_RPC
import Data.Maybe (isJust)
#endif
import Data.Word

import GHC.Generics (Generic)

import Network.CEP

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

rcHasStarted :: G.Graph -> Process G.Graph
rcHasStarted rg = do
    self <- getSelfPid
    let selfNid  = processNodeId self

    -- | RC automatically is a satellite node (supports services)
    _ <- spawnLocal $ nodeUp ([selfNid], 1000000)

    (rg2, psm) <- case lookupMasterMonitor rg of
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
    _startService selfNid masterMonitor masterConf rg2
    return rg2

registerMasterMonitor :: ServiceProcess MonitorConf -> CEP LoopState ()
registerMasterMonitor sp = do
    ls <- State.get
    let rg' = G.connect Cluster MasterMonitor sp $ lsGraph ls
    State.put ls { lsGraph = rg' }

lookupMasterMonitor :: G.Graph -> Maybe (ServiceProcess MonitorConf)
lookupMasterMonitor rg =
    case G.connectedTo Cluster MasterMonitor rg of
      [sp] -> Just sp
      _    -> Nothing

startEQTracker :: NodeId -> CEP LoopState ()
startEQTracker nid = do
    cepLog "action" $ "Starting " ++ EQT.name ++ " on node " ++ show nid
    State.gets lsGraph >>= \rg -> liftProcess $ do
      sayRC $ "New node contacted: " ++ show nid
      _startService nid EQT.eqTracker EmptyConf rg

ack :: ProcessId -> CEP LoopState ()
ack pid = liftProcess $ usend pid ()

getSelfProcessId :: CEP s ProcessId
getSelfProcessId = liftProcess getSelfPid

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

sendToMonitor :: Serializable a => Node -> a -> CEP LoopState ()
sendToMonitor node a = do
    res <- lookupRunningService node regularMonitor
    forM_ res $ \(ServiceProcess pid) ->
      liftProcess $ usend pid a

-- | Sends a message to the Master Monitor.
sendToMasterMonitor :: Serializable a => a -> CEP LoopState ()
sendToMasterMonitor a = do
    spm <- return . lookupMasterMonitor =<< State.gets lsGraph
    forM_ spm $ \(ServiceProcess mpid) ->
      liftProcess $ usend mpid a

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

prepareEpochResponse :: CEP LoopState EpochResponse
prepareEpochResponse = do
    rg <- State.gets lsGraph

    let edges :: [G.Edge Cluster Has (Epoch ByteString)]
        edges = G.edgesFromSrc Cluster rg
        G.Edge _ Has target = head edges

    return $ EpochResponse $ epochId target

getEpochId :: CEP LoopState Word64
getEpochId = do
    rg <- State.gets lsGraph

    let edges :: [G.Edge Cluster Has (Epoch ByteString)]
        edges = G.edgesFromSrc Cluster rg
        G.Edge _ Has target = head edges

    return $ epochId target

getMultimapProcessId :: CEP LoopState ProcessId
getMultimapProcessId = State.gets lsMMPid

----------------------------------------------------------
-- Recovery Co-ordinator                                --
----------------------------------------------------------

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
    rg    <- HA.RecoveryCoordinator.Mero.initialize mm >>= rcHasStarted
    start <- G.sync rg
    runProcessor (LoopState start Map.empty mm) $ do
      rm
      addRuleFinalizer $ \ls -> do
        newGraph <- G.sync $ lsGraph ls
        return ls { lsGraph = newGraph }

-- remotable [ 'recoveryCoordinator ]
