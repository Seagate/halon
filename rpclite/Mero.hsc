-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Initialization and finalization calls of mero.
--
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE ForeignFunctionInterface  #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE LambdaCase                #-}
module Mero
  ( m0_init
  , m0_fini
  , withM0
  , withM0Deferred
  , sendM0Task
  , sendM0Task_
  , M0InitException(..)
  , setNodeUUID
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
    , takeMVar)
import Control.Exception
    ( Exception
    , bracket_
    , bracket
    , finally
    , try
    , SomeException(..)
    , throwIO)
import Control.Monad (when)
import Data.IORef
import Data.Typeable
import Data.Foldable
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt(..))
import Foreign.Ptr (nullPtr)
import System.IO.Unsafe

-- | Initializes mero.
m0_init :: IO ()
m0_init = do
    setNodeUUID Nothing
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
    runworker = forkM0OS $
      let loop = do
           mt <- readChan globalM0Chan
           forM_ mt $ \(Task f b) -> f >>= putMVar b >> loop
      in loop
    stopworker mid = do
      writeChan globalM0Chan Nothing
      joinM0OS mid

newtype M0InitException = M0InitException CInt deriving (Show, Typeable)

instance Exception M0InitException

globalM0Chan :: Chan (Maybe Task)
{-# NOINLINE globalM0Chan #-}
globalM0Chan = unsafePerformIO newChan

data Task = forall a . Task (IO (Either SomeException a)) (MVar (Either SomeException a))

-- | Send task to M0 worker, may throw 'M0InitException' if mero worker
-- failed to initialize mero.
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

-- | Spawns a deferred worker thread in parrallel to main. New deferred
-- thread will be initialized as m0 thread only when first task will
-- arrive.
withM0Deferred :: IO a -> IO a
withM0Deferred f = do
    cont <- newIORef True
    end  <- newEmptyMVar
    bracket_ (initialize cont end)
             (finalize cont end)
             f
  where
    initialize cont end = forkOS $ do
        let initloop = do
              shouldContinue <- readIORef cont
              when shouldContinue $ do
                mt <- readChan globalM0Chan
                forM_ mt $ \t@(Task _ b) -> do
                  setNodeUUID Nothing
                  rc <- m0_init_wrapper
                  if (rc == 0)
                    then mainloop t `finally` m0_fini
                    else do putMVar b (Left (SomeException (M0InitException rc)))
                            initloop
            mainloop (Task cmd b) = do
                cmd >>= putMVar b
                readChan globalM0Chan >>= traverse_ mainloop
        initloop
        putMVar end ()
    finalize cont end = do
        writeIORef cont False
        writeChan globalM0Chan Nothing
        takeMVar end

foreign import ccall m0_init_wrapper :: IO CInt

-- | Finalizes mero.
foreign import ccall m0_fini :: IO ()

foreign import ccall "<lib/uuid.h> m0_node_uuid_string_set"
  c_node_uuid_string_set  :: CString -> IO ()

-- | Unset node uuid, so library will be able to work without connection to mero instance.
setNodeUUID :: Maybe String -> IO ()
setNodeUUID Nothing = c_node_uuid_string_set nullPtr
setNodeUUID (Just s) = withCString s c_node_uuid_string_set
