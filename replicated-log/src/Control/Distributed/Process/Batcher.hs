-- |
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- An implementation of a batcher
--

{-# LANGUAGE MonoLocalBinds #-}

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

-- | @batcher s0 handleBatch@ runs a process which accumulates messages of type
-- @a@ and calls @handleBatch@ to handle the accumulated requests.
--
batcher :: Serializable a => (s -> [a] -> Process s) -> s -> Process b
batcher handleBatch s =
    liftM2 (:) expect collectMailbox >>= handleBatch s >>= batcher handleBatch
  where
    collectMailbox :: Serializable a => Process [a]
    collectMailbox = do
      getSelfPid >>= flip usend Marker
      flip fix [] $ \loop acc -> receiveWait
        [ match $ \a -> loop (a : acc)
        , match $ \Marker -> return $ reverse acc
        ]
