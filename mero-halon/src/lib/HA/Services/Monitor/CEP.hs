{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE OverloadedStrings  #-}
-- |
-- Copyright: (C) 2015 Seagate LLC
--
module HA.Services.Monitor.CEP where

import Network.CEP

import Prelude hiding (id)
import Control.Category (id)
import Control.Concurrent (threadDelay)
import Data.Foldable (traverse_)
import Data.Typeable
import GHC.Generics

import           Control.Distributed.Process
import           Control.Distributed.Process.Serializable
import           Control.Monad.State
import           Data.Binary (Binary)
import qualified Data.Map.Strict as M
import qualified Data.Set        as S

import HA.EventQueue.Producer (promulgate)
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
    { spPid :: !(ServiceProcess MonitorConf)
      -- ^ 'Process' where the monitoring is running.
    , spPs :: !MonitorConf
      -- ^ Serialized list of services the monitor manages.
    } deriving (Typeable, Generic)

instance Binary SaveProcesses

-- | Event send by the Master Monitor to the RC.
newtype SetMasterMonitor =
    SetMasterMonitor (ServiceProcess MonitorConf)
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

decodeMsg :: ProcessEncode a => BinRep a -> CEP s a
decodeMsg = liftProcess . decodeP

-- | By monitoring a service, we mean calling `monitor` with its `ProcessId`,
--   regitered it into monitor internal state and then persists that into
--   ReplicatedGraph.
monitoring :: Configuration a
           => Service a
           -> ServiceProcess a
           -> CEP MonitorState ()
monitoring svc (ServiceProcess pid) = do
    ms <- get
    _  <- liftProcess $ monitor pid
    let m' = M.insert pid (Monitored pid svc) (msMap ms)

    put ms { msMap = m' }
    sendSaveRequest

-- | Get a 'Monitored' from monitor internal state. That 'Monitored' will no
--   longer be accessible from monitor state after.
takeMonitored :: ProcessId -> CEP MonitorState (Maybe Monitored)
takeMonitored pid = do
    ms <- get
    let mon = M.lookup pid $ msMap ms
        m'  = M.delete pid $ msMap ms

    put ms { msMap = m' }
    sendSaveRequest
    return mon

-- | Asks kindly the RC to persist the list of monitored services in the
--   ReplicatedGraph.
sendSaveRequest ::CEP MonitorState ()
sendSaveRequest = do
    ms   <- get
    self <- liftProcess getSelfPid
    let ps = toProcesses ms

    sendToRC $ SaveProcesses (ServiceProcess self) (MonitorConf ps)

-- | Sends a message to the RC. Strictly speaking, it sends the message to EQ,
--   through the 'EQTracker', which forwards it to the RC.
sendToRC :: Serializable a => a -> CEP s ()
sendToRC a = do
    _ <- liftProcess $ promulgate a
    return ()

-- | Notifies the RC that a monitored service has died.
reportFailure :: Monitored -> CEP s ()
reportFailure (Monitored pid svc) = liftProcess $ do
    let node = Node $ processNodeId pid
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
          traverse_ reportFailure =<< takeMonitored pid

    define "service-started" id $ \msg -> do
      ServiceStarted _ svc _ sp <- decodeMsg msg
      monitoring svc sp

    define "heartbeat" id $ \Heartbeat ->
      traverse_ nodeHeartbeatRequest =<< nodeIds
