{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE OverloadedStrings  #-}
-- |
-- Copyright: (C) 2015 Seagate LLC
--
module HA.Services.Monitor.CEP where

import Network.CEP

import Control.Monad
import Data.Foldable (traverse_)
import Data.Typeable
import GHC.Generics

import           Control.Distributed.Process
import           Control.Distributed.Process.Serializable
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

-- | Builds a list of every monitored services 'NodeId'. 'NodeId' that compose
--   that list are unique.
nodeIds :: PhaseM MonitorState l [NodeId]
nodeIds = fmap (S.toList . foldMap go . M.keys . msMap) $ get Global
  where
    go pid = S.singleton $ processNodeId pid

monitorState :: Processes -> Process MonitorState
monitorState (Processes ps) = do
    st <- fmap fromMonitoreds $ traverse deserializedMonitored ps
    forM_ (M.elems $ msMap st) $ \(Monitored pid _) -> do
      traceMonitor $ "start monitoring " ++ show pid
      monitor pid
    return st

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
    _ <- receiveTimeout heartbeatDelay []
    usend mainpid Heartbeat

decodeMsg :: ProcessEncode a => BinRep a -> PhaseM g l a
decodeMsg = liftProcess . decodeP

-- | By monitoring a service, we mean calling `monitor` with its `ProcessId`,
--   regitered it into monitor internal state and then persists that into
--   ReplicatedGraph.
monitoring :: Configuration a
           => Service a
           -> ServiceProcess a
           -> PhaseM MonitorState l ()
monitoring svc (ServiceProcess pid) = do
    ms <- get Global
    _  <- liftProcess $ monitor pid
    sayMonitor $ "start monitoring " ++ show pid
    let m' = M.insert pid (Monitored pid svc) (msMap ms)

    put Global ms { msMap = m' }
    sendSaveRequest

-- | Get a 'Monitored' from monitor internal state. That 'Monitored' will no
--   longer be accessible from monitor state after.
takeMonitored :: ProcessId -> PhaseM MonitorState l (Maybe Monitored)
takeMonitored pid = do
    ms <- get Global
    let mon = M.lookup pid $ msMap ms
        m'  = M.delete pid $ msMap ms

    put Global ms { msMap = m' }
    sendSaveRequest
    return mon

-- | Asks kindly the RC to persist the list of monitored services in the
--   ReplicatedGraph.
sendSaveRequest :: PhaseM MonitorState l ()
sendSaveRequest = do
    ms   <- get Global
    self <- liftProcess getSelfPid
    let ps = toProcesses ms

    sendToRC $ SaveProcesses (ServiceProcess self) (MonitorConf ps)

-- | Sends a message to the RC. Strictly speaking, it sends the message to EQ,
--   through the 'EQTracker', which forwards it to the RC.
sendToRC :: Serializable a => a -> PhaseM g l ()
sendToRC a = do
    _ <- liftProcess $ promulgate a
    return ()

traceMonitor :: String -> Process ()
traceMonitor s = say $ "[Monitor]: " ++ s

sayMonitor :: String -> PhaseM g l ()
sayMonitor = liftProcess . traceMonitor

-- | Notifies the RC that a monitored service has died.
reportFailure :: Monitored -> PhaseM g l ()
reportFailure (Monitored pid svc) = do
    sayMonitor $ "Notify death for " ++ show (serviceName svc) ++ " at " ++ show pid
    let node = Node $ processNodeId pid
        msg  = encodeP $ ServiceFailed node svc pid
    _ <- liftProcess $ promulgate msg
    return ()

-- | Verifies that a node is still up.
nodeHeartbeatRequest :: NodeId -> PhaseM g l ()
nodeHeartbeatRequest nid = liftProcess $ nsendRemote nid "nonexistentprocess" ()

monitorRules :: Definitions MonitorState ()
monitorRules = do
    defineSimple "monitor-notification" $
      \(ProcessMonitorNotification _ pid reason) -> do
          case reason of
            DiedNormal -> do
              sayMonitor $ "notification about normal death " ++ show pid
              _ <- takeMonitored pid
              return ()
            _ -> do
              sayMonitor $ "notification about death " ++ show pid ++ "(" ++ show reason ++ ")"
              traverse_ reportFailure =<< takeMonitored pid

    defineSimple "link-to" $ liftProcess . link

    defineSimple "service-started" $ \msg -> do
      ServiceStarted _ svc _ sp <- decodeMsg msg
      monitoring svc sp

    defineSimple "heartbeat" $ \Heartbeat -> do
      traverse_ nodeHeartbeatRequest =<< nodeIds
