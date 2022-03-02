-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Functions to interrupt actions when monitor notifications arrive.
--
module Control.Distributed.Process.Monitor
    ( retryMonitoring
    , withMonitoring
    ) where

import Control.Distributed.Process
    ( exit
    , link
    , matchIf
    , newChan
    , receiveChan
    , receiveTimeout
    , receiveWait
    , sendChan
    , spawnLocal
    , unlink
    , MonitorRef
    , Process
    , ProcessLinkException(..)
    , ProcessMonitorNotification(..)
    )

import Control.Monad (join)
import Control.Monad.Catch


-- | Runs the given action, but returns 'Nothing' if monitoring
-- produces a notification.
--
-- TODO: Don't leak ProcessLinkExceptions to the caller when this
-- call is interrupted.
--
withMonitoring :: Process MonitorRef -> Process b -> Process (Maybe b)
withMonitoring mon action = do
    (sp, rp) <- newChan
    pid <- spawnLocal $ do
      ref <- mon
      sendChan sp ()
      receiveWait
        [ matchIf (\(ProcessMonitorNotification ref' _ _) -> ref == ref')
                  $ const (return ())
        ]
    do bracket_ (link pid) (unlink pid >> exit pid "withMonitoring finished") $
         receiveChan rp >> fmap Just action
     `catch` \e@(ProcessLinkException pid' _ ) ->
        if pid == pid'
          then return Nothing
          else throwM e

-- | Runs the given action using 'withMonitoingr'. If it produces 'Nothing', it
-- waits the given delay of microseconds and retries repeteadly until the action
-- succeeds or fails with an exception.
retryMonitoring :: Process MonitorRef -> Int -> Process (Maybe b) -> Process b
retryMonitoring mon delay action =
    withMonitoring mon action >>=
      maybe (receiveTimeout delay [] >> retryMonitoring mon delay action) return
      . join
