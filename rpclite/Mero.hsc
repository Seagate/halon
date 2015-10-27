-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Initialization and finalization calls of mero.
--
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE ForeignFunctionInterface   #-}
{-# LANGUAGE DeriveDataTypeable #-}
module Mero
  ( m0_init
  , m0_fini
  , withM0
  , withM0Deferred
  , sendM0Task
  , M0InitException(..)
  ) where

import Mero.Concurrent

import Control.Concurrent
    ( forkOS
    , Chan
    , newChan
    , readChan
    , writeChan
    , MVar
    , newEmptyMVar
    , putMVar
    , takeMVar
    , killThread)
import Control.Exception
    ( Exception
    , bracket_
    , bracket
    , finally
    , try
    , SomeException(..)
    , throwIO)
import Control.Monad (when, join, forever)
import Data.Typeable
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
withM0 :: IO a -> IO a
withM0 = bracket_ m0_init m0_fini . bracket runworker stopworker . const
  where
    runworker = forkM0OS $ forever $ do
      Task f b <- readChan globalM0Chan
      putMVar b =<< try f
    stopworker mid = do
      killThread $ m0ThreadId mid
      joinM0OS mid

newtype M0InitException = M0InitException CInt deriving (Show, Typeable)

instance Exception M0InitException

globalM0Chan :: Chan Task
{-# NOINLINE globalM0Chan #-}
globalM0Chan = unsafePerformIO newChan

data Task = forall a . Task (IO a) (MVar (Either SomeException a))

-- | Send task to M0 worker, may throw 'M0InitException' if mero worker
-- failed to initialize mero.
sendM0Task :: IO a -> IO a
sendM0Task f = do
    box <- newEmptyMVar
    writeChan globalM0Chan (Task f box)
    either throwIO return =<< takeMVar box

-- | Sends task to M0 worker, do not wait for task completion.
sendM0Task_ :: IO () -> IO ()
sendM0Task_ f = do
  box <- newEmptyMVar
  writeChan globalM0Chan (Task f box)

-- | Spawns a deferred worker thread in parrallel to main. New deferred
-- thread will be initialized as m0 thread only when first task will
-- arrive.
withM0Deferred :: IO a -> IO a
withM0Deferred = bracket init killThread . const
  where
    init = forkOS $ do
        let initloop = do
              t@(Task cmd b) <- readChan globalM0Chan
              rc <- m0_init_wrapper
              if (rc == 0)
                 then mainloop t `finally` m0_fini
                 else do putMVar b (Left (SomeException (M0InitException rc)))
                         initloop
            mainloop (Task cmd b) =
              try cmd >>= putMVar b >> readChan globalM0Chan >>= mainloop
        initloop

foreign import ccall m0_init_wrapper :: IO CInt

-- | Finalizes mero.
foreign import ccall m0_fini :: IO ()
