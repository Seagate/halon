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
import Data.Typeable (Typeable)
import GHC.Generics (Generic)


data Marker = Marker
  deriving (Typeable, Generic)

instance Binary Marker

-- | @batcher handleBatch@ runs a process which accumulates requests of type @a@
-- and calls @handleBatch@ to handle the accumulated requests.
--
batcher :: Serializable a => ([a] -> Process ()) -> Process b
batcher handleBatch = do
    self <- getSelfPid
    liftM2 (:) expect (usend self Marker >> collectUntilMarker) >>= handleBatch
    batcher handleBatch
  where
    collectUntilMarker :: Serializable a => Process [a]
    collectUntilMarker = receiveWait
      [ match $ \a -> fmap (a :) collectUntilMarker
      , match $ \Marker -> return []
      ]
