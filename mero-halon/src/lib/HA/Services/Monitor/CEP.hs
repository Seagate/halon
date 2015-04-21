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

import HA.EventQueue.Producer (promulgate)
import HA.ResourceGraph
import HA.Resources
import HA.Service
import HA.Services.Monitor.Types

data MonitorState = MonitorState { msMap :: !(M.Map ProcessId Monitored) }

data Heartbeat = Heartbeat deriving (Typeable, Generic)

instance Binary Heartbeat

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

decodeMsg :: ProcessEncode a => BinRep a -> CEP s a
decodeMsg = liftProcess . decodeP

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

syncRG :: Service MonitorConf
       -> ProcessId
       -> CEP MonitorState a
       -> CEP MonitorState a
syncRG monSvc mmid action = do
    old <- get
    res <- action
    new <- get
    rg  <- liftProcess $ getGraph mmid
    let rg' = disconnect monSvc Monitor (toProcesses old) >>>
              connect monSvc Monitor (toProcesses new) $ rg
    _ <- liftProcess $ sync rg'
    return res

monitorService :: Configuration a
               => Service MonitorConf
               -> ProcessId
               -> Service a
               -> ServiceProcess a
               -> CEP MonitorState ()
monitorService monSvc mmid svc (ServiceProcess pid) = syncRG monSvc mmid $ do
    ms <- get
    _  <- liftProcess $ monitor pid
    let m' = M.insert pid (Monitored pid svc) (msMap ms)
    put ms { msMap = m' }

takeMonitored :: Service MonitorConf
              -> ProcessId
              -> ProcessId
              -> CEP MonitorState (Maybe Monitored)
takeMonitored monSvc mmid pid = syncRG monSvc mmid $ do
    ms <- get
    let mon = M.lookup pid $ msMap ms
        m'  = M.delete pid $ msMap ms

    put ms { msMap = m' }
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

monitorRules :: Service MonitorConf -> ProcessId -> RuleM MonitorState ()
monitorRules monSvc mmid = do
    define "monitor-notification" id $
      \(ProcessMonitorNotification _ pid _) ->
          traverse_ (reportFailure pid) =<< takeMonitored monSvc mmid pid

    define "service-started" id $ \msg -> do
      ServiceStarted _ svc _ sp <- decodeMsg msg
      monitorService monSvc mmid svc sp

    define "heartbeat" id $ \Heartbeat ->
      traverse_ nodeHeartbeatRequest =<< nodeIds
