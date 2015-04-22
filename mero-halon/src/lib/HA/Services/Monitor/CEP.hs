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

data MonitorState = MonitorState { msMap :: !(M.Map ProcessId Monitored) }

data Heartbeat = Heartbeat deriving (Typeable, Generic)

instance Binary Heartbeat

newtype SaveProcesses = SaveProcesses Processes deriving (Typeable, Binary)

newtype SetMasterMonitor =
    SetMasterMonitor ProcessId
    deriving (Typeable, Binary)

heartbeatDelay :: Int
heartbeatDelay = 2 * 1000000

emptyMonitorState :: MonitorState
emptyMonitorState = MonitorState M.empty

monitorState :: Processes -> Process MonitorState
monitorState (Processes _ ps) = fmap fromMonitoreds $ traverse decodeSlot ps

fromMonitoreds :: [Monitored] -> MonitorState
fromMonitoreds = MonitorState . M.fromList . fmap go
  where
    go m@(Monitored pid _) = (pid, m)

toProcesses :: Node -> MonitorState -> Processes
toProcesses n = Processes n . fmap encodeMonitored . M.elems . msMap

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

heartbeatProcess :: ProcessId -> Process ()
heartbeatProcess mainpid = forever $ do
    liftIO $ threadDelay heartbeatDelay
    usend mainpid Heartbeat

nodeIds :: CEP MonitorState [NodeId]
nodeIds = gets (S.toList . foldMap go . M.elems . msMap)
  where
    go (Monitored pid _) = S.singleton $ processNodeId pid

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
    _ <- liftProcess $ promulgate (SaveProcesses $ toProcesses node newMs)
    return ()

takeMonitored :: ProcessId -> CEP MonitorState (Maybe Monitored)
takeMonitored pid = do
    ms   <- get
    self <- liftProcess getSelfPid
    let node  = Node $ processNodeId self
        mon   = M.lookup pid $ msMap ms
        m'    = M.delete pid $ msMap ms
        newMs = ms { msMap = m' }

    put newMs
    _ <- liftProcess $ promulgate (SaveProcesses $ toProcesses node newMs)
    return mon

reportFailure :: ProcessId -> Monitored -> CEP s ()
reportFailure pid (Monitored _ svc) = liftProcess $ do
    self <- getSelfPid
    let node = Node $ processNodeId self
        msg  = encodeP $ ServiceFailed node svc pid
    _ <- promulgate msg
    return ()

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

lookupNodeMonitorProcess :: Node -> Graph -> Maybe (ServiceProcess MonitorConf)
lookupNodeMonitorProcess node rg =
    case connectedTo node Runs rg of
      [sp] -> Just sp
      _    -> Nothing

lookupMonitorProcesses :: ServiceProcess MonitorConf -> Graph -> Maybe Processes
lookupMonitorProcesses sp rg =
    case connectedTo sp Monitor rg of
      [ps] -> Just ps
      _    -> Nothing

saveProcesses :: Processes -> CEP LoopState ()
saveProcesses new@(Processes node _) = do
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

setMasterMonitor :: ProcessId -> CEP LoopState ()
setMasterMonitor pid = do
    ls <- get
    let sp  = ServiceProcess pid :: ServiceProcess MonitorConf
        rg' = connect MasterMonitor Cluster sp $ lsGraph ls
    put ls { lsGraph = rg' }

sendToMasterMonitor :: Serializable a => a -> CEP LoopState ()
sendToMasterMonitor a = do
    rg <- gets lsGraph
    case connectedTo MasterMonitor Cluster rg :: [ServiceProcess MonitorConf] of
      [ServiceProcess pid] -> liftProcess $ usend pid a
      _                    -> return ()

monitorServiceRules :: RuleM LoopState ()
monitorServiceRules = do
    defineHAEvent "save-processes" id $ \(HAEvent _ (SaveProcesses ps) _) ->
      saveProcesses ps

    defineHAEvent "set-master-monitor" id $
      \(HAEvent _ (SetMasterMonitor pid) _) -> setMasterMonitor pid
