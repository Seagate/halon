{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE LambdaCase         #-}
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
import           Data.UUID (UUID)
import           Data.UUID.V4 (nextRandom)
import qualified Data.Map.Strict as M
import qualified Data.Set        as S

import HA.EventQueue.Producer (promulgate)
import HA.Logger
import HA.Resources
import HA.Service
import HA.Services.Monitor.Types

-- | Monitor internal state.
newtype MonitorState = MonitorState { msMap :: M.Map ProcessId Monitored }

-- | Sent by heartbeat process.
data Heartbeat = Heartbeat deriving (Typeable, Generic)

instance Binary Heartbeat

-- | Sent to the monitor as a check for node connectivity
data HeartbeatAckRequest = HeartbeatAckRequest ProcessId UUID
  deriving (Eq, Show, Ord, Typeable, Generic)

instance Binary HeartbeatAckRequest

-- | Response to 'HeartbeatAckRequest'.
data HeartbeatAck = HeartbeatAck UUID
  deriving (Eq, Show, Ord, Typeable, Generic)

instance Binary HeartbeatAck

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

-- | Simple process that sends 'Heartbeat' event to main monitor thread every
--   'heartbeatDelay'.
heartbeatProcess :: ProcessId -> Process ()
heartbeatProcess mainpid = forever $ do
    _ <- receiveTimeout heartbeatDelay []
    traceMonitor $ "Sending heartbeat to " ++ show mainpid
    usend mainpid Heartbeat

decodeMsg :: ProcessEncode a => BinRep a -> PhaseM g l a
decodeMsg = liftProcess . decodeP

-- | Get a 'Monitored' from monitor internal state. That 'Monitored' will no
--   longer be accessible from monitor state after.
takeMonitored :: ProcessId -> PhaseM MonitorState l (Maybe Monitored)
takeMonitored pid = do
    ms <- get Global
    let mon = M.lookup pid $ msMap ms
        m'  = M.delete pid $ msMap ms
    put Global ms { msMap = m' }
    return mon

-- | Sends a message to the RC. Strictly speaking, it sends the message to EQ,
--   through the 'EQTracker', which forwards it to the RC.
sendToRC :: Serializable a => a -> PhaseM g l ()
sendToRC a = do
    _ <- liftProcess $ promulgate a
    return ()

-- | Monitor trace process
traceMonitor :: String -> Process ()
traceMonitor = mkHalonTracer "monitor-service"

-- | Send a message from the monitor trace process
sayMonitor :: String -> PhaseM g l ()
sayMonitor = liftProcess . traceMonitor

-- | Notifies the RC that a monitored service has died.
reportFailure :: Monitored -> PhaseM g l ()
reportFailure (Monitored pid svc _) = do
    sayMonitor $ "Notify death for " ++ show (serviceName svc) ++ " at " ++ show pid
    let node = Node $ processNodeId pid
        msg  = encodeP $ ServiceFailed node svc pid
    _ <- liftProcess $ promulgate msg
    return ()

-- | Notifies the RC that monitored service exited normally.
reportExitOk :: Monitored -> PhaseM g l ()
reportExitOk (Monitored pid svc _) = do
    sayMonitor $ "Notify normal exit for " ++ show (serviceName svc) ++ " at " ++ show pid
    let node = Node $ processNodeId pid
        msg  = encodeP $ ServiceExit node svc pid
    _ <- liftProcess $ promulgate msg
    return ()

-- | Time to wait for a heartbeat response. If the response doesn't
-- come back on time, the node is assumed to have disconnected.
heartbeatTimeout :: Int
heartbeatTimeout = 10 * 1000000

failServiceAbnormal :: ProcessId -> String -> PhaseM MonitorState l ()
failServiceAbnormal pid reason = do
  sayMonitor $ "notification about death " ++ show pid ++ "(" ++ reason ++ ")"
  traverse_ reportFailure =<< takeMonitored pid

-- | Verifies that a node is still up.
nodeHeartbeatRequest :: NodeId -> PhaseM MonitorState l ()
nodeHeartbeatRequest nid = do
  self <- liftProcess getSelfPid
  localNid <- liftProcess getSelfNode
  case nid == localNid of
    True -> sayMonitor $ "Heartbeat request to local node, doing nothing"
    False -> do
      -- TODO use sendToMonitor instead of nsendRemote
      let ServiceName mname = monitorServiceName
      uuid <- liftIO nextRandom
      let req = HeartbeatAckRequest self uuid
      liftProcess $ nsendRemote nid mname req
      sayMonitor $ "Sending " ++ show req ++ " request to " ++ show nid
      let uuidMatches = matchIf (\(HeartbeatAck uuid') -> uuid == uuid')
      liftProcess (receiveTimeout heartbeatTimeout [ uuidMatches return ]) >>= \case
        Nothing -> do
          sayMonitor $ "Heartbeat " ++ show req ++ " timed out for " ++ show nid
          sendToRC $ GetServicePids (Node nid) self
          liftProcess (expectTimeout heartbeatTimeout) >>= \case
            Nothing -> phaseLog "warn" $
              "RC didn't return failed services for " ++ show nid ++ " on time"
            Just (RunningServicePids pids) -> forM_ pids $ \pid ->
              failServiceAbnormal pid "ExplicitHeartbeatTimeout"
        Just ack@(HeartbeatAck _) -> do
          sayMonitor $ "Got heartbeat ack " ++ show ack ++ " from " ++ show nid

monitorRules :: Definitions MonitorState ()
monitorRules = do
    defineSimple "monitor-notification" $
      \(ProcessMonitorNotification _ pid reason) -> do
          case reason of
            DiedNormal -> do
              sayMonitor $ "notification about normal death " ++ show pid
              traverse_ reportExitOk =<< takeMonitored pid
            _ -> failServiceAbnormal pid $ show reason

    defineSimple "link-to" $ liftProcess . link

    defineSimple "service-started" $ \(StartMonitoringRequest caller msg) -> do
      forM_ msg $ \m -> do
        ServiceStarted _ svc _ (ServiceProcess pid) <- decodeMsg m
        ms <- get Global
        case M.lookup pid (msMap ms) of
          Just{} ->  sayMonitor $ "already monitoring " ++ show pid
          Nothing -> do ref  <- liftProcess $ monitor pid
                        sayMonitor $ "start monitoring " ++ show pid
                        let m' = M.insert pid (Monitored pid svc ref) (msMap ms)
                        put Global ms { msMap = m' }
      liftProcess $ usend caller StartMonitoringReply

    defineSimple "heartbeat" $ \Heartbeat -> do
      nids <- nodeIds
      sayMonitor $ "Got heartbeat, pinging nodes " ++ show nids
      traverse_ nodeHeartbeatRequest nids -- =<< nodeIds

    defineSimple "heartbeat-request" $ \msg@(HeartbeatAckRequest caller uuid) -> do
      let reply = HeartbeatAck uuid
      pid <- liftProcess getSelfPid
      sayMonitor $ "Got " ++ show msg ++ ", sending back " ++ show reply ++ " PID " ++ show pid
      liftProcess $ usend caller reply
