-- |
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Initialization and finalization calls of mero.
--
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE ForeignFunctionInterface  #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE LambdaCase                #-}
module Mero
  ( withM0
  , sendM0Task
  , sendM0Task_
  , M0WorkerIsNotStarted(..)
  , addM0Finalizer
  ) where

import Mero.Concurrent

import Control.Concurrent
    ( forkIO
    , myThreadId
    , killThread
    , ThreadId
    , Chan
    , newChan
    , readChan
    , writeChan
    , MVar
    , newEmptyMVar
    , putMVar
    , takeMVar)
import Control.Exception
    ( Exception
    , bracket_
    , bracket
    , try
    , SomeException(..)
    , throwIO)
import Control.Monad (when, forever)
import Data.IORef
import Data.Typeable
import Data.Foldable
import Foreign.C.Types (CInt(..))
import System.IO.Unsafe

-- | Initializes mero.
m0_init :: IO ()
m0_init = do
    rc <- m0_init_wrapper
    when (rc /= 0) $
      fail $ "m0_init: failed with " ++ show rc

-- | Encloses an action with calls to 'm0_init' and 'm0_fini'.
-- Run m0 worker in parrallel, it's possible to send tasks to worker
-- using 'sendM0Task' primitive.
--
-- This method should be called from the bound thread.
withM0 :: IO a -> IO a
withM0 = bracket_ m0_init m0_fini . bracket runworker stopworker . const
  where
    runworker = forkM0OS $ do
      replaceGlobalWorker =<< myThreadId
      let loop = do
           mt <- readChan globalM0Chan
           forM_ mt $ \(Task f b) -> f >>= putMVar b >> loop
      loop
    stopworker mid = do
      writeChan globalM0Chan Nothing
      joinM0OS mid

-- | Exception means that 'withM0' or was not called, so
-- there is no worker that could start mero or process query.
data M0WorkerIsNotStarted = M0WorkerIsNotStarted deriving (Show, Typeable)

instance Exception M0WorkerIsNotStarted

globalM0Chan :: Chan (Maybe Task)
{-# NOINLINE globalM0Chan #-}
globalM0Chan = unsafePerformIO newChan

globalM0Worker :: IORef ThreadId
{-# NOINLINE globalM0Worker #-}
globalM0Worker = unsafePerformIO $ do
  tid <- forkIO $ forever $ do
           mt <- readChan globalM0Chan
           forM_ mt $ \(Task _ b) ->
             putMVar b (Left (SomeException M0WorkerIsNotStarted))
  newIORef tid

replaceGlobalWorker :: ThreadId -> IO ()
replaceGlobalWorker tid = do
  wid <- readIORef globalM0Worker
  killThread wid
  writeIORef globalM0Worker tid



data Task = forall a . Task (IO (Either SomeException a)) (MVar (Either SomeException a))

-- | Send task to M0 worker, may throw an exception if mero worker
-- failed to initialize mero. This call blocks until the task is
-- completed.
sendM0Task :: IO a -> IO a
sendM0Task f = do
    box <- newEmptyMVar
    writeChan globalM0Chan . Just $ Task (try f) box
    either throwIO return =<< takeMVar box

-- | Sends task to M0 worker, do not wait for task completion, this call is
-- completelly asynchronous.
sendM0Task_ :: IO () -> IO ()
sendM0Task_ f = do
  box <- newEmptyMVar
  writeChan globalM0Chan . Just $ Task (try f) box

foreign import ccall m0_init_wrapper :: IO CInt

-- | Finalizes mero.
foreign import ccall m0_fini_wrapper :: IO ()

m0_fini :: IO ()
m0_fini = finalizeM0 >> m0_fini_wrapper
