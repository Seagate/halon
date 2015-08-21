-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
--
-- Helper functions that are not defined in base
module Data.Traversable.Lib
  ( mapAccumLM ) where

import Control.Monad.State.Strict

-- |The 'mapAccumLM' works like 'Data.Traversable.mapAccumL' but
-- could perform effectfull operations.
mapAccumLM :: (Monad m , Traversable t)
           => (a -> b -> m (a, c))
           -> a
           -> t b
           -> m (a, t c)
mapAccumLM f s t = (\(a,b) -> (b,a)) <$> runStateT (traverse go t) s
  where
    go x = do s' <- get
              (s'', x') <- lift $ f s' x
              put s''
              return x'
