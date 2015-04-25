-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Concurrency primitives of Mero.
--
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE EmptyDataDecls           #-}
module Mero.Concurrent (forkM0OS, joinM0OS, m0ThreadId, M0Thread) where

import Control.Concurrent      (myThreadId, ThreadId, rtsSupportsBoundThreads)
import Control.Concurrent.MVar
import Control.Monad           (when)
import Foreign.C.Types         (CInt(..))
import Foreign.Marshal.Alloc   (mallocBytes)
import Foreign.Ptr             (FunPtr, Ptr)

#include "lib/thread.h"


-- | m0_threads
data M0Thread = M0Thread
   { _m0ThreadId :: ThreadId
   , _m0ThreadPtr :: Ptr M0Thread
   } deriving Show

-- | Creates a bound m0_thread.
--
--  The thread is a resource to be disposed with 'joinM0OS'.
--
-- None of these calls can be performed without calling 'Mero.m0_init' first.
forkM0OS :: IO () -> IO M0Thread
forkM0OS action | rtsSupportsBoundThreads = do
    mv <- newEmptyMVar
    w <- cwrapAction $ myThreadId >>= putMVar mv >> action
    ptr <- mallocBytes #{size struct m0_thread}
    rc <- forkM0OS_createThread ptr w
    when (rc /= 0) $
      fail "forkM0OS: Cannot create m0_thread."
    tid <- takeMVar mv
    return $ M0Thread tid ptr
forkM0OS _ = fail $ "forkM0OS: RTS doesn't support multiple OS threads "
                    ++"(use ghc -threaded when linking)"

-- | Waits for an m0_thread to finish and then releases it.
joinM0OS :: M0Thread -> IO ()
joinM0OS m0t = do
    rc <- forkM0OS_joinThread (_m0ThreadPtr m0t)
    when (rc /= 0) $
      fail $ "joinM0OS: Cannot join m0_thread " ++ show m0t ++ ": " ++ show rc

-- | Yields the 'ThreadId' associated with an m0_thread.
m0ThreadId :: M0Thread -> ThreadId
m0ThreadId = _m0ThreadId

foreign import ccall forkM0OS_createThread ::
    Ptr M0Thread -> FunPtr (IO ()) -> IO CInt

foreign import ccall "wrapper" cwrapAction :: IO () -> IO (FunPtr (IO ()))

foreign import ccall forkM0OS_joinThread :: Ptr M0Thread -> IO CInt
