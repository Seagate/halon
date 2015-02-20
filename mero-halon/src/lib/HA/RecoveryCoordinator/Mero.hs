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
       , sayRC
       , syncResourceGraph
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
       ) where

import Prelude hiding ((.), id, mapM_)
import HA.Resources
import HA.Service
#ifdef USE_MERO_NOTE
import HA.Resources.Mero (ConfObject(..), ConfObjectState(..), Is(..))
#endif
import HA.NodeAgent.Messages
import qualified HA.Services.EQTracker as EQT

import HA.EventQueue.Producer (promulgateEQ)
import qualified HA.ResourceGraph as G
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
import Control.Monad.Trans

import Control.Monad (void, mapM_)
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

-- | Fake @Monoid@ instance which still satisfies @Monoid@ laws. Used to satisfy
-- `netwire` @Monoid@ constraint.
instance Monoid LoopState where
    mempty = LoopState G.unsafeEmptyGraph Map.empty
    mappend _ r = r

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

syncResourceGraph :: State.StateT LoopState Process ()
syncResourceGraph = do
    ls       <- State.get
    newGraph <- lift $ G.sync $ lsGraph ls
    State.put ls { lsGraph = newGraph }

knownResource :: G.Resource a => a -> State.StateT LoopState Process Bool
knownResource res = do
    ls <- State.get
    return $ G.memberResource res (lsGraph ls)

registerNode :: Node -> State.StateT LoopState Process ()
registerNode node = do
    rg <- State.gets lsGraph

    let rg' = G.newResource node                       >>>
              G.newResource EQT.eqTracker              >>>
              G.connect Cluster Supports EQT.eqTracker >>>
              G.connect Cluster Has node $ rg

    State.modify $ \ls -> ls { lsGraph = rg' }

startEQTracker :: IgnitionArguments
               -> NodeId
               -> State.StateT LoopState Process ()
startEQTracker argv nid = State.gets lsGraph >>= \rg -> lift $ do
    sayRC $ "New node contacted: " ++ show nid
    eqt  <- _startService nid EQT.eqTracker () rg
    True <- updateEQNodes eqt (stationNodes argv)
    return ()

ack :: ProcessId -> State.StateT LoopState Process ()
ack pid = lift $ usend pid ()

lookupRunningService :: Configuration a
                     => Node
                     -> Service a
                     -> State.StateT LoopState Process (Maybe (ServiceProcess a))
lookupRunningService n svc =
    fmap (runningService n svc . lsGraph) State.get

isServiceRunning :: Configuration a
                 => Node
                 -> Service a
                 -> State.StateT LoopState Process Bool
isServiceRunning n svc =
    fmap (maybe False (const True)) $ lookupRunningService n svc

registerService :: Configuration a
                => Service a
                -> State.StateT LoopState Process ()
registerService svc = do
    ls <- State.get
    let rg' = G.newResource svc >>>
              G.connect Cluster Supports svc $ lsGraph ls
    State.put ls { lsGraph = rg' }

startService :: Configuration a
             => NodeId
             -> Service a
             -> a
             -> State.StateT LoopState Process ProcessId
startService n svc conf =
    lift . _startService n svc conf . lsGraph =<< State.get

unregisterPreviousServiceProcess :: Configuration a
                                 => Node
                                 -> Service a
                                 -> ServiceProcess a
                                 -> State.StateT LoopState Process ()
unregisterPreviousServiceProcess n svc sp = do
    ls <- State.get
    let rg' = G.disconnect sp Owns (serviceName svc) >>>
              G.disconnect n Runs sp                 >>>
              G.disconnect svc InstanceOf sp $ lsGraph ls
    State.put ls { lsGraph = rg' }

registerServiceName :: Configuration a
                    => Service a
                    -> State.StateT LoopState Process ()
registerServiceName svc = do
    ls <- State.get
    let rg' = G.newResource (serviceName svc) $ lsGraph ls
    State.put ls { lsGraph = rg' }

registerServiceProcess :: Configuration a
                       => Node
                       -> Service a
                       -> a
                       -> ServiceProcess a
                       -> State.StateT LoopState Process ()
registerServiceProcess n svc cfg sp = do
    ls <- State.get
    let rg' = G.newResource sp                    >>>
              G.connect n Runs sp                 >>>
              G.connect svc InstanceOf sp         >>>
              G.connect sp Owns (serviceName svc) >>>
              writeConfig sp cfg Current $ lsGraph ls

    State.put ls { lsGraph = rg' }

getSelfProcessId :: MonadTrans m => m Process ProcessId
getSelfProcessId = lift getSelfPid

sayRC :: String -> Process ()
sayRC s = say $ "Recovery Coordinator: " ++ s

sendMsg :: (MonadTrans m, Serializable a) => ProcessId -> a -> m Process ()
sendMsg pid a = lift $ usend pid a

decodeMsg :: (MonadTrans m, ProcessEncode a) => BinRep a -> m Process a
decodeMsg = lift . decodeP

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
             -> Process ProcessId
_startService node svc cfg _ = do
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
_bounceServiceTo :: Configuration a
               => ConfigRole -- ^ Configuration role to bounce to.
               -> Node -- ^ Node on which to bounce service
               -> Service a -- ^ Service to bounce
               -> G.Graph -- ^ Resource Graph
               -> Process ProcessId -- ^ Process ID of new service instance.
_bounceServiceTo role n@(Node nid) s g = case runningService n s g of
    Just sp -> go sp
    Nothing -> error "Cannot bounce non-existent service."
  where
    go sp = case readConfig sp role g of
      Just cfg -> killService nid sp Shutdown >> _startService nid s cfg g
      Nothing -> error "Cannot find current configuation"


bounceServiceTo :: Configuration a
                => ConfigRole
                -> Node
                -> Service a
                -> State.StateT LoopState Process ProcessId
bounceServiceTo role n s =
    lift . _bounceServiceTo role n s . lsGraph =<< State.get

prepareEpochResponse :: State.StateT LoopState Process EpochResponse
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
                           -> State.StateT LoopState Process ()
updateServiceConfiguration opts svc nodeFilter = do
    ls <- State.get
    lift $ sayRC $ "Request to reconfigure service "
                 ++ snString (serviceName svc)
                 ++ " on nodes " ++ (show nodeFilter)

    let rg       = lsGraph ls
        svcs     = filterServices nodeFilter svc rg
        fns      = fmap (\(_, nsvc) -> writeConfig nsvc opts Intended) svcs
        rgUpdate = foldl' (flip (.)) id fns
        rg'      = rgUpdate rg

    newGraph <- lift $ do
      self <- getSelfPid
      mapM_ (usend self . encodeP . (flip ReconfigureCmd) svc . fst) svcs
      G.sync rg'

    State.put ls { lsGraph = newGraph }

getEpochId :: State.StateT LoopState Process Word64
getEpochId = do
    rg <- State.gets lsGraph

    let edges :: [G.Edge Cluster Has (Epoch ByteString)]
        edges = G.edgesFromSrc Cluster rg
        G.Edge _ Has target = head edges

    return $ epochId target

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
makeRecoveryCoordinator :: ProcessId -- ^ pid of the replicated multimap
                        -> RuleM LoopState ()
                        -> Process ()
makeRecoveryCoordinator mm rm = do
    rg <- HA.RecoveryCoordinator.Mero.initialize mm
    start <- G.sync rg
    buildFromRuleMS (LoopState start Map.empty) rm

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
