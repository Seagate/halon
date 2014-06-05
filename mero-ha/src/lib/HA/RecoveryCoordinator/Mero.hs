-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- * Recovery coordinator
--
-- LEGEND: RC - recovery coordinator, R - replicator, RG - resource graph.
--
-- Behaviour of RC is determined by the state of RG and incoming HA events that
-- are posted by R from the event queue maintained by R. After recovering an HA
-- event, RC instructs R to drop the event, using a globally unique identifier.

{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}

module HA.RecoveryCoordinator.Mero
       ( recoveryCoordinator
       , IgnitionArguments(..)
       , __remoteTable
       ) where

import HA.Resources
#ifdef USE_RPC
import HA.Resources.Mero (ConfObject(..), ConfObjectState(..), Is(..))
#endif
import HA.Network.Address
import HA.NodeAgent hiding (__remoteTable)
import Mero.Messages
import HA.NodeAgent.Lookup (lookupNodeAgent)
import HA.EventQueue.Consumer
import qualified HA.ResourceGraph as G
#ifdef USE_RPC
import qualified Mero.Notification
import Mero.Notification.HAState
#endif

import HA.Services.Mero

import Control.Distributed.Process

import Control.Applicative ((<*))
import Control.Arrow ((>>>))
import Control.Monad (forM_)
import Data.Typeable (Typeable)
import Data.Binary (Binary)
import GHC.Generics (Generic)
#ifdef USE_RPC
import Data.List (foldl')
#endif
import Data.Maybe (mapMaybe)
import Data.ByteString (ByteString)


-- | Initial configuration data.
data IgnitionArguments = IgnitionArguments
  { -- | The names of all nodes in the cluster.
    clusterNodes :: [String]

    -- | The names of all tracking station nodes.
  , stationNodes :: [String]
  } deriving (Generic,Typeable)

instance Binary IgnitionArguments

-- | An internal message type.
data NodeAgentContacted = NodeAgentContacted ProcessId
         deriving (Typeable, Generic)

instance Binary NodeAgentContacted

sayRC :: String -> Process ()
sayRC s = say $ "Recovery Coordinator: " ++ s

initialize :: ProcessId -> IgnitionArguments -> Process G.Graph
initialize mm IgnitionArguments{..} = do
    self <- getSelfPid
    network <- liftIO readNetworkGlobalIVar

    -- Ask all nodes to make themselves known.
    forM_ (mapMaybe parseAddress clusterNodes) $ \addr -> spawnLocal $ do
        mbpid <- lookupNodeAgent network addr
        case mbpid of
            Nothing -> sayRC $ "No node agent found."
            Just agent -> send self $ NodeAgentContacted agent

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

-- | The entry point for the RC.
--
-- Before evaluating 'recoveryCoordinator', the global network variable needs
-- to be initialized with 'HA.Network.Address.writeNetworkGlobalIVar'. This is
-- done automatically if 'HA.Network.Address.startNetwork' is used to create
-- the transport.
recoveryCoordinator :: ProcessId -- ^ pid of the replicated event queue
                    -> ProcessId -- ^ pid of the replicated multimap
                    -> IgnitionArguments -> Process ()
recoveryCoordinator eq mm argv = do
    rg <- HA.RecoveryCoordinator.Mero.initialize mm argv
    loop =<< G.sync rg
  where
    loop :: G.Graph -> Process ()
    loop rg = receiveWait
        [ match $ \(NodeAgentContacted agent) -> do
              sayRC $ "New node contacted: " ++ show agent
              let rg' = G.newResource (Node agent) >>>
                        G.newResource m0d >>>
                        G.connect (Node agent) Runs m0d >>>
                        G.connect Cluster Has (Node agent) $
                        rg
              _ <- updateEQ agent $ mapMaybe parseAddress $ stationNodes argv
               -- XXX check for timeout.
              _ <- spawn (processNodeId agent) $ serviceProcess m0d
              loop =<< G.sync rg'
        , matchIfHAEvent
          -- Check that node is already initialized.
          (\(HAEvent _ (ServiceFailed node _)) -> G.memberResource node rg)
          (\(HAEvent eid (ServiceFailed (Node agent) srv)) -> do
               sayRC $ "Notified of service failure: " ++ show (serviceName srv)
               -- XXX check for timeout.
               _ <- spawn (processNodeId agent) $ serviceProcess srv
               send eq $ eid
               loop rg)
        , matchIfHAEvent
          (\(HAEvent _ (ServiceCouldNotStart node _)) -> G.memberResource node rg)
          (\(HAEvent eid (ServiceCouldNotStart _ srv)) -> do
               -- XXX notify the operator in a more appropriate manner.
               sayRC $ "Can't start service: " ++ show (serviceName srv)
               send eq $ eid
               loop rg)
        , matchIfHAEvent
          (\(HAEvent _ (StripingError node)) -> G.memberResource node rg)
          (\(HAEvent eid (StripingError _)) -> do
              sayRC $ "Striping error detected"

              -- Increment the epoch.
              let e :: G.Edge Cluster Has (Epoch ByteString)
                  e = head $ G.edgesFromSrc Cluster rg
                  current = G.edgeDst e
                  -- XXX this is a fake formula associated with the epoch. These
                  -- will be changed in due course to something meaningful,
                  -- possibly provided entirely by Mero and therefore the
                  -- content is not decided upon by the RC.
                  target = Epoch (succ (epochId current)) "y = x^3"
                  rg' = G.deleteEdge e >>> G.connect Cluster Has target $ rg
                  m0dNodes = [ node | node <- G.connectedTo Cluster Has rg'
                                    , G.isConnected node Runs m0d rg' ]

              -- Broadcast new epoch.
              forM_ m0dNodes $ \(Node them) ->
                  nsendRemote (processNodeId them) (serviceName m0d) $
                  EpochTransition
                      { et_current = epochId current
                      , et_target  = epochId target
                      , et_how     = epochState target :: ByteString
                      }

              loop =<< G.sync rg' <* send eq eid)
        , matchHAEvent $ \(HAEvent eid EpochTransitionRequest{..}) -> do
              let G.Edge _ Has target = head $ G.edgesFromSrc Cluster rg
              send etr_source $ EpochTransition
                  { et_current = etr_current
                  , et_target  = epochId target
                  , et_how     = epochState target :: ByteString
                  }
              send eq $ eid
              loop rg
#ifdef USE_RPC
        , matchHAEvent $ \(HAEvent eid (Mero.Notification.Get pid objs)) -> do
              let f obj@(ConfObject oty oid) = Note oid oty st
                      where st = head $ G.connectedTo obj Is rg
                  nvec = map f objs
              send pid $ Mero.Notification.GetReply nvec
              send eq $ eid
              loop rg
        , matchHAEvent $ \(HAEvent eid (Mero.Notification.Set nvec)) -> do
              let f rg1 (Note oid oty st) =
                      let obj = ConfObject oty oid
                          edges :: [G.Edge ConfObject Is ConfObjectState]
                          edges = G.edgesFromSrc obj rg
                          -- Disconnect object from any existing state and reconnect
                          -- it to a new one.
                      in G.connect obj Is st $ foldr G.deleteEdge rg1 edges
                  rg' = foldl' f rg nvec
                  m0dNodes = [ node | node <- G.connectedTo Cluster Has rg'
                                    , G.isConnected node Runs m0d rg' ]
              forM_ m0dNodes $ \(Node them) ->
                  nsendRemote (processNodeId them) (serviceName m0d) $
                  Mero.Notification.Set nvec
              send eq $ eid
              loop =<< G.sync rg'
#endif
        ]
