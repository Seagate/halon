-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

module Control.Distributed.Process.Quorum where

import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Control.Monad.Trans.Either
import Control.Monad (forM_)


-- | Wait for at least @n `div` 2 + 1@ processes to respond, where @n@ is the
-- number of processes. The provided match clauses indicate whether to abort
-- or continue waiting for quorum.
expectQuorum :: Serializable a =>
                [Match (Either e b)] -> [ProcessId] -> a -> Process (Either e [b])
expectQuorum clauses them msg = do
  forM_ them $ \α -> send α msg
  runEitherT (wait 0 [])
  where quorum = length them `div` 2 + 1
        wait n resps
          | n == quorum = return resps
          | otherwise = do
            x <- EitherT $ receiveWait clauses
            wait (n + 1) (x:resps)
