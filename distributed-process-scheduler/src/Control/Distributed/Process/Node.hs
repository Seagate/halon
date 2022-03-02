-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.

{-# LANGUAGE PackageImports #-}
module Control.Distributed.Process.Node
  ( module DPN
  , forkProcess
  ) where

import "distributed-process" Control.Distributed.Process as DP
import qualified "distributed-process" Control.Distributed.Process.Node as DPN
import           "distributed-process" Control.Distributed.Process.Node
  hiding (forkProcess)
import Control.Distributed.Process.Scheduler.Internal
  ( SchedulerMsg(..)
  , schedulerIsEnabled
  , getScheduler
  , SchedulerResponse(..)
  )

import Control.Concurrent.MVar
import Control.Distributed.Process.Internal.Types (processId)


forkProcess :: LocalNode -> Process () -> IO ProcessId
forkProcess n p | schedulerIsEnabled = do
    mv <- newEmptyMVar
    pid <- DPN.forkProcess n $ do
      self <- DP.getSelfPid
      s <- liftIO getScheduler
      DP.send (processId s) $ SpawnedProcess self self
      SpawnAck <- DP.expect
      liftIO $ putMVar mv ()
      Continue <- DP.expect
      p
    -- Don't yield the pid to the caller until the scheduler has learned
    -- of the existence of the process.
    liftIO $ takeMVar mv
    return pid
forkProcess n p = DPN.forkProcess n p
