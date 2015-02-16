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
       ( recoveryCoordinator
       , IgnitionArguments(..)
       , HA.RecoveryCoordinator.Mero.__remoteTable
       , recoveryCoordinator__sdict
       , recoveryCoordinator__static
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

import Control.Distributed.Process hiding (send)
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Internal.Types ( remoteTable, processNode )
import Control.Distributed.Static (closureApply, unstatic)
import Control.Monad.Reader (ask)

import Control.Applicative ((<|>))
import Control.Category ((.))
import Control.Arrow ((>>>))
import Control.Monad (forM_, void)

import Data.Binary (Binary, Get, encode, get, put)
import Data.Binary.Put (runPut)
import Data.Binary.Get (runGet)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BS
import Data.Foldable (mapM_)
import Data.List (foldl', intersect)
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing)
#ifdef USE_RPC
import Data.Maybe (isJust)
#endif
import Data.Monoid
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Prelude hiding ((.), mapM_)

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

-- | Fake @Monoid@ instance which still satisfies @Monoid@ laws. Used to satisfy
--   `netwire` @Monoid@ constraint.
instance Monoid LoopState where
    mempty = LoopState G.unsafeEmptyGraph Map.empty

    mappend _ r = r

-- | The entry point for the RC.
--
-- Before evaluating 'recoveryCoordinator', the global network variable needs
-- to be initialized with 'HA.Network.Address.writeNetworkGlobalIVar'. This is
-- done automatically if 'HA.Network.Address.startNetwork' is used to create
-- the transport.
recoveryCoordinator :: IgnitionArguments
                    -> ProcessId -- ^ pid of the replicated event queue
                    -> ProcessId -- ^ pid of the replicated multimap
                    -> Process ()
recoveryCoordinator argv eq mm = do
    rg         <- HA.RecoveryCoordinator.Mero.initialize mm
    startGraph <- G.sync rg
    let start = LoopState { lsGraph   = startGraph
                          , lsFailMap = Map.empty
                          }

    runProcessor definitions (network eq argv) start

network :: ProcessId
        -> IgnitionArguments
        -> ComplexEvent LoopState Input LoopState
network eq argv = reconfigureCmd  <|>
                  eventqueueEvents eq argv

definitions ::     ReconfigureMsg
               .+. (    EQEvent NodeUp
                   .++. EQEvent EpochRequest
                   .++. EQEvent ConfigurationUpdateMsg
                   .++. EQEvent ServiceStartRequestMsg
                   .++. EQEvent ServiceStartedMsg
                   .++. EQEvent ServiceFailedMsg
                   .++. EQEvent ServiceCouldNotStartMsg
                   .++. EQEvent StripingError
                   .++. EQEvent EpochTransitionRequest
#ifdef USE_MERO
                   .++. EQEvent Mero.Notification.Get
                   .++. EQEvent Mero.Notification.Set
#endif
                   )
definitions = Ask

reconfigureCmd :: ComplexEvent LoopState Input LoopState
reconfigureCmd = repeatedly go . decoded
  where
    go ls@(LoopState rg _) msg = liftProcess $ do
        ReconfigureCmd n@(Node nid) svc <- decodeP msg
        SomeConfigurationDict G.Dict    <- unStatic (configDict svc)
        sayRC $ "Reconfiguring service "
                ++ (snString . serviceName $ svc)
                ++ " on node " ++ (show nid)
        _ <- reconfigureService n svc rg
        return ls

eventqueueEvents :: ProcessId
                 -> IgnitionArguments
                 -> ComplexEvent LoopState Input LoopState
eventqueueEvents eq argv =     onNodeUp argv
                           <|> epochRequest
                           <|> configurationUpdate
                           <|> serviceStart
                           <|> serviceStarted
                           <|> serviceFailed eq
                           <|> stripingError eq
                           <|> epochTransition eq
#ifdef USE_MERO
                           <|> meroGetNotification eq
                           <|> meroSetNotification eq
#endif

onNodeUp :: IgnitionArguments
         -> ComplexEvent LoopState Input LoopState
onNodeUp argv = repeatedly go . decoded
  where
    go ls@(LoopState rg _) (HAEvent _ (NodeUp pid) _) = liftProcess $ do
        let nid  = processNodeId pid
            node = Node nid
            prg  = if G.memberResource node rg
                   then return rg
                   else do
                       sayRC $ "New node contacted: " ++ show nid
                       let rg' = G.newResource node                       >>>
                                 G.newResource EQT.eqTracker              >>>
                                 G.connect Cluster Supports EQT.eqTracker >>>
                                 G.connect Cluster Has node $ rg
                       eqt <- startService nid EQT.eqTracker () rg'
                       -- Send list of EQs to the tracker
                       True <- updateEQNodes eqt (stationNodes argv)
                       return rg'
        usend pid ()
        rg'      <- prg
        newGraph <- G.sync rg'
        return ls { lsGraph = newGraph }

epochRequest :: ComplexEvent LoopState Input LoopState
epochRequest = repeatedly go . decoded
  where
    go ls@(LoopState rg _) (HAEvent _ (EpochRequest pid) _) = liftProcess $ do
        let edges :: [G.Edge Cluster Has (Epoch ByteString)]
            edges = G.edgesFromSrc Cluster rg
            G.Edge _ Has target = head edges

        usend pid $ EpochResponse $ epochId target
        return ls

configurationUpdate :: ComplexEvent LoopState Input LoopState
configurationUpdate = repeatedly go . decoded
  where
    go ls@(LoopState rg _) (HAEvent _ cum _) = liftProcess $ do
        ConfigurationUpdate epoch opts svc nodeFilter <- decodeP cum
        let edges :: [G.Edge Cluster Has (Epoch ByteString)]
            edges = G.edgesFromSrc Cluster rg
            G.Edge _ Has target = head edges

        if epoch == epochId target
            then do
                 SomeConfigurationDict G.Dict <- unStatic (configDict svc)
                 sayRC $ "Request to reconfigure service "
                         ++ snString (serviceName svc)
                         ++ " on nodes " ++ (show nodeFilter)
                 -- Write the new config as a 'Wants' config
                 let svcs = filterServices nodeFilter svc rg
                     fns  = fmap (\(_, nsvc) -> writeConfig nsvc opts Intended)
                                 svcs
                     rgUpdate = foldl' (flip (.)) id fns
                     rg'      = rgUpdate rg
                 -- Send a message to ourselves asking to reconfigure
                 self <- getSelfPid
                 mapM_ (usend self . encodeP . (flip ReconfigureCmd) svc . fst) svcs
                 newGraph <- G.sync rg'
                 return ls { lsGraph = newGraph }
            else return ls

serviceStart :: ComplexEvent LoopState Input LoopState
serviceStart = repeatedly go . decoded
  where
    go ls@(LoopState rg _) evt@(HAEvent _ ssrm _) = liftProcess $ do
        ServiceStartRequest n@(Node nid) svc c <- decodeP ssrm
        if G.memberResource n rg && (isNothing $ runningService n svc rg)
            then do
                SomeConfigurationDict G.Dict <- unStatic (configDict svc)
                sayRC $ "Request to start service "
                        ++ snString (serviceName svc)
                        ++ " on node " ++ (show n)
                let rg' = G.newResource svc >>>
                          G.connect Cluster Supports svc $ rg
                _ <- startService nid svc c rg'
                newGraph <- G.sync rg'
                return ls { lsGraph = newGraph }
            else do
                 s <- getSelfPid
                 usend s evt
                 return ls

serviceStarted :: ComplexEvent LoopState Input LoopState
serviceStarted = repeatedly go . decoded
  where
    go ls@(LoopState rg _) (HAEvent _ ssm _) = liftProcess $ do
        ServiceStarted n (svc @ Service {..}) cfg sp <- decodeP ssm
        SomeConfigurationDict G.Dict <- unStatic configDict
        sayRC $ "Service successfully started: " ++ snString serviceName
        let rg' = case runningService n svc rg of
                    Just sp' -> G.disconnect sp' Owns serviceName >>>
                                G.disconnect n Runs sp'           >>>
                                G.disconnect svc InstanceOf sp
                    Nothing -> G.newResource serviceName
                  >>> G.newResource sp
                  >>> G.connect n Runs sp
                  >>> G.connect svc InstanceOf sp
                  >>> G.connect sp Owns serviceName
                  >>> writeConfig sp cfg Current $ rg
        newGraph <- G.sync rg'
        return ls { lsGraph = newGraph }

serviceFailed :: ProcessId -> ComplexEvent LoopState Input LoopState
serviceFailed eq = repeatedly go . decoded
  where
    go ls@(LoopState rg _) (HAEvent eid sfm _) = liftProcess $ do
        ServiceFailed n srv@(Service _ _ sdict) <- decodeP sfm
        SomeConfigurationDict G.Dict <- unStatic sdict
        sayRC $ "Notified of service failure: " ++ show (serviceName srv)
        -- XXX check for timeout.
        _ <- restartService n srv rg
        usend eq eid
        return ls
serviceCouldNotStart :: ProcessId
                     -> ComplexEvent LoopState Input LoopState
serviceCouldNotStart eq = repeatedly go . decoded
  where
    go ls@(LoopState rg failmap) (HAEvent eid scns _) = liftProcess $ do
        ServiceCouldNotStart node srv@(Service _ _ sdict) <- decodeP scns
        SomeConfigurationDict G.Dict <- unStatic sdict
        -- Update the fail map to record this failure
        let sName       = serviceName srv
            failmap'    = Map.update (Just . succ) (sName, node) failmap
            failedCount = Map.findWithDefault 0 (sName, node) failmap'

        usend eq eid
        -- If we have failed too many times, stop and remove any new config.
        if failedCount >= reconfFailureLimit
            then do
              -- XXX notify the operator in a more appropriate manner.
              sayRC $ "Can't start service: " ++ show (serviceName srv)
              let failmap'' = Map.delete (sName, node) failmap'
              rg' <- case runningService node srv rg of
                       Just sp -> G.sync $ disconnectConfig sp Intended rg
                       Nothing -> return rg
              _ <- restartService node srv rg
              return ls { lsGraph   = rg'
                        , lsFailMap = failmap''
                        }
            else do
              _ <- reconfigureService node srv rg
              return ls { lsFailMap = failmap' }

stripingError :: ProcessId
              -> ComplexEvent LoopState Input LoopState
stripingError eq = repeatedly go . decoded
  where
    go ls@(LoopState rg _) (HAEvent eid (StripingError node) _) = liftProcess $
        if G.memberResource node rg
        then do
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
                m0Instances = [ i1 | m0node <- (G.connectedTo Cluster Has rg'
                                              :: [Node])
                                   , i1 <- (G.connectedTo m0node Runs rg'
                                            :: [ServiceProcess ()])
                                   , i2 <- (G.connectedTo m0d InstanceOf rg'
                                            :: [ServiceProcess ()])
                                   , i1 == i2 ]

            -- Broadcast new epoch.
            forM_ m0Instances $ \(ServiceProcess pid) ->
              usend pid EpochTransition
                       { etCurrent = epochId current
                       , etTarget  = epochId target
                       , etHow     = epochState target :: ByteString
                       }
            usend eq eid
            newGraph <- G.sync rg'
            return ls { lsGraph = newGraph }
        else return ls

epochTransition :: ProcessId
                -> ComplexEvent LoopState Input LoopState
epochTransition eq = repeatedly go . decoded
  where
    go ls@(LoopState rg _) (HAEvent eid EpochTransitionRequest{..}  _) =
        liftProcess $ do
          let G.Edge _ Has target = head $ G.edgesFromSrc Cluster rg
          usend etrSource EpochTransition
                         { etCurrent = etrCurrent
                         , etTarget  = epochId target
                         , etHow     = epochState target :: ByteString
                         }
          usend eq eid
          return ls

#ifdef USE_MERO
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
            nsendRemote them (serviceName m0d) $
              Mero.Notification.Set nvec
          usend eq eid
          newGraph <- G.sync rg'
          return ls { lsGraph = newGraph }

#endif

remotable [ 'recoveryCoordinator ]
