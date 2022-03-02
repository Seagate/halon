-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Functions to interrupt actions
--
module Control.Distributed.Process.Timeout (retry, timeout, callLocal) where

import Control.Concurrent.MVar
import Control.Distributed.Process hiding (mask, mask_, catch, Handler, catches)
import Control.Distributed.Process.Internal.Types
  ( runLocalProcess
  , ProcessExitException(..)
  )
import Control.Distributed.Process.Scheduler
import Control.Monad.Catch
import Control.Monad.Reader ( ask )
import Data.Binary (Binary)
import Data.Typeable (Typeable)
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
    | schedulerIsEnabled = do
        self <- getSelfPid
        -- Filled with () iff the timeout expired or the action was
        -- completed. It helps ensuring at most one of these events is
        -- considered.
        mv <- liftIO newEmptyMVar
        mask $ \unmask -> do
          timerPid <- spawnLocal $ do
            Nothing <- receiveTimeout t [] :: Process (Maybe ())
            b <- liftIO $ tryPutMVar mv ()
            if b then exit self TimeoutExit else return ()
          let handleExceptions proc = catches proc
                [ Handler $ \e@(ProcessExitException pid _) -> do
                    if pid == timerPid then return Nothing
                    else do
                      b <- liftIO $ tryPutMVar mv ()
                      if b then exit timerPid "timeout completed"
                      else waitTimeout
                      throwM e
                , Handler $ \e -> do
                    b <- liftIO $ tryPutMVar mv ()
                    if b then exit timerPid "timeout completed"
                    else waitTimeout
                    throwM (e :: SomeException)
                ]
              waitTimeout = uninterruptiblyMaskKnownExceptions_ $
                catch (receiveWait []) $ \e@(ProcessExitException pid _) ->
                  if pid == timerPid then return ()
                  else throwM e
          handleExceptions $ do
            r <- unmask action
            b <- liftIO $ tryPutMVar mv ()
            if b then do
              exit timerPid "timeout completed"
              return $ Just r
            else receiveWait []
    | otherwise = ask >>= liftIO . T.timeout t . (`runLocalProcess` action)
