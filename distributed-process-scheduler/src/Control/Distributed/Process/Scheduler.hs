-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--

{-# LANGUAGE PackageImports #-}

module Control.Distributed.Process.Scheduler
       ( Internal.schedulerIsEnabled
       , startScheduler
       , stopScheduler
       , withScheduler
       , addFailures
       , removeFailures
       , AbsentScheduler(..)
       , uninterruptiblyMaskKnownExceptions_
       , __remoteTable
       ) where

import "distributed-process" Control.Distributed.Process.Node
import Control.Distributed.Process.Scheduler.Internal
  ( ifSchedulerIsEnabled
  , AbsentScheduler(..)
  , addFailures
  , removeFailures
  , uninterruptiblyMaskKnownExceptions_
  )
import qualified Control.Distributed.Process.Scheduler.Internal as Internal
import "distributed-process" Control.Distributed.Process (Process, RemoteTable)
import Control.Exception (bracket)
import Control.Monad
import Network.Transport (Transport)


startScheduler :: Int -> Int -> Int -> Transport -> RemoteTable
               -> IO [LocalNode]
startScheduler = ifSchedulerIsEnabled
                   Internal.startScheduler
                   (error "Scheduler not enabled.")

stopScheduler  :: IO ()
stopScheduler = ifSchedulerIsEnabled
                  Internal.stopScheduler
                  (error "Scheduler not enabled.")

withScheduler  :: Int -> Int -> Int -> Transport -> RemoteTable
               -> ([LocalNode] -> Process ()) -> IO ()
withScheduler s cs numNodes tr rt = ifSchedulerIsEnabled
    (Internal.withScheduler s cs numNodes tr rt)
    (\p -> bracket (replicateM numNodes $ newLocalNode tr rt)
                   (mapM_ closeLocalNode)
                   (\(n : ns) -> runProcess n $ p ns)
    )

__remoteTable  :: RemoteTable -> RemoteTable
__remoteTable = ifSchedulerIsEnabled
                  (Internal.__remoteTableDecl . Internal.__remoteTable)
                  id
