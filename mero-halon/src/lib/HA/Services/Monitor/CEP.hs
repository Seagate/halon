{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE OverloadedStrings  #-}
-- |
-- Copyright: (C) 2015 Seagate LLC
--
module HA.Services.Monitor.CEP where

import Network.CEP

import Prelude hiding (id)
import Control.Arrow ((>>>))
import Control.Category (id)
import Control.Concurrent (threadDelay)
import Data.Foldable (traverse_)
import Data.Typeable
import GHC.Generics

import           Control.Distributed.Process
import           Control.Distributed.Process.Serializable (Serializable)
import           Control.Monad.State
import           Data.Binary (Binary)
import qualified Data.Map.Strict as M
import qualified Data.Set        as S

import HA.EventQueue.Consumer (HAEvent(..), defineHAEvent)
import HA.EventQueue.Producer (promulgate)
import HA.RecoveryCoordinator.Mero (LoopState(..), decodeMsg)
import HA.ResourceGraph
import HA.Resources
import HA.Service
import HA.Services.Monitor.Types

-- | Monitor internal state.
newtype MonitorState = MonitorState { msMap :: M.Map ProcessId Monitored }

-- | Sent by heartbeat process.
data Heartbeat = Heartbeat deriving (Typeable, Generic)

instance Binary Heartbeat

-- | Sent by a monitor process to the RC.
data SaveProcesses =
    SaveProcesses
    { spNode :: !Node
      -- ^ Node where the monitoring is running.
    , spPs   :: !Processes
      -- ^ Serialized list of services the monitor manages.
    } deriving (Typeable, Generic)

instance Binary SaveProcesses

-- | Event send by the Master Monitor to the RC.
newtype SetMasterMonitor =
    SetMasterMonitor ProcessId
    deriving (Typeable, Binary)

-- | Delay (seconds) at which the heartbeat process sends a 'Heartbeat' event to
--   main monitor process thread.
heartbeatDelay :: Int
heartbeatDelay = 2 * 1000000

emptyMonitorState :: MonitorState
emptyMonitorState = MonitorState M.empty

monitorState :: Processes -> Process MonitorState
monitorState (Processes ps) =
    fmap fromMonitoreds $ traverse deserializedMonitored ps

fromMonitoreds :: [Monitored] -> MonitorState
fromMonitoreds = MonitorState . M.fromList . fmap go
  where
    go m@(Monitored pid _) = (pid, m)

-- | Serializes a monitor state to 'Processes'.
toProcesses :: MonitorState -> Processes
toProcesses = Processes . fmap encodeMonitored . M.elems . msMap

-- | Loads monitor's 'Processes' from the ReplicatedGraph and construct a
--   'MonitorState' out of it.
loadPrevProcesses :: ProcessId -> Process MonitorState
loadPrevProcesses mmid = do
    rg   <- getGraph mmid
    self <- getSelfPid
    let node   = Node $ processNodeId self
        action = do
          sp <- lookupNodeMonitorProcess node rg
          lookupMonitorProcesses sp rg
    case action of
      Just ps -> monitorState ps
      _       -> return emptyMonitorState

-- | Simple process that sends 'Heartbeat' event to main monitor thread every
--   'heartbeatDelay'.
heartbeatProcess :: ProcessId -> Process ()
heartbeatProcess mainpid = forever $ do
    liftIO $ threadDelay heartbeatDelay
    usend mainpid Heartbeat

-- | Builds a list of every monitored services 'NodeId'. 'NodeId' that compose
--   that list are unique.
nodeIds :: CEP MonitorState [NodeId]
nodeIds = gets (S.toList . foldMap go . M.elems . msMap)
  where
    go (Monitored pid _) = S.singleton $ processNodeId pid

-- | By monitoring a service, we mean calling `monitor` with its `ProcessId`,
--   regitered it into monitor internal state and then persists that into
--   ReplicatedGraph.
monitorService :: Configuration a
               => Service a
               -> ServiceProcess a
               -> CEP MonitorState ()
monitorService svc (ServiceProcess pid) = do
    ms   <- get
    _    <- liftProcess $ monitor pid
    self <- liftProcess getSelfPid
    let node  = Node $ processNodeId self
        m'    = M.insert pid (Monitored pid svc) (msMap ms)
        newMs = ms { msMap = m' }
    put newMs
    _ <- liftProcess $ promulgate (SaveProcesses node $ toProcesses newMs)
    return ()

-- | Get a 'Monitored' from monitor internal state. That 'Monitored' will no
--   longer be accessible from monitor state after.
takeMonitored :: ProcessId -> CEP MonitorState (Maybe Monitored)
takeMonitored pid = do
    ms   <- get
    self <- liftProcess getSelfPid
    let node  = Node $ processNodeId self
        mon   = M.lookup pid $ msMap ms
        m'    = M.delete pid $ msMap ms
        newMs = ms { msMap = m' }

    put newMs
    _ <- liftProcess $ promulgate (SaveProcesses node $ toProcesses newMs)
    return mon

-- | Notifies the RC that a monitored service has died.
reportFailure :: ProcessId -> Monitored -> CEP s ()
reportFailure pid (Monitored _ svc) = liftProcess $ do
    self <- getSelfPid
    let node = Node $ processNodeId self
        msg  = encodeP $ ServiceFailed node svc pid
    _ <- promulgate msg
    return ()

-- | Verifies that a node is still up.
nodeHeartbeatRequest :: NodeId -> CEP s ()
nodeHeartbeatRequest nid = liftProcess $ nsendRemote nid "nonexistentprocess" ()

monitorRules :: RuleM MonitorState ()
monitorRules = do
    define "monitor-notification" id $
      \(ProcessMonitorNotification _ pid _) ->
          traverse_ (reportFailure pid) =<< takeMonitored pid

    define "service-started" id $ \msg -> do
      ServiceStarted _ svc _ sp <- decodeMsg msg
      monitorService svc sp

    define "heartbeat" id $ \Heartbeat ->
      traverse_ nodeHeartbeatRequest =<< nodeIds

-- | Gets the monitor 'ProcessId' given a 'Node' from the ReplicatedGraph.
lookupNodeMonitorProcess :: Node -> Graph -> Maybe (ServiceProcess MonitorConf)
lookupNodeMonitorProcess node rg =
    case connectedTo node Runs rg of
      [sp] -> Just sp
      _    -> Nothing

-- | Gets monitor's 'Processes' given its `ProcessId`
lookupMonitorProcesses :: ServiceProcess MonitorConf -> Graph -> Maybe Processes
lookupMonitorProcesses sp rg =
    case connectedTo sp Monitor rg of
      [ps] -> Just ps
      _    -> Nothing

--------------------------------------------------------------------------------
-- RC actions
--
-- From here those actions have to be expected to run on the RC.
--------------------------------------------------------------------------------
-- | Persists monitor's 'Processes' into the ReplicatedGraph.
saveProcesses :: Node -> Processes -> CEP LoopState ()
saveProcesses node new = do
    ls <- get
    let rg' =
            case lookupNodeMonitorProcess node $ lsGraph ls of
              Just sp ->
                case lookupMonitorProcesses sp $ lsGraph ls of
                  Just old -> disconnect sp Monitor old >>>
                              connect sp Monitor new $ lsGraph ls
                  _        -> connect sp Monitor new $ lsGraph ls
              _ -> lsGraph ls

    put ls { lsGraph = rg' }

-- | Registers the Master Monitor into the ReplicatedGraph.
setMasterMonitor :: ProcessId -> CEP LoopState ()
setMasterMonitor pid = do
    ls <- get
    let sp  = ServiceProcess pid :: ServiceProcess MonitorConf
        rg' = connect MasterMonitor Cluster sp $ lsGraph ls
    put ls { lsGraph = rg' }

-- | Sends a message to the Master Monitor.
sendToMasterMonitor :: Serializable a => a -> CEP LoopState ()
sendToMasterMonitor a = do
    rg <- gets lsGraph
    case connectedTo MasterMonitor Cluster rg :: [ServiceProcess MonitorConf] of
      [ServiceProcess pid] -> liftProcess $ usend pid a
      _                    -> return ()

-- | Monitor infrastructure that needs be handle in the RC.
monitorServiceRules :: RuleM LoopState ()
monitorServiceRules = do
    defineHAEvent "save-processes" id $
      \(HAEvent _ (SaveProcesses node ps) _) -> saveProcesses node ps

    defineHAEvent "set-master-monitor" id $
      \(HAEvent _ (SetMasterMonitor pid) _) -> setMasterMonitor pid
