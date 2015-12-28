-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Concurrency primitives of Mero.
--
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE EmptyDataDecls           #-}
{-# LANGUAGE LambdaCase               #-}
module Mero.Concurrent
  ( forkM0OS
  , joinM0OS
  , m0ThreadId
  , M0Thread
  , finalizeM0
  , addM0Finalizer
  ) where

import Control.Concurrent      (myThreadId, ThreadId, rtsSupportsBoundThreads, killThread)
import Control.Concurrent.MVar
import Control.Monad           (when)
import Foreign.C.Types         (CInt(..))
import Foreign.Marshal.Alloc   (mallocBytes)
import Foreign.Ptr             (FunPtr, Ptr)
import Data.Foldable           (forM_)
import System.IO.Unsafe        (unsafePerformIO)
import Data.IORef              (IORef, newIORef, modifyIORef, atomicModifyIORef)

import System.IO
#include "lib/thread.h"


-- | m0_threads
data M0Thread = M0Thread
   { _m0ThreadId :: ThreadId
   , _m0ThreadPtr :: Ptr M0Thread
   , _m0ThreadJoined :: MVar Bool
   }

instance Show M0Thread where
  show (M0Thread a b c) = "M0Thread "++show a++" "++show b++" <lock>"

globalFinalizers :: IORef [(Maybe ThreadId, IO ())]
globalFinalizers = unsafePerformIO $ newIORef []
{-# NOINLINE globalFinalizers #-}

-- | Creates a bound m0_thread.
--
--  The thread is a resource to be disposed with 'joinM0OS'.
--
-- This call can happen only in an m0_thread. The thread calling 'Mero.m0_init'
-- becomes an m0_thread.
forkM0OS :: IO () -> IO M0Thread
forkM0OS action | rtsSupportsBoundThreads = do
    mv <- newEmptyMVar
    w <- cwrapAction $ myThreadId >>= putMVar mv >> action
    ptr <- mallocBytes #{size struct m0_thread}
    rc <- forkM0OS_createThread ptr w
    when (rc /= 0) $
      fail "forkM0OS: Cannot create m0_thread."
    tid <- takeMVar mv
    vv  <- newMVar False
    let mt = M0Thread tid ptr vv
    modifyIORef globalFinalizers ((Just tid, killThread tid >> joinM0OS mt):)
    return mt
forkM0OS _ = fail $ "forkM0OS: RTS doesn't support multiple OS threads "
                    ++"(use ghc -threaded when linking)"

-- | Waits for an m0_thread to finish and then releases it.
--
-- This call can happen only in an m0_thread.
joinM0OS :: M0Thread -> IO ()
joinM0OS m0t = do
    modifyMVar_ (_m0ThreadJoined m0t) $ \case
      True -> return True
      False -> do
        rc <- forkM0OS_joinThread (_m0ThreadPtr m0t)
        when (rc /= 0) $
          fail $ "joinM0OS: Cannot join m0_thread " ++ show m0t ++ ": " ++ show rc
        modifyIORef globalFinalizers $ filter (( /= (Just $ _m0ThreadId m0t)) . fst)
        return True

-- | Yields the 'ThreadId' associated with an m0_thread.
m0ThreadId :: M0Thread -> ThreadId
m0ThreadId = _m0ThreadId

foreign import ccall forkM0OS_createThread ::
    Ptr M0Thread -> FunPtr (IO ()) -> IO CInt

foreign import ccall "wrapper" cwrapAction :: IO () -> IO (FunPtr (IO ()))

foreign import ccall forkM0OS_joinThread :: Ptr M0Thread -> IO CInt

finalizeM0 :: IO ()
finalizeM0 = do
  list <- atomicModifyIORef globalFinalizers (\x -> ([], x))
  forM_ list $ \(_, a) -> a

-- | Adds an action that will be called just before 'Mero.m0_fini' is called.
-- Adding finalizers after calling to m0_fini may lead to a mero failure,
-- user encouraged to use this call only from m0 thread.
addM0Finalizer :: IO () -> IO ()
addM0Finalizer f = atomicModifyIORef globalFinalizers (\x -> ((Nothing, f):x, ()))
