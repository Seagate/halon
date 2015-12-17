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
       , module HA.RecoveryCoordinator.Actions.Test
       , IgnitionArguments(..)
       , GetMultimapProcessId(..)
       , ack
       , makeRecoveryCoordinator
       , lookupDLogServiceProcess
       , sendToMonitor
       , sendToMasterMonitor
       , rcInitRule
       , handled
       , startProcessingMsg
       , finishProcessingMsg
       , loadNodeMonitorConf
       , notHandled
       , buildRCState
       , timeoutHost
       ) where

import Prelude hiding ((.), id, mapM_)
import HA.EventQueue.Types (HAEvent(..))
import HA.Resources
import HA.Service
import HA.Services.DecisionLog
import HA.Services.Monitor

import qualified HA.EQTracker as EQT

import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Hardware
import HA.RecoveryCoordinator.Actions.Service
import HA.RecoveryCoordinator.Actions.Monitor
import HA.RecoveryCoordinator.Actions.Test
import qualified HA.Resources.Castor as M0
#ifdef USE_MERO
import qualified HA.Resources.Mero as M0
import HA.Resources.Mero.Note (ConfObjectState(..))
import HA.Services.Mero (notifyMero)
#endif
import qualified HA.ResourceGraph as G

import Control.Distributed.Process

import Control.Wire hiding (when)

import Data.Binary (Binary)
import Data.Dynamic
import qualified Data.Map.Strict as Map
import qualified Data.HashSet as HS
import qualified Data.Set as S
import Data.UUID (UUID)

import GHC.Generics (Generic)

import Network.CEP
import Network.HostName

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

notHandled :: HAEvent a -> LoopState -> l -> Process (Maybe (HAEvent a))
notHandled evt@(HAEvent eid _ _) ls _
    | S.member eid $ lsHandled ls = return Nothing
    | otherwise                   = return $ Just evt

handled :: HAEvent a -> PhaseM LoopState l ()
handled (HAEvent eid _ _) = do
    ls <- get Global
    let ls' = ls { lsHandled = S.insert eid $ lsHandled ls }
    put Global ls'
    sendMsg (lsEQPid ls) eid

finishProcessingMsg :: UUID -> PhaseM LoopState l ()
finishProcessingMsg eid = do
    ls <- get Global
    let ls' = ls { lsHandled = S.delete eid $ lsHandled ls }
    put Global ls'

startProcessingMsg :: UUID -> PhaseM LoopState l ()
startProcessingMsg eid = do
    ls <- get Global
    let ls' = ls { lsHandled = S.insert eid $ lsHandled ls }
    put Global ls'

rcInitRule :: IgnitionArguments
           -> RuleM LoopState (Maybe ProcessId) (Started LoopState (Maybe ProcessId))
rcInitRule argv = do
    boot        <- phaseHandle "boot"

    directly boot $ do
      h   <- liftIO getHostName
      nid <- liftProcess getSelfNode
      liftProcess $ do
         sayRC $ "My hostname is " ++ show h ++ " and nid is " ++ show (Node nid)
         sayRC $ "Executing on node: " ++ show nid
      ms   <- getNodeRegularMonitors
      liftProcess $ do
        self <- getSelfPid
        EQT.updateEQNodes $ stationNodes argv
        mpid <- spawnLocal $ do
           link self
           monitorProcess Master
        link mpid
        register masterMonitorName mpid
        usend mpid $ StartMonitoringRequest self ms
        _ <- expect :: Process StartMonitoringReply
        sayRC $ "started monitoring nodes"
        sayRC $ "continue in normal mode"

    start boot Nothing

-- | Notify mero about the node being considered down and set the
-- appropriate host attributes.
timeoutHost :: M0.Host -> PhaseM LoopState g ()
timeoutHost h = hasHostAttr M0.HA_TRANSIENT h >>= \case
  False -> return ()
  True -> do
    liftProcess . sayRC $ "Disconnecting " ++ show h ++ " due to timeout"
#ifdef USE_MERO
    g <- getLocalGraph
    let nodes = [ n
                | (c :: M0.Controller) <- G.connectedFrom M0.At h g
                , (n :: M0.Node) <- G.connectedFrom M0.IsOnHardware c g
                ]
    notifyMero (M0.AnyConfObj <$> nodes) M0_NC_FAILED
    -- TODO: do we also have to tell mero about things connected to
    -- the nodes being down?
#endif
    unsetHostAttr h M0.HA_TRANSIENT
    setHostAttr h M0.HA_DOWN

ack :: ProcessId -> PhaseM LoopState l ()
ack pid = liftProcess $ usend pid ()

lookupDLogServiceProcess :: NodeId -> LoopState -> Maybe (ServiceProcess DecisionLogConf)
lookupDLogServiceProcess nid ls =
    runningService (Node nid) decisionLog $ lsGraph ls

initialize :: ProcessId -> Process G.Graph
initialize mm = do
    rg <- G.getGraph mm
    if G.null rg then say "Starting from empty graph."
                 else say "Found existing graph."
    -- Empty graph means cluster initialization.
    let rg' | G.null rg =
            G.newResource Cluster >>>
            (\g -> g { G.grRootNodes =
                       G.grRootNodes g <> HS.singleton (G.Res Cluster) })
            $ rg
            | otherwise = rg
    return rg'

----------------------------------------------------------
-- Recovery Co-ordinator                                --
----------------------------------------------------------

buildRCState :: ProcessId -> ProcessId -> Process LoopState
buildRCState mm eq = do
    rg      <- HA.RecoveryCoordinator.Mero.initialize mm
    startRG <- G.sync rg
    return $ LoopState startRG Map.empty mm eq S.empty

-- | The entry point for the RC.
--
-- Before evaluating 'recoveryCoordinator', the global network variable needs
-- to be initialized with 'HA.Network.Address.writeNetworkGlobalIVar'. This is
-- done automatically if 'HA.Network.Address.startNetwork' is used to create
-- the transport.
makeRecoveryCoordinator :: ProcessId -- ^ pid of the replicated multimap
                        -> ProcessId -- ^ pid of the EQ
                        -> Definitions LoopState ()
                        -> Process ()
makeRecoveryCoordinator mm eq rm = do
    init_st <- buildRCState mm eq
    execute init_st $ do
      rm
      setRuleFinalizer $ \ls -> do
        newGraph <- G.sync $ lsGraph ls
        return ls { lsGraph = newGraph }

-- remotable [ 'recoveryCoordinator ]
