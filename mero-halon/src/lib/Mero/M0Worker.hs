-- |
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- An interface to manage an @m0_thread@ that consumes a queue of
-- tasks.
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
import Control.Exception (AsyncException(ThreadKilled))
import Control.Monad
import Control.Monad.Catch
import Control.Monad.IO.Class (MonadIO, liftIO)
import Mero
import Mero.Concurrent
import Mero.Engine

-- | Encapsulate 'M0Thread' along with its communication 'Chan'.
data M0Worker = M0Worker
    { m0WorkerChan   :: Chan (IO ())
    -- ^ Communication channel
    , m0WorkerThread :: M0Thread
    -- ^ Thread on which the tasks are actually ran.
    }

-- | Exception thrown to the 'M0Worker' through 'terminateM0Worker'.
data StopWorker = StopWorker deriving (Eq,Show)
instance Exception StopWorker

-- | Creates a new worker.
newM0Worker :: IO M0Worker
newM0Worker = do
    c <- newChan
    bracket_ initializeOnce
             finalizeOnce
      $ sendM0Task $ M0Worker c <$> forkM0OS (initializeOnce >> worker c)
  where
    worker c = (forever $ join $ readChan c) `catches`
                [ Handler $ \StopWorker -> return ()
                , Handler $ \ThreadKilled -> return ()
                ]

-- | Terminates a worker. Waits for all queued tasks to be executed.
terminateM0Worker :: M0Worker -> IO ()
terminateM0Worker M0Worker {..} = do
    liftGlobalM0 $ do
      writeChan m0WorkerChan $ throwM StopWorker
      joinM0OS m0WorkerThread
    finalizeOnce

-- | Queues a new task for the worker. Catches
queueM0Worker :: M0Worker -> IO () -> IO ()
queueM0Worker (M0Worker {..}) task = writeChan m0WorkerChan $
 catch task (\e -> putStrLn $ "M0Worker: " ++ show (e :: SomeException))

-- | Runs a task in a worker. Re-throws 'SomeException' from
-- 'queueM0Worker', if any.
runOnM0Worker :: (MonadIO m, MonadThrow m) => M0Worker -> IO a -> m a
runOnM0Worker M0Worker{..} task = do
    result <- liftIO $ do
      mv <- newEmptyMVar
      writeChan m0WorkerChan $ try task >>= putMVar mv
      takeMVar mv
    either throw return result
  where
    throw :: MonadThrow m => SomeException -> m a
    throw = throwM

-- | Runs the given action in the global mero worker and lifts the
-- operation into the desired monad.
--
-- The operations should be non-blocking and short-lived, otherwise consider moving
-- them to other threads.
liftGlobalM0 :: MonadIO m => IO a -> m a
liftGlobalM0 = liftIO . sendM0Task
