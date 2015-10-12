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
       , uninterruptiblyMaskKnownExceptions_
       , __remoteTable
       ) where

import "distributed-process" Control.Distributed.Process.Node
import Control.Distributed.Process.Scheduler.Internal
  ( schedulerIsEnabled
  , addFailures
  , removeFailures
  , uninterruptiblyMaskKnownExceptions_
  )
import qualified Control.Distributed.Process.Scheduler.Internal as Internal
import "distributed-process" Control.Distributed.Process (Process, RemoteTable)
import Control.Exception (bracket)
import Control.Monad
import Network.Transport (Transport)


-- These functions are marked NOINLINE, because this way the "if"
-- statement only has to be evaluated once and not at every call site.
-- After the first evaluation, these top-level functions are simply a
-- jump to the appropriate function.

{-# NOINLINE startScheduler #-}
startScheduler :: Int -> Int -> Int -> Transport -> RemoteTable
               -> IO [LocalNode]
startScheduler = if schedulerIsEnabled
                 then Internal.startScheduler
                 else error "Scheduler not enabled."

{-# NOINLINE stopScheduler #-}
stopScheduler  :: IO ()
stopScheduler = if schedulerIsEnabled
                then Internal.stopScheduler
                else error "Scheduler not enabled."

{-# NOINLINE withScheduler #-}
withScheduler  :: Int -> Int -> Int -> Transport -> RemoteTable
               -> ([LocalNode] -> Process ()) -> IO ()
withScheduler s cs numNodes tr rt = if schedulerIsEnabled
    then Internal.withScheduler s cs numNodes tr rt
    else \p -> bracket (replicateM numNodes $ newLocalNode tr rt)
                       (mapM_ closeLocalNode) $ \(n : ns) ->
                       runProcess n $ p ns

{-# NOINLINE __remoteTable #-}
__remoteTable  :: RemoteTable -> RemoteTable
__remoteTable = if schedulerIsEnabled
                then Internal.__remoteTableDecl . Internal.__remoteTable
                else id
