-- |
-- Copyright : (C) 2014-2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Control mero system lifetime by introducing singletons
-- objects.
module Mero.Engine
  ( initializeOnce
  , finalizeOnce
  , withMero
  ) where

import Mero

import Control.Concurrent (forkOS, myThreadId)
import Control.Concurrent.MVar
import Control.Distributed.Process hiding (bracket_, catch)
import Control.Exception (throwTo)
import Control.Monad (when)
import Control.Monad.Catch (bracket_, catch)
import Data.Functor (void)
import System.IO.Unsafe (unsafePerformIO)

-- | Reference counter of the entities that are using mero.
m0subsystemReferenceCounter :: MVar Int
m0subsystemReferenceCounter = unsafePerformIO $ newMVar 0
{-# NOINLINE m0subsystemReferenceCounter #-}

-- | MVar that signals that mero subsystem can be closed.
-- Empty if subsystem should not be closed, full if it can be
-- closed.
m0subsystemClose :: MVar ()
m0subsystemClose = unsafePerformIO $ newEmptyMVar
{-# NOINLINE m0subsystemClose #-}

-- | MVar that signals that mero subsystem was closed.
-- Full if subsystem was closed.
m0subsystemClosed :: MVar ()
m0subsystemClosed = unsafePerformIO $ newEmptyMVar
{-# NOINLINE m0subsystemClosed #-}


-- | Intialize mero subsytem in the program.
--
-- If mero subsystem was not initialized it starts a bounded
-- mero thread (main mero thread) and creates mero worker that
-- could be used to run mero actions in the mero thread.
--
-- This thread is waiting for a signal to finalize subsystem.
--
-- After exit of the 'initializeOnce' it's guaranteed that
-- mero subsystem will stay alive until 'finalizeOnce' was
-- called.
initializeOnce :: IO ()
initializeOnce =
  modifyMVar_ m0subsystemReferenceCounter $ \i -> do
    when (i == 0) $ do
      started <- newEmptyMVar
      callerId <- myThreadId
      void $ forkOS $ do
        rethrowingTo callerId . withM0 $ do
          putMVar started ()
          takeMVar m0subsystemClose
        putMVar m0subsystemClosed ()
      takeMVar started
    return (i+1)
   where
     rethrowingTo tid f = catch f $ \e -> throwTo tid (e :: IOError)

-- | Finalize mero subsystem if it's unused.
--
-- If mero subsystem is not used this call will block until mero
-- subsystem is fully uninitialized.
finalizeOnce :: IO ()
finalizeOnce = modifyMVar_ m0subsystemReferenceCounter $ \i -> do
  when (i-1 == 0) $ do
    putMVar m0subsystemClose ()
    takeMVar m0subsystemClosed
  return (i-1)

-- | Run code with mero environment being enabled.
withMero :: Process () -> Process ()
withMero = bracket_ (liftIO initializeOnce) (liftIO finalizeOnce)
