-- |
-- Copyright : (C) 2015 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- An implementation of a pool of processes
--
module Control.Distributed.Process.ProcessPool
  ( newProcessPool
  , submitTask
  , ProcessPool
  ) where

import Control.Distributed.Process

import Control.Monad
import Data.IORef
import qualified Data.Map as Map


-- | A pool of worker processes that execute tasks.
--
-- Each worker process is named with a key @k@. Tasks are submitted to a
-- specific worker using its key. While the worker is busy the tasks are queued.
-- When there are no more queued tasks the worker ceases to exist.
--
-- The next time a task is submitted the worker will be respawned.
--
newtype ProcessPool k = ProcessPool (IORef (Map.Map k (Maybe (Process ()))))

-- Each worker has an entry in the map with a closure that contains all
-- queued actions fot it.
--
-- No entry in the map is kept for defunct workers.

-- | Creates a pool with no workers.
newProcessPool :: Process (ProcessPool k)
newProcessPool = fmap ProcessPool $ liftIO $ newIORef Map.empty

-- | @submitTask pool k task@ submits a task for the worker @k@.
--
-- If worker @k@ is busy, then @submitTask@ yields @Nothing@ and the task is
-- queued until the worker is available.
--
-- If worker @k@ does not exist, then @submitTask@ yields @Just worker@ where
-- @worker@ is the worker that will execute the task and possibly other tasks
-- submitted later. Callers will likely want to run @worker@ in a newly spawned
-- thread.
--
submitTask :: Ord k
           => ProcessPool k -> k -> Process () -> Process (Maybe (Process ()))
submitTask (ProcessPool mapRef) k task = do
    liftIO $ atomicModifyIORef mapRef $ \m ->
      case Map.lookup k m of
        -- There is no worker for this key, create one.
        Nothing -> ( Map.insert k Nothing m
                   , Just $ flip onException terminateWorker $ do
                       task
                       continue
                   )
        -- Queue an action for the existing worker.
        Just mp -> ( Map.insert k (Just $ maybe task (>> task) mp) m
                   , Nothing
                   )
  where
    continue =
      join $ liftIO $ atomicModifyIORef mapRef $ \m ->
        case Map.lookup k m of
          -- Execute the next batch of queued actions.
          Just (Just p)  -> (Map.insert k Nothing m, p >> continue)
          -- There are no more queued actions. Terminate the worker.
          Just Nothing   -> (Map.delete k m, return ())
          -- The worker key was removed already (?)
          Nothing        -> (m, return ())
    -- Remove the worker key regardless of whether there are more queued
    -- actions.
    terminateWorker = liftIO $ atomicModifyIORef mapRef $ \m ->
                        (Map.delete k m, ())
