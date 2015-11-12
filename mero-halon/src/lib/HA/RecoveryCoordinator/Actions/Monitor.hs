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
  , masterMonitorName
    -- * Queries
  , loadNodeMonitorConf
    -- * Data types
  , StartMonitoringRequest(..)
  , StartMonitoringReply(..)
  ) where

import Prelude hiding ((.), id)
import HA.Resources
  ( Node(..)
  )

import HA.Service
import HA.Services.Monitor
import HA.Services.Monitor.Types
import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Service

import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Data.Foldable (forM_)
import Data.Maybe (fromMaybe)
import Network.CEP

masterMonitorName :: String
masterMonitorName = "halon:master-monitor"

sendToMonitor :: Serializable a => Node -> a -> PhaseM LoopState l ()
sendToMonitor node a = do
    res <- lookupRunningService node regularMonitor
    forM_ res $ \(ServiceProcess pid) ->
      liftProcess $ do
        sayRC $ "Sent to Monitor on " ++ show node ++ " to " ++ show pid
        usend pid a

-- | Sends a message to the Master Monitor.
sendToMasterMonitor :: Serializable a => a -> PhaseM LoopState l ()
sendToMasterMonitor a = liftProcess $ do
      sayRC "Sent to Master monitor"
      nsend masterMonitorName a

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

loadNodeMonitorConf :: Node -> PhaseM LoopState l MonitorConf
loadNodeMonitorConf node = do
    res <- lookupRunningService node regularMonitor
    rg  <- getLocalGraph
    let action = do
          sp <- res
          readConfig sp Current rg
    return $ fromMaybe emptyMonitorConf action
