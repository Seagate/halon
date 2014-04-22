-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE CPP #-}
{-# LANGUAGE PackageImports #-}

{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
module Control.Distributed.Process.Scheduler
  (
#ifdef USE_DETERMINISTIC_SCHEDULER
    module Internal
  , schedulerIsEnabled
#else
    module Control.Distributed.Process.Scheduler
#endif
  ) where

#ifdef USE_DETERMINISTIC_SCHEDULER
import Control.Distributed.Process.Scheduler.Internal as Internal
#else
import "distributed-process" Control.Distributed.Process
    (Process, ProcessId, RemoteTable)
#endif

-- | @True@ iff the package "distributed-process-scheduler" was built with
-- the scheduler enabled.
--
-- If @False@, all exported definitions default to the ones of the
-- "distributed-process" package.
schedulerIsEnabled :: Bool
#ifdef USE_DETERMINISTIC_SCHEDULER
schedulerIsEnabled = True
#else
startScheduler :: [ProcessId] -> Int -> Process ()
stopScheduler  :: Process ()
withScheduler  :: [ProcessId] -> Int -> Process a -> Process a
__remoteTable  :: RemoteTable -> RemoteTable

schedulerIsEnabled = False
startScheduler = error "Scheduler not enabled."
stopScheduler  = error "Scheduler not enabled."
withScheduler _ _ p = p
__remoteTable  = id
#endif
