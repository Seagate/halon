-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- An interface to manage an m0_thread that consumes a queue of tasks.
--
module Mero.M0Worker
    ( M0Worker
    , newM0Worker
    , terminateM0Worker
    , queueM0Worker
    , runOnM0Worker
    , startGlobalWorker
    , getGlobalWorker
    , runOnGlobalM0Worker
    ) where

import Control.Concurrent.Chan
import Control.Concurrent.MVar
import Control.Exception
import Control.Monad
import Data.IORef
import Mero.Concurrent
import System.IO.Unsafe


data M0Worker = M0Worker
    { m0WorkerChan   :: Chan (IO ())
    , m0WorkerThread :: M0Thread
    }

-- | Creates a new worker.
newM0Worker :: IO M0Worker
newM0Worker = do
    c <- newChan
    fmap (M0Worker c) $ forkM0OS (worker c)
  where
    worker c = forever $ join $ readChan c

-- | Terminates a worker. Waits for all queued tasks to be executed.
terminateM0Worker :: M0Worker -> IO ()
terminateM0Worker M0Worker {..} =
    writeChan m0WorkerChan $ error "terminated by terminateM0Worker"
    joinM0OS m0WorkerThread

-- | Queues a new task for the worker.
queueM0Worker :: M0Worker -> IO () -> IO ()
queueM0Worker (M0Worker {..}) task = do
    writeChan m0WorkerChan $
      catch task (\e -> putStrLn $ "M0Worker: " ++ show (e :: SomeException))

-- | Runs a task in a worker.
runOnM0Worker :: M0Worker -> IO a -> IO a
runOnM0Worker w task = do
    mv <- newEmptyMVar
    queueM0Worker w $ try task >>= putMVar mv
    takeMVar mv >>= either (throwIO :: SomeException -> IO a) return

{-# NOINLINE globalWorkerRef #-}
globalWorkerRef :: IORef (Maybe M0Worker)
globalWorkerRef = unsafePerformIO $ newIORef Nothing

-- | Starts a new worker and makes it globally available with 'getGlobalWorker'.
-- Call this from an m0_thread.
startGlobalWorker :: IO ()
startGlobalWorker = newM0Worker >>= writeIORef globalWorkerRef . Just

-- | Yields the global worker. Call 'startGlobalWorker' first.
getGlobalWorker :: IO M0Worker
getGlobalWorker = readIORef globalWorkerRef
                    >>= maybe (error "getGlobalWorker: not initialized") return

-- | Runs a task in the global worker.
runOnGlobalM0Worker :: IO a -> IO a
runOnGlobalM0Worker task = getGlobalWorker >>= flip runOnM0Worker task
