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

{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies #-}

{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module HA.RecoveryCoordinator.Mero
       ( recoveryCoordinator
       , IgnitionArguments(..)
       , HA.RecoveryCoordinator.Mero.__remoteTable
       ) where

import HA.Resources
import HA.Service
#ifdef USE_RPC
import HA.Resources.Mero (ConfObject(..), ConfObjectState(..), Is(..))
#endif
import HA.NodeAgent

import Mero.Messages
import HA.EventQueue.Consumer
import qualified HA.ResourceGraph as G
#ifdef USE_RPC
import qualified Mero.Notification
import Mero.Notification.HAState
#endif

import HA.Services.Mero

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Internal.Types ( remoteTable, processNode )
import Control.Distributed.Static (closureApply, unstatic)
import Control.Monad.Reader (ask)

import Control.Applicative ((<*), (<$>))
import Control.Arrow ((>>>))
import Control.Monad (forM, forM_, when, void, (>=>))
import qualified Data.Map.Strict as Map
import Data.Typeable (Typeable)
import Data.Binary (Binary, Get, encode, get, put)
import Data.Binary.Put (runPut)
import Data.Binary.Get (runGet)
import qualified Data.ByteString.Lazy as BS
import Data.Foldable (mapM_)
import GHC.Generics (Generic)
#ifdef USE_RPC
import Data.List (foldl')
#endif
import Data.ByteString (ByteString)

import Prelude hiding (mapM_)

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
  { -- | The names of all nodes in the cluster.
    clusterNodes :: [NodeId]

    -- | The names of all tracking station nodes.
  , stationNodes :: [NodeId]
  } deriving (Generic,Typeable)

instance Binary IgnitionArguments

-- | An internal message type.
data NodeAgentContacted = NodeAgentContacted ProcessId
         deriving (Typeable, Generic)

instance Binary NodeAgentContacted

reconfFailureLimit :: Int
reconfFailureLimit = 3

sayRC :: String -> Process ()
sayRC s = say $ "Recovery Coordinator: " ++ s

initialize :: ProcessId -> IgnitionArguments -> Process G.Graph
initialize mm IgnitionArguments{..} = do
    self <- getSelfPid
    -- Ask all nodes to make themselves known.
    forM_ clusterNodes $ \nid -> spawnLocal $ do
        getNodeAgent nid >>= \case
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

----------------------------------------------------------
-- Reconfiguration                                      --
----------------------------------------------------------

-- | kill_helper is made remotable and works on the remote node running
--   the service. This is because it needs to look up the process id on the
--   remote node. In a NodeAgent-less world this should be unnecessary.
kill_helper :: (ServiceName, ExitReason) -> Process ()
kill_helper (svc, reason) = do
  mpid <- whereis svc
  mapM_ (flip exit $ reason) mpid

remotable ['kill_helper]

startService :: forall a. Configuration a
             => NodeId -- ^ Node to start service on
             -> Service a -- ^ Service
             -> ConfigRole
             -> G.Graph
             -> Process ()
startService node svc role rg = case readConfig svc role rg of
  Just cfg -> void . spawn node $ serviceProcess svc
                `closureApply` closure (staticDecode sDict) (encode cfg)
  Nothing -> sayRC $ "Unable to find config for " ++ serviceName svc

-- | Kill a service on a remote node
killService :: NodeId
            -> Service a
            -> ExitReason
            -> Process ()
killService node svc reason =
  void . spawn node $ $(mkClosure 'kill_helper) (serviceName svc, reason)

restartService :: Configuration a
               => NodeId
               -> Service a
               -> G.Graph
               -> Process ()
restartService n s g =
  killService n s Shutdown >> startService n s Current g

reconfigureService :: Configuration a
                   => NodeId
                   -> Service a
                   -> G.Graph
                   -> Process ()
reconfigureService n s g =
  killService n s Reconfigure >> startService n s Intended g

-- | Starting from the root node, find nodes and services matching the given
--   ConfigurationFilter (not really important how this is specified) and
--   the type of the configuration.
filterServices :: forall a. Configuration a
               => ConfigurationFilter
               -> a -- ^ Configuration object (maybe just typeRep of this?)
               -> G.Graph
               -> [(Node, Service a)]
filterServices (ConfigurationFilter _ (ServiceFilter sf)) _ rg = do
  node <- G.connectedTo Cluster Has rg :: [Node]
  svc <- filter (\(Service n _ _) -> n `elem` sf) $
              (G.connectedTo node Runs rg :: [Service a])
  return (node, svc)

----------------------------------------------------------
-- Recovery Co-ordinator                                --
----------------------------------------------------------

data LoopState = LoopState {
    lsGraph :: G.Graph -- ^ Graph
  , lsFailMap :: Map.Map ServiceName Int -- ^ Failed reconfiguration count
}

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
    loop =<< initLoopState <$> G.sync rg
  where
    initLoopState :: G.Graph -> LoopState
    initLoopState g = LoopState { lsGraph = g, lsFailMap = Map.empty }
    loop :: LoopState -> Process ()
    loop ls@(LoopState rg failmap) = receiveWait
        [ match $ \(EpochRequest pid) -> do
            let G.Edge _ Has target = head (G.edgesFromSrc Cluster rg :: [G.Edge Cluster Has (Epoch ByteString)])
            send pid $ EpochResponse $ epochId target
            loop ls
        , match $ (decodeP >=>) $ \(ConfigurationUpdate epoch opts sdict nodeFilter) -> let
              G.Edge _ Has target = head (G.edgesFromSrc Cluster rg :: [G.Edge Cluster Has (Epoch ByteString)])
            in when (epoch == epochId target) $ do
              unStatic sdict >>= \case
                SomeConfigurationDict G.Dict -> do
                  -- Write the new config as a 'Wants' config
                  let svcs = filterServices nodeFilter opts rg
                      rgUpdate = foldl1 (.) $ fmap (
                          \case (_, svc@(Service _ _ _))
                                  -> writeConfig svc opts Intended
                        ) svcs
                      rg' = rgUpdate rg
                  -- Send a message to ourselves asking to reconfigure
                  self <- getSelfPid
                  mapM_ (send self . encodeP . uncurry ReconfigureCmd) svcs
                  loop =<< (fmap (\a -> ls { lsGraph = a }) $ G.sync rg')
        , match $ \(NodeAgentContacted agent) -> do
              let nid = processNodeId agent
                  node = Node nid
              sayRC $ "New node contacted: " ++ show agent
              let rg' = G.newResource node >>>
                        G.newResource m0d >>>
                        G.connect node Runs m0d >>>
                        G.connect Cluster Has node $
                        rg
              -- TODO make async.
              mbpids <- forM (stationNodes argv) getNodeAgent
              _ <- updateEQNodes agent [ processNodeId pid | Just pid <- mbpids ]
               -- XXX check for timeout.
              _ <- restartService nid m0d rg
              loop =<< (fmap (\a -> ls { lsGraph = a }) $ G.sync rg')
        , match $ (decodeP >=>) $ \(ReconfigureCmd (Node nid) svc) ->
            unStatic (configDict svc) >>= \case
              SomeConfigurationDict G.Dict -> do
                reconfigureService nid svc rg
                loop ls
      , matchHAEvent
          (\evt@(HAEvent _ (ssrm :: ServiceStartRequestMsg) _) -> do
            ServiceStartRequest n@(Node nid) svc c <- decodeP ssrm
            if G.memberResource n rg then
              unStatic (configDict svc) >>= \case
                SomeConfigurationDict G.Dict -> do
                  sayRC $ "Request to start service " ++ show (serviceName svc)
                          ++ "on node " ++ (show n)
                  let rg' = G.newResource svc >>>
                            writeConfig svc c Intended >>>
                            G.connect n Runs svc $
                            rg
                  startService nid svc Intended rg'
                  loop =<< (fmap (\a -> ls { lsGraph = a}) $ G.sync rg')
            else getSelfPid >>= \s -> send s evt >> loop ls
          )
      , matchHAEvent
          -- (\(HAEvent _ (ServiceStarted node _) _) -> G.memberResource node rg)
          (\(HAEvent _ (ssm :: ServiceStartedMsg) _) -> do
            ServiceStarted _ svc <- decodeP ssm
            unStatic (configDict svc) >>= \case
              SomeConfigurationDict G.Dict -> do
                sayRC $ "Service successfully started: " ++ show (serviceName svc)
                let rg' = updateConfig svc rg
                loop =<< (fmap (\a -> ls { lsGraph = a }) $ G.sync rg')
          )
        , matchHAEvent
          -- Check that node is already initialized.
          -- (\(HAEvent _ (ServiceFailedMsg node _) _) -> G.memberResource node rg)
          (\(HAEvent eid (sfm :: ServiceFailedMsg) _) -> do
            (ServiceFailed (Node nid)
              srv@(Service _ _ sdict)) <- decodeP sfm
            unStatic sdict >>= \case
                SomeConfigurationDict G.Dict -> do
                  sayRC $ "Notified of service failure: " ++ show (serviceName srv)
                  -- XXX check for timeout.
                  _ <- restartService nid srv rg
                  send eq $ eid
                  loop ls)
        , matchHAEvent
          -- (\(HAEvent _ (ServiceCouldNotStart node _) _) -> G.memberResource node rg)
          (\(HAEvent eid (scns :: ServiceCouldNotStartMsg) _) -> do
            (ServiceCouldNotStart (Node node)
              srv@(Service _ _ sdict)) <- decodeP scns
            unStatic sdict >>= \case
                SomeConfigurationDict G.Dict-> do
                  -- Update the fail map to record this failure
                  let sName = serviceName srv
                      failmap' = Map.update (\x -> Just $ x + 1) sName failmap
                      failedCount = Map.findWithDefault 0 sName failmap'
                  send eq $ eid
                  -- If we have failed too many times, stop and remove any new config.
                  if failedCount >= reconfFailureLimit then do
                    -- XXX notify the operator in a more appropriate manner.
                    sayRC $ "Can't start service: " ++ show (serviceName srv)
                    let failmap'' = Map.delete sName failmap'
                    rg' <- G.sync $ disconnectConfig srv Intended rg
                    restartService node srv rg
                    loop $ ls {
                        lsGraph = rg'
                      , lsFailMap = failmap''
                    }
                  else do
                    reconfigureService node srv rg
                    loop (ls { lsFailMap = failmap' }))
        , matchIfHAEvent
          (\(HAEvent _ (StripingError node) _) -> G.memberResource node rg)
          (\(HAEvent eid (StripingError _) _) -> do
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
                  nsendRemote them (serviceName m0d) $
                  EpochTransition
                      { etCurrent = epochId current
                      , etTarget  = epochId target
                      , etHow     = epochState target :: ByteString
                      }

              loop =<< (fmap (\a -> ls { lsGraph = a }) $ G.sync rg' <* send eq eid))
        , matchHAEvent $ \(HAEvent eid EpochTransitionRequest{..} _) -> do
              let G.Edge _ Has target = head $ G.edgesFromSrc Cluster rg
              send etrSource $ EpochTransition
                  { etCurrent = etrCurrent
                  , etTarget  = epochId target
                  , etHow     = epochState target :: ByteString
                  }
              send eq $ eid
              loop ls
#ifdef USE_RPC
        , matchHAEvent $ \(HAEvent eid (Mero.Notification.Get pid objs) _) -> do
              let f oid = Note oid $ head $ G.connectedTo (ConfObject oid) Is rg
                  nvec = map f objs
              send pid $ Mero.Notification.GetReply nvec
              send eq $ eid
              loop ls
        , matchHAEvent $ \(HAEvent eid (Mero.Notification.Set nvec) _) -> do
              let f rg1 (Note oid st) =
                      let edges :: [G.Edge ConfObject Is ConfObjectState]
                          edges = G.edgesFromSrc (ConfObject oid) rg
                          -- Disconnect object from any existing state and reconnect
                          -- it to a new one.
                      in G.connect (ConfObject oid) Is st $
                           foldr G.deleteEdge rg1 edges
                  rg' = foldl' f rg nvec
                  m0dNodes = [ node | node <- G.connectedTo Cluster Has rg'
                                    , G.isConnected node Runs m0d rg' ]
              forM_ m0dNodes $ \(Node them) ->
                  nsendRemote them (serviceName m0d) $
                  Mero.Notification.Set nvec
              send eq $ eid
              loop =<< (fmap (\a -> ls { lsGraph = a }) $ G.sync rg')
#endif
        ]
