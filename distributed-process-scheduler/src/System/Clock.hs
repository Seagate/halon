-- |
-- Copyright: (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- A wraper for System.Clock from the clock package.
--
{-# LANGUAGE PackageImports #-}
module System.Clock
  ( getTime
  , C.Clock(..)
  , C.TimeSpec(..)
  ) where

import           Control.Concurrent.MVar
import           Control.Distributed.Process.Internal.Types (LocalProcess(..))
import qualified "distributed-process" Control.Distributed.Process.Node as DPN
import qualified Control.Distributed.Process.Scheduler.Internal as Internal
import qualified "distributed-process" Control.Distributed.Process as DP
import qualified "clock" System.Clock as C

ifSchedulerIsEnabled :: a -> a -> a
ifSchedulerIsEnabled a b
    | Internal.schedulerIsEnabled = a
    | otherwise                   = b

{-# NOINLINE getTime #-}
getTime :: C.Clock -> IO C.TimeSpec
getTime = ifSchedulerIsEnabled schedGetTime C.getTime

schedGetTime :: C.Clock -> IO C.TimeSpec
schedGetTime C.Monotonic = do
    mv <- newEmptyMVar
    sproc <- Internal.getScheduler
    _ <- DPN.forkProcess (processNode sproc) $ do
      self <- DP.getSelfPid
      DP.send (processId sproc) $ Internal.GetTime self
      DP.expect >>= DP.liftIO . putMVar mv
    t <- takeMVar mv
    let (q, r) = divMod (t :: Int) (1000 * 1000)
    return $ C.TimeSpec (fromIntegral q) (fromIntegral $ r * 1000)
schedGetTime c = error $ "scheduler.schedGetTime not defined for " ++ show c
