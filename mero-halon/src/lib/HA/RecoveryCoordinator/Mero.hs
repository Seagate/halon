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
{-# LANGUAGE TypeFamilies               #-}

{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module HA.RecoveryCoordinator.Mero
       ( recoveryCoordinator
       , IgnitionArguments(..)
       ) where

import HA.Resources
import HA.Service
#ifdef USE_MERO
import HA.Resources.Mero (ConfObject(..), ConfObjectState(..), Is(..))
#endif
import HA.NodeAgent.Messages
import HA.NodeUp
import qualified HA.Services.EQTracker as EQT

import Mero.Messages
import HA.EventQueue.Consumer
import HA.EventQueue.Producer (promulgateEQ)
import qualified HA.ResourceGraph as G
#ifdef USE_MERO
import qualified Mero.Notification
import Mero.Notification.HAState
#endif

import HA.Services.Mero
import HA.Services.Noisy as Noisy

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Internal.Types ( remoteTable, processNode )
import Control.Distributed.Static (closureApply, unstatic)
import Control.Monad.Reader (ask)

import Control.Applicative ((<*), (<$>))
import Control.Arrow ((>>>))
import Control.Monad (forM_, void, (>=>))

import Data.Binary (Binary, Get, encode, get, put)
import Data.Binary.Put (runPut)
import Data.Binary.Get (runGet)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BS
import Data.Foldable (mapM_)
import Data.List (foldl', intersect)
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing)
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

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
  { -- | The names of all tracking station nodes.
    stationNodes :: [NodeId]
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

startService :: forall a. Configuration a
             => NodeId -- ^ Node to start service on
             -> Service a -- ^ Service
             -> a
             -> G.Graph
             -> Process ProcessId
startService node svc cfg _ = do
  mynid <- getSelfNode
  pid <- spawn node $ serviceProcess svc
              `closureApply` closure (staticDecode sDict) (encode cfg)
  void . promulgateEQ [mynid] . encodeP $
    ServiceStarted (Node node) svc cfg (ServiceProcess pid)
  return pid

-- | Kill a service on a remote node
killService :: NodeId
            -> ServiceProcess a
            -> ExitReason
            -> Process ()
killService _ (ServiceProcess pid) reason =
  exit pid reason

-- | Bounce the service to a particular configuration.
bounceServiceTo :: Configuration a
               => ConfigRole -- ^ Configuration role to bounce to.
               -> Node -- ^ Node on which to bounce service
               -> Service a -- ^ Service to bounce
               -> G.Graph -- ^ Resource Graph
               -> Process ProcessId -- ^ Process ID of new service instance.
bounceServiceTo role n@(Node nid) s g = case runningService n s g of
    Just sp -> go sp
    Nothing -> error "Cannot bounce non-existent service."
  where
    go sp = case readConfig sp role g of
      Just cfg -> killService nid sp Shutdown >> startService nid s cfg g
      Nothing -> error "Cannot find current configuation"

restartService :: Configuration a
               => Node
               -> Service a
               -> G.Graph
               -> Process ProcessId
restartService = bounceServiceTo Current

reconfigureService :: Configuration a
                   => Node
                   -> Service a
                   -> G.Graph
                   -> Process ProcessId
reconfigureService = bounceServiceTo Intended

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
    lsGraph :: G.Graph -- ^ Graph
  , lsFailMap :: Map.Map (ServiceName, Node) Int -- ^ Failed reconfiguration count
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
    rg <- HA.RecoveryCoordinator.Mero.initialize mm
    loop =<< initLoopState <$> G.sync rg
  where
    initLoopState :: G.Graph -> LoopState
    initLoopState g = LoopState { lsGraph = g, lsFailMap = Map.empty }
    loop :: LoopState -> Process ()
    loop ls@(LoopState rg failmap) = receiveWait
        [ match $ (decodeP >=>) $ \(ReconfigureCmd n@(Node nid) svc) ->
            unStatic (configDict svc) >>= \case
              SomeConfigurationDict G.Dict -> do
                sayRC $ "Reconfiguring service "
                        ++ (snString . serviceName $ svc)
                        ++ " on node " ++ (show nid)
                _ <- reconfigureService n svc rg
                loop ls
        , matchHAEvent $ \(HAEvent _ (NodeUp pid) _) -> let
              nid = processNodeId pid
              node = Node nid
              prg = if (G.memberResource node rg)
                    then return rg
                    else do
                      sayRC $ "New node contacted: " ++ show nid
                      let rg' = G.newResource node >>>
                                G.newResource EQT.eqTracker >>>
                                G.connect Cluster Supports EQT.eqTracker >>>
                                G.connect Cluster Has node $
                                rg
                      eqt <- startService nid EQT.eqTracker () rg'
                      -- Send list of EQs to the tracker
                      True <- updateEQNodes eqt (stationNodes argv)
                      return rg'
            in do
              -- Send acknowledgement to let nodeUp die
              send pid ()
              loop =<< (fmap (\a -> ls { lsGraph = a }) . G.sync) =<< prg
        , matchHAEvent $ \(HAEvent eid DummyEvent _) -> do
            let (rg', i) = case G.connectedTo Noisy.noisy HasPingCount rg of
                 [] -> ( G.connect Noisy.noisy HasPingCount (NoisyPingCount 0) $
                         G.newResource (NoisyPingCount 0)
                         rg
                       , 0
                       )
                 pc@(NoisyPingCount iPc) : _ ->
                  let newPingCount = NoisyPingCount $ iPc + 1
                   in ( G.connect Noisy.noisy HasPingCount newPingCount $
                        G.newResource newPingCount $
                        G.disconnect Noisy.noisy HasPingCount pc
                        rg
                      , iPc
                      )
            rg'' <- G.sync rg'
            send eq eid
            sayRC $ "Noisy ping count: " ++ show i
            loop $ ls { lsGraph = rg'' }
        , matchHAEvent $ \(HAEvent _ (EpochRequest pid) _) -> do
            let G.Edge _ Has target = head (G.edgesFromSrc Cluster rg :: [G.Edge Cluster Has (Epoch ByteString)])
            send pid $ EpochResponse $ epochId target
            loop ls
        , matchHAEvent
            (\(HAEvent _ (cum :: ConfigurationUpdateMsg) _) -> do
              ConfigurationUpdate epoch opts svc nodeFilter <- decodeP cum
              let
                G.Edge _ Has target = head (G.edgesFromSrc Cluster rg :: [G.Edge Cluster Has (Epoch ByteString)])
              if epoch == epochId target then do
                unStatic (configDict svc) >>= \case
                  SomeConfigurationDict G.Dict -> do
                    sayRC $ "Request to reconfigure service " ++ snString (serviceName svc)
                            ++ " on nodes " ++ (show nodeFilter)
                    -- Write the new config as a 'Wants' config
                    let svcs = filterServices nodeFilter svc rg
                        rgUpdate = foldl' (flip (.)) id $ fmap (
                            \(_, nsvc)
                                    -> writeConfig nsvc opts Intended
                          ) svcs
                        rg' = rgUpdate rg
                    -- Send a message to ourselves asking to reconfigure
                    self <- getSelfPid
                    mapM_ (send self . encodeP . (flip ReconfigureCmd) svc . fst) svcs
                    loop =<< (fmap (\a -> ls { lsGraph = a }) $ G.sync rg')
              else loop ls
              )
        , matchHAEvent
            (\evt@(HAEvent _ (ssrm :: ServiceStartRequestMsg) _) -> do
              ServiceStartRequest n@(Node nid) svc c <- decodeP ssrm
              if G.memberResource n rg
                 && (isNothing $ runningService n svc rg)
              then
                unStatic (configDict svc) >>= \case
                  SomeConfigurationDict G.Dict -> do
                    sayRC $ "Request to start service " ++ snString (serviceName svc)
                            ++ " on node " ++ (show n)
                    let rg' = G.newResource svc >>>
                              G.connect Cluster Supports svc $
                              rg
                    _ <- startService nid svc c rg'
                    loop =<< (fmap (\a -> ls { lsGraph = a}) $ G.sync rg')
              else getSelfPid >>= \s -> send s evt >> loop ls
            )
        , matchHAEvent
            -- (\(HAEvent _ (ServiceStarted node _) _) -> G.memberResource node rg)
            (\(HAEvent _ (ssm :: ServiceStartedMsg) _) -> do
              ServiceStarted n (svc @ Service {..}) cfg sp <- decodeP ssm
              unStatic configDict >>= \case
                SomeConfigurationDict G.Dict -> do
                  sayRC $ "Service successfully started: " ++ snString serviceName
                  let rg' = case runningService n svc rg of
                              Just sp' -> G.disconnect sp' Owns serviceName
                                        >>> G.disconnect n Runs sp'
                                        >>> G.disconnect svc InstanceOf sp
                              Nothing -> G.newResource serviceName
                            >>> G.newResource sp
                            >>> G.connect n Runs sp
                            >>> G.connect svc InstanceOf sp
                            >>> G.connect sp Owns serviceName
                            >>> writeConfig sp cfg Current $
                            rg
                  loop =<< (fmap (\a -> ls { lsGraph = a }) $ G.sync rg')
            )
        , matchHAEvent
          -- Check that node is already initialized.
          -- (\(HAEvent _ (ServiceFailedMsg node _) _) -> G.memberResource node rg)
          (\(HAEvent eid (sfm :: ServiceFailedMsg) _) -> do
            (ServiceFailed n srv@(Service _ _ sdict)) <- decodeP sfm
            unStatic sdict >>= \case
                SomeConfigurationDict G.Dict -> do
                  sayRC $ "Notified of service failure: " ++ show (serviceName srv)
                  -- XXX check for timeout.
                  _ <- restartService n srv rg
                  send eq $ eid
                  loop ls)
        , matchHAEvent
          -- (\(HAEvent _ (ServiceCouldNotStart node _) _) -> G.memberResource node rg)
          (\(HAEvent eid (scns :: ServiceCouldNotStartMsg) _) -> do
            (ServiceCouldNotStart node srv@(Service _ _ sdict)) <- decodeP scns
            unStatic sdict >>= \case
                SomeConfigurationDict G.Dict-> do
                  -- Update the fail map to record this failure
                  let sName = serviceName srv
                      failmap' = Map.update (\x -> Just $ x + 1) (sName, node) failmap
                      failedCount = Map.findWithDefault 0 (sName, node) failmap'
                  send eq $ eid
                  -- If we have failed too many times, stop and remove any new config.
                  if failedCount >= reconfFailureLimit then do
                    -- XXX notify the operator in a more appropriate manner.
                    sayRC $ "Can't start service: " ++ show (serviceName srv)
                    let failmap'' = Map.delete (sName, node) failmap'
                    rg' <- case runningService node srv rg of
                      Just sp -> G.sync $ disconnectConfig sp Intended rg
                      Nothing -> return rg
                    _ <- restartService node srv rg
                    loop $ ls {
                        lsGraph = rg'
                      , lsFailMap = failmap''
                    }
                  else do
                    _ <- reconfigureService node srv rg
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
                  m0Instances = [ i1 | node <- (G.connectedTo Cluster Has rg'
                                          :: [Node])
                                       , i1 <- (G.connectedTo node Runs rg'
                                          :: [ServiceProcess ()])
                                       , i2 <- (G.connectedTo m0d InstanceOf rg'
                                          :: [ServiceProcess ()])
                                       , i1 == i2 ]

              -- Broadcast new epoch.
              forM_ m0Instances $ \(ServiceProcess pid) ->
                send pid $
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
#ifdef USE_MERO
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
                                    , isJust $ runningService node m0d rg' ]
              forM_ m0dNodes $ \(Node them) ->
                  nsendRemote them (serviceName m0d) $
                  Mero.Notification.Set nvec
              send eq $ eid
              loop =<< (fmap (\a -> ls { lsGraph = a }) $ G.sync rg')
#endif
        ]
