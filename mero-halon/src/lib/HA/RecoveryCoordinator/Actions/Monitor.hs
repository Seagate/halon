-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
module HA.RecoveryCoordinator.Actions.Monitor
  ( -- * Communication
    sendToMonitor
  , sendToMasterMonitor
  , startProcessMonitoring
  , startNodesMonitoring
    -- * Queries
  , lookupMasterMonitor
  , stealMasterMonitorConf
  , loadNodeMonitorConf
  , registerMasterMonitor
    -- * Data types
  , StartMonitoringRequest(..)
  , StartMonitoringReply(..)
  ) where

import Prelude hiding ((.), id)
import qualified HA.ResourceGraph as G
import HA.Resources
  ( Cluster(..)
  , Node(..)
  )

import HA.Service
import HA.Services.Monitor
import HA.Services.Monitor.Types
import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Service

import Control.Applicative
import Control.Category
import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Data.Foldable (forM_)
import Data.Maybe (fromMaybe)
import Network.CEP

sendToMonitor :: Serializable a => Node -> a -> PhaseM LoopState l ()
sendToMonitor node a = do
    res <- lookupRunningService node regularMonitor
    forM_ res $ \(ServiceProcess pid) ->
      liftProcess $ do
        sayRC $ "Sent to Monitor on " ++ show node ++ " to " ++ show pid
        usend pid a

-- | Sends a message to the Master Monitor.
sendToMasterMonitor :: Serializable a => a -> PhaseM LoopState l ()
sendToMasterMonitor a = do
    self <- liftProcess getSelfNode
    spm  <- fmap lookupMasterMonitor getLocalGraph
    -- In case the `MasterMonitor` link is not established, look for a
    -- local instance
    spm' <- lookupRunningService (Node self) masterMonitor
    forM_ (spm <|> spm') $ \(ServiceProcess mpid) -> liftProcess $ do
      sayRC "Sent to Master monitor"
      usend mpid a

-- | Start monitoring nodes
startNodesMonitoring :: [ServiceStartedMsg] -> PhaseM LoopState l ()
startNodesMonitoring ms = do
  self <- liftProcess getSelfPid
  sendToMasterMonitor (StartMonitoringRequest self ms)


-- | Start monitoring Services located on the Node.
startProcessMonitoring :: Node -> [ServiceStartedMsg] -> PhaseM LoopState l ()
startProcessMonitoring node ms = do
  self <- liftProcess getSelfPid
  sendToMonitor node (StartMonitoringRequest self ms)

-- | Find master monitor in the ResourceGraph.
lookupMasterMonitor :: G.Graph -> Maybe (ServiceProcess MonitorConf)
lookupMasterMonitor rg =
    case G.connectedTo Cluster MasterMonitor rg of
      [sp] -> Just sp
      _    -> Nothing

stealMasterMonitorConf :: PhaseM LoopState l MonitorConf
stealMasterMonitorConf = do
    rg <- getLocalGraph
    let action = do
          sp   <- lookupMasterMonitor rg
          conf <- readConfig sp Current rg
          return (sp, conf)
    case action of
      Nothing         -> return emptyMonitorConf
      Just (sp, conf) -> do
        let rg' = disconnectConfig sp Current >>>
                  G.disconnect Cluster MasterMonitor sp $ rg
        putLocalGraph rg'
        return conf

loadNodeMonitorConf :: Node -> PhaseM LoopState l MonitorConf
loadNodeMonitorConf node = do
    res <- lookupRunningService node regularMonitor
    rg  <- getLocalGraph
    let action = do
          sp <- res
          readConfig sp Current rg
    return $ fromMaybe emptyMonitorConf action

registerMasterMonitor :: ServiceProcess MonitorConf -> PhaseM LoopState l ()
registerMasterMonitor sp = modifyLocalGraph $ \rg ->
    return $ G.connect Cluster MasterMonitor sp rg
