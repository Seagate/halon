-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.

{-# LANGUAGE MonoLocalBinds #-}

module Control.Distributed.Process.Trans where

import Prelude hiding (Applicative, (<$>))
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Internal.CQueue
import Control.Distributed.Process.Internal.Types
import Control.Distributed.Process.Internal.Primitives
import Control.Applicative (Applicative, (<$>))
import Control.Monad
import Control.Monad.Trans
import Control.Monad.Reader (ask)


class (Applicative m, Monad m) => MonadProcess m where
    liftProcess :: Process a -> m a

newtype MatchT m b = MatchT { unMatch :: MatchOn Message (m b) }

-- | Match against any message of the right type
matchT :: (Serializable a, MonadProcess m) => (a -> m b) -> MatchT m b
matchT = matchIfT (const True)

-- | Match against any message of the right type that satisfies a predicate
matchIfT :: forall m a b. Serializable a =>
            (a -> Bool) -> (a -> m b) -> MatchT m b
matchIfT c p = MatchT $ MatchMsg $ \msg -> join $
   handleMessage msg $ \x ->
     if c x
     then Just (p x)
     else Nothing

receiveWaitT :: MonadProcess m => [MatchT m b] -> m b
receiveWaitT ms = do
    queue <- processQueue <$> liftProcess ask
    Just proc <- liftProcess $ liftIO $ dequeue queue Blocking (map unMatch ms)
    proc

receiveTimeoutT :: MonadProcess m => Int -> [MatchT m b] -> m (Maybe b)
receiveTimeoutT t ms = do
    queue <- processQueue <$> liftProcess ask
    let blockSpec = if t == 0 then NonBlocking else Timeout t
    mProc <- liftProcess $ liftIO $ dequeue queue blockSpec (map unMatch ms)
    case mProc of
      Nothing   -> return Nothing
      Just proc -> fmap Just proc
