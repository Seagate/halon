-- |
-- Copyright: (C) 2015 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Provides a wrapper to 'System.Clock.getTime' of the clock package and
-- reexports the rest.
--
{-# LANGUAGE PackageImports #-}
module System.Clock
  ( getTime
  , C.Clock(..)
  , C.TimeSpec(..)
  , C.diffTimeSpec
  , C.toNanoSecs
  ) where

import           Control.Concurrent.MVar
import           Control.Distributed.Process.Internal.Types (LocalProcess(..))
import qualified "distributed-process" Control.Distributed.Process.Node as DPN
import qualified Control.Distributed.Process.Scheduler.Internal as Internal
import qualified "distributed-process" Control.Distributed.Process as DP
import qualified "clock" System.Clock as C

-- | When the scheduler is enabled, this yields the value of a virtual clock
-- under the scheduler control.
--
-- When the scheduler is not enabled, performs as the function in the clock
-- package.
getTime :: C.Clock -> IO C.TimeSpec
getTime = Internal.ifSchedulerIsEnabled schedGetTime C.getTime

-- | Yields the value of the virtual clock of the scheduler.
--
-- The scheduler must be enabled for this call to succeed.
--
schedGetTime :: C.Clock -> IO C.TimeSpec
schedGetTime C.Monotonic = do
    mv <- newEmptyMVar
    sproc <- Internal.getScheduler
    _ <- DPN.forkProcess (processNode sproc) $ do
      self <- DP.getSelfPid
      Internal.schedulerTrace "System.Clock.getTime"
      DP.send (processId sproc) $ Internal.GetTime self
      DP.expect >>= DP.liftIO . putMVar mv
    t <- takeMVar mv
    let (q, r) = divMod (t :: Int) (1000 * 1000)
    return $ C.TimeSpec (fromIntegral q) (fromIntegral $ r * 1000)
schedGetTime c = error $ "scheduler.schedGetTime not defined for " ++ show c
