-- |
-- Copyright : (C) 2015 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- An implementation of a batcher
--
module Control.Distributed.Process.Batcher (batcher) where

import Control.Distributed.Process
import Control.Distributed.Process.Serializable

import Control.Monad
import Data.Binary(Binary)
import Data.Function (fix)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)


data Marker = Marker
  deriving (Typeable, Generic)

instance Binary Marker

-- | @batcher s0 handleBatch@ runs a process which accumulates requests of type
-- @a@ and calls @handleBatch@ to handle the accumulated requests.
--
-- The handler can return a list of non-processed events, which will be appended
-- to the list given to the next call.
--
batcher :: Serializable a => ([a] -> Process [a]) -> Process b
batcher handleBatch = flip fix [] $ \loop xs -> do
    self <- getSelfPid
    -- Wait for a message if there are no pending messages.
    f <- if null xs then expect >>= return . (:) else return id
    xs' <- fmap f $ usend self Marker >> collectUntilMarker xs
    handleBatch xs' >>= loop
  where
    collectUntilMarker :: Serializable a => [a] -> Process [a]
    collectUntilMarker xs = fix $ \loop -> receiveWait
      [ match $ \a -> fmap (a :) loop
      , match $ \Marker -> return xs
      ]
