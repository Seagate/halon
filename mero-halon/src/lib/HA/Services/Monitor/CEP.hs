{-# LANGUAGE OverloadedStrings #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module HA.Services.Monitor.CEP where

import Network.CEP

import Prelude hiding (id)
import Control.Category (id)

import Control.Distributed.Process

import HA.Services.Monitor.Types

data MonitorState = MonitorState

emptyMonitorState :: MonitorState
emptyMonitorState = MonitorState

monitorRules :: RuleM MonitorState ()
monitorRules = do
    define "monitor-reply" id $ \(MonitorReply pid) -> do
      _ <- liftProcess $ monitor pid
      -- handle Monitor State
      return ()

    define "monitor-notification" id $ \(ProcessMonitorNotification _ _ _) ->
        -- Notify the RC that service is no longer available
        return ()
