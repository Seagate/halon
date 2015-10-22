-- |
-- Copyright: (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- A wraper for Data.UUID.V4 from the uuid package.
--
{-# LANGUAGE PackageImports #-}
module Data.UUID.V4 (nextRandom) where

import "uuid" Data.UUID (UUID)
import qualified "uuid" Data.UUID.V4 as U (nextRandom)
import           Control.Concurrent.MVar
import           Control.Distributed.Process.Internal.Types (LocalProcess(..))
import qualified "distributed-process" Control.Distributed.Process.Node as DPN
import qualified Control.Distributed.Process.Scheduler.Internal as Internal
import qualified "distributed-process" Control.Distributed.Process as DP

ifSchedulerIsEnabled :: a -> a -> a
ifSchedulerIsEnabled a b
    | Internal.schedulerIsEnabled = a
    | otherwise                   = b

schedNextRandom :: IO UUID
schedNextRandom = do
    mv <- newEmptyMVar
    sproc <- Internal.getScheduler
    _ <- DPN.forkProcess (processNode sproc) $ do
      self <- DP.getSelfPid
      DP.send (processId sproc) $ Internal.NextRandom self
      DP.expect >>= DP.liftIO . putMVar mv
    takeMVar mv

{-# NOINLINE nextRandom #-}
nextRandom :: IO UUID
nextRandom = ifSchedulerIsEnabled schedNextRandom U.nextRandom
