-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Functions to interrupt actions
--
module Control.Distributed.Process.Timeout (retry, timeout) where

import Control.Distributed.Process
import Control.Distributed.Process.Internal.Types ( runLocalProcess )
import Control.Monad.Reader ( ask )
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

-- | A version of 'System.Timeout.timeout' for the 'Process' monad.
timeout :: Int -> Process a -> Process (Maybe a)
timeout t action = ask >>= liftIO . T.timeout t . (`runLocalProcess` action)
