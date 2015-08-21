-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Functions to interrupt actions
--
module Control.Distributed.Process.Timeout (retry, timeout, callLocal) where

import Control.Concurrent.MVar
import Control.Distributed.Process
import Control.Distributed.Process.Internal.Types ( runLocalProcess )
import Control.Distributed.Process.Scheduler (schedulerIsEnabled)
import Control.Exception (SomeException, throwIO)
import Control.Monad
import Control.Monad.Reader ( ask )
import Data.Binary (Binary)
import Data.Typeable (Typeable)
import Data.Function
import GHC.Generics (Generic)
import qualified System.Timeout as T ( timeout )

-- | Retries an action every certain amount of microseconds until it completes
-- within the given time interval.
--
-- The action is interrupted, if necessary, to retry.
--
retry :: Int  -- ^ Amount of microseconds between retries
      -> Process a -- ^ Action to perform
      -> Process a
retry t action = timeout t action >>= maybe (retry t action) return

data TimeoutExit = TimeoutExit
  deriving (Show, Typeable, Generic)

instance Binary TimeoutExit

-- | A version of 'System.Timeout.timeout' for the 'Process' monad.
timeout :: Int -> Process a -> Process (Maybe a)
timeout t action
    | schedulerIsEnabled = callLocal $ do
        self <- getSelfPid
        mv <- liftIO newEmptyMVar
        _ <- spawnLocal $ do
          Nothing <- receiveTimeout t [] :: Process (Maybe ())
          b <- liftIO $ tryPutMVar mv ()
          if b then exit self TimeoutExit else return ()
        flip catchExit (\_pid TimeoutExit -> return Nothing) $ do
          r <- action
          b <- liftIO $ tryPutMVar mv ()
          if b then return $ Just r
          else receiveWait []
    | otherwise = ask >>= liftIO . T.timeout t . (`runLocalProcess` action)

-- | An internal type used only by 'callLocal'.
data Done = Done
  deriving (Typeable,Generic)

instance Binary Done

-- XXX pending inclusion of a fix to callLocal upstream.
--
-- https://github.com/haskell-distributed/distributed-process/pull/180
callLocal :: Process a -> Process a
callLocal p = mask_ $ do
  mv <-liftIO $ newEmptyMVar
  self <- getSelfPid
  pid <- spawnLocal $ try p >>= liftIO . putMVar mv
                      >> when schedulerIsEnabled (usend self Done)
  when schedulerIsEnabled $ do
    -- The process might be killed before reading the Done message,
    -- thus some spurious Done message might exist in the queue.
    fix $ \loop -> do Done <- expect
                      b <- liftIO $ isEmptyMVar mv
                      when b loop
  liftIO (takeMVar mv >>= either (throwIO :: SomeException -> IO a) return)
    `onException` do
       -- Exit the worker and wait for it to terminate.
       bracket (monitor pid) unmonitor $ \ref -> do
         exit pid "callLocal was interrupted"
         receiveWait
           [ matchIf (\(ProcessMonitorNotification ref' _ _) -> ref == ref')
                     (const $ return ())
           ]
