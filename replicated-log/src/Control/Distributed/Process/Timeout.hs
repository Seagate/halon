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
