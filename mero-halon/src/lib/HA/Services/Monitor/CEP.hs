{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings         #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.Monitor.CEP where

import Network.CEP

import Prelude hiding (id)
import Control.Category (id)
import Data.Foldable (traverse_)

import           Control.Distributed.Process
import           Control.Monad.State
import qualified Data.Map.Strict as M

import HA.EventQueue.Producer (promulgate)
import HA.Resources
import HA.Service

data Monitored = forall a. Configuration a => Monitored (Service a)

data MonitorState = MonitorState { msMap :: !(M.Map ProcessId Monitored) }

emptyMonitorState :: MonitorState
emptyMonitorState = MonitorState M.empty

decodeMsg :: ProcessEncode a => BinRep a -> CEP s a
decodeMsg = liftProcess . decodeP

monitorService :: Configuration a
               => Service a
               -> ServiceProcess a
               -> CEP MonitorState ()
monitorService svc (ServiceProcess pid) = do
    ms <- get
    _  <- liftProcess $ monitor pid
    let m' = M.insert pid (Monitored svc) $ msMap ms
    put ms { msMap = m' }

takeMonitored :: ProcessId -> CEP MonitorState (Maybe Monitored)
takeMonitored pid = do
    ms <- get
    let mon = M.lookup pid $ msMap ms
        m'  = M.delete pid $ msMap ms
    put ms { msMap = m' }
    return mon

reportFailure :: ProcessId -> Monitored -> CEP s ()
reportFailure pid (Monitored svc) = liftProcess $ do
    self <- getSelfPid
    let node = Node $ processNodeId self
        msg  = encodeP $ ServiceFailed node svc pid
    _ <- promulgate msg
    return ()

monitorRules :: RuleM MonitorState ()
monitorRules = do
    define "monitor-notification" id $
      \(ProcessMonitorNotification _ pid _) ->
          traverse_ (reportFailure pid) =<< takeMonitored pid

    define "service-started" id $ \msg -> do
      ServiceStarted _ svc _ sp <- decodeMsg msg
      monitorService svc sp
