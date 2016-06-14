-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- This module implements a pool of processes with an upper bound for the amount
-- of processes that it can use.
module Control.Distributed.Process.Pool.Bounded
    ( ProcessPool
    , newProcessPool
    , submitTask
    ) where

import Control.Distributed.Process hiding (catch, finally, mask_, try)

import Control.Monad (join)
import Control.Monad.Catch
import Data.IORef (IORef, atomicModifyIORef, newIORef)
import Data.Sequence as Seq


-- | A pool of processes that execute tasks.
--
-- It is restricted to produce only a bounded amount of processes.
--
data ProcessPool = ProcessPool
    { ppBound :: Int -- ^ Maximum amount of processes that can be created
    , ppRef   :: IORef PoolState -- ^ Reference to the pool state
    }

-- | The state of a pool
data PoolState = PoolState
    { psCount :: !Int  -- ^ Amount of processes in the pool
    , psQueue :: !(Seq (Process ())) -- ^ The queue of tasks
    }

-- | Creates a new pool with the given bound for the amount of processes.
newProcessPool :: Int -> IO ProcessPool
newProcessPool bound =
  fmap (ProcessPool bound) (newIORef $ PoolState 0 Seq.empty)

-- | @submitTask pool task@ submits a task to the pool.
--
-- If there are less processes than the bound, then @submitTask@ yields
-- @Just proc@ where @proc@ is the computation that will execute the task and
-- possibly other tasks submitted later. Callers will likely want to run
-- @proc@ in a newly spawned process.
--
-- If there are as many processes as the bound, then @submitTask@ yields
-- @Nothing@ and the task is queued until the first worker becomes available.
--
-- A task which ends with an exception ends the process immediately and prevents
-- other tasks from running on it.
--
submitTask :: ProcessPool -> Process () -> Process (Maybe (Process ()))
submitTask (ProcessPool {..}) t =
    liftIO $ atomicModifyIORef ppRef $ \ps@(PoolState {..}) ->
      if psCount < ppBound then
        -- Increase the process count if there is capacity.
        ( PoolState (succ psCount) psQueue
        , Just ((t >> continue) `finally` terminate)
        )
      else
        -- Queue the task if the process bound has been reached.
        (ps { psQueue = psQueue |> t}, Nothing)
  where
    continue :: Process ()
    continue = join $ liftIO $ atomicModifyIORef ppRef $ \ps@(PoolState {..}) ->
      case viewl psQueue of
        -- Terminate if there are no more tasks in the queue.
        EmptyL -> (ps, return ())
        -- Continue with a task from the queue if available.
        next :< s -> (ps { psQueue = s}, next >> continue)

    -- Decrement the process count when a process terminates.
    terminate :: Process ()
    terminate = liftIO $ atomicModifyIORef ppRef $ \ps ->
      (ps { psCount = pred (psCount ps) }, ())
