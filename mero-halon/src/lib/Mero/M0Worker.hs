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
    , liftGlobalM0
    , sendM0Task
    ) where

import Control.Concurrent.Chan
import Control.Concurrent.MVar
import Control.Exception
import Control.Monad
import Control.Monad.IO.Class (MonadIO, liftIO)
import Mero.Concurrent
import System.IO

import Mero

data M0Worker = M0Worker
    { m0WorkerChan   :: Chan (IO ())
    , m0WorkerThread :: M0Thread
    }

data StopWorker = StopWorker deriving (Eq,Show)

instance Exception StopWorker

-- | Creates a new worker.
newM0Worker :: IO M0Worker
newM0Worker = do
    c <- newChan
    sendM0Task $ M0Worker c <$> forkM0OS (worker c)
  where
    worker c = (forever $ join $ readChan c) `catches`
                [ Handler $ \StopWorker -> return ()
                , Handler $ \ThreadKilled -> return ()
                ]

-- | Terminates a worker. Waits for all queued tasks to be executed.
terminateM0Worker :: M0Worker -> IO ()
terminateM0Worker M0Worker {..} = do
    writeChan m0WorkerChan $ throwIO StopWorker
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


-- | Runs the given action in the global mero worker and lifts the
-- operation into the desired monad.
--
-- The operations should be non-blocking and short-lived, otherwise consider moving
-- them to other threads.
liftGlobalM0 :: MonadIO m => IO a -> m a
liftGlobalM0 = liftIO . sendM0Task
