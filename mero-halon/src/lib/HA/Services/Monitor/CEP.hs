{-# LANGUAGE OverloadedStrings #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.Monitor.CEP where

import Network.CEP

import Prelude hiding (id)
import Control.Arrow ((>>>))
import Control.Category (id)
import Data.Foldable (traverse_)

import           Control.Distributed.Process
import           Control.Monad.State
import qualified Data.Map.Strict as M

import HA.EventQueue.Producer (promulgate)
import HA.ResourceGraph
import HA.Resources
import HA.Service
import HA.Services.Monitor.Types

data MonitorState = MonitorState { msMap :: !(M.Map ProcessId Monitored) }

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

monitorService :: Configuration a
               => Service MonitorConf
               -> ProcessId
               -> Service a
               -> ServiceProcess a
               -> CEP MonitorState ()
monitorService monSvc mmid svc (ServiceProcess pid) = do
    ms <- get
    _  <- liftProcess $ monitor pid
    rg <- liftProcess $ getGraph mmid
    let oldMap = msMap ms
        newMap = M.insert pid (Monitored pid svc) oldMap
        newMs  = MonitorState newMap
        rg'    = disconnect monSvc Monitor (toProcesses ms) >>>
                 connect monSvc Monitor (toProcesses newMs) $ rg
    put newMs
    _ <- liftProcess $ sync rg'
    return ()

takeMonitored :: ProcessId -> CEP MonitorState (Maybe Monitored)
takeMonitored pid = do
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

monitorRules :: Service MonitorConf -> ProcessId -> RuleM MonitorState ()
monitorRules monSvc mmid = do
    define "monitor-notification" id $
      \(ProcessMonitorNotification _ pid _) ->
          traverse_ (reportFailure pid) =<< takeMonitored pid

    define "service-started" id $ \msg -> do
      ServiceStarted _ svc _ sp <- decodeMsg msg
      monitorService monSvc mmid svc sp
