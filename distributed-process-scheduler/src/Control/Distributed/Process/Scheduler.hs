-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE PackageImports #-}

module Control.Distributed.Process.Scheduler
       ( schedulerIsEnabled
       , startScheduler
       , stopScheduler
       , withScheduler
       , addFailures
       , removeFailures
       , __remoteTable
       ) where

import Control.Distributed.Process.Scheduler.Internal
  ( schedulerIsEnabled
  , addFailures
  , removeFailures
  )
import qualified Control.Distributed.Process.Scheduler.Internal as Internal
import "distributed-process" Control.Distributed.Process (Process, ProcessId, RemoteTable)

-- These functions are marked NOINLINE, because this way the "if"
-- statement only has to be evaluated once and not at every call site.
-- After the first evaluation, these top-level functions are simply a
-- jump to the appropriate function.

{-# NOINLINE startScheduler #-}
startScheduler :: [ProcessId] -> Int -> Int -> Process ()
startScheduler = if schedulerIsEnabled
                 then Internal.startScheduler
                 else error "Scheduler not enabled."

{-# NOINLINE stopScheduler #-}
stopScheduler  :: Process ()
stopScheduler = if schedulerIsEnabled
                then Internal.stopScheduler
                else error "Scheduler not enabled."

{-# NOINLINE withScheduler #-}
withScheduler  :: [ProcessId] -> Int -> Int -> Process a -> Process a
withScheduler = if schedulerIsEnabled
                then Internal.withScheduler
                else \_ _ _ p -> p

{-# NOINLINE __remoteTable #-}
__remoteTable  :: RemoteTable -> RemoteTable
__remoteTable = if schedulerIsEnabled
                then Internal.__remoteTable
                else id
