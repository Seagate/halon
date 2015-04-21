{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE OverloadedStrings  #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
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

heartbeatDelay :: Int
heartbeatDelay = 2 * 1000000

emptyMonitorState :: MonitorState
emptyMonitorState = MonitorState M.empty

monitorState :: Processes -> Process MonitorState
monitorState (Processes ps) = fmap fromMonitoreds $ traverse decodeSlot ps

fromMonitoreds :: [Monitored] -> MonitorState
fromMonitoreds = MonitorState . M.fromList . fmap go
  where
    go m@(Monitored pid _) = (pid, m)

toProcesses :: MonitorState -> Processes
toProcesses = Processes . fmap encodeMonitored . M.elems . msMap

loadPrevProcesses :: Service MonitorConf -> ProcessId -> Process MonitorState
loadPrevProcesses svc mmid = do
    rg <- getGraph mmid
    case connectedTo svc Monitor rg of
      [ps] -> monitorState ps
      _    -> return emptyMonitorState

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
    ms <- get
    _  <- liftProcess $ monitor pid
    let m'    = M.insert pid (Monitored pid svc) (msMap ms)
        newMs = ms { msMap = m' }
    put newMs
    _ <- liftProcess $ promulgate (SaveProcesses $ toProcesses newMs)
    return ()

takeMonitored :: ProcessId -> CEP MonitorState (Maybe Monitored)
takeMonitored pid = do
    ms <- get
    let mon   = M.lookup pid $ msMap ms
        m'    = M.delete pid $ msMap ms
        newMs = ms { msMap = m' }

    put newMs
    _ <- liftProcess $ promulgate (SaveProcesses $ toProcesses newMs)
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

saveProcesses :: Service MonitorConf -> Processes -> CEP LoopState ()
saveProcesses monSvc new = do
    ls <- get
    let rg' =
            case connectedTo monSvc Monitor (lsGraph ls) :: [Processes] of
              [old] -> disconnect monSvc Monitor old >>>
                       connect monSvc Monitor new $ lsGraph ls
              _     -> connect monSvc Monitor new $ lsGraph ls
    put ls { lsGraph = rg' }

monitorServiceRulesF :: Service MonitorConf -> RuleM LoopState ()
monitorServiceRulesF monSvc = do
    defineHAEvent "save-processes" id $ \(HAEvent _ (SaveProcesses ps) _) ->
      saveProcesses monSvc ps
