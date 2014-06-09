-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- A simple interface for remote calls which imitates the interface
-- of "Control.Distributed.Process.Platform.Call".
--
-- The module provides a client-side interface to send requests,
-- and a server-side interface to produce responses.
--
module HA.Call
      ( -- * Client-side interface
        Timeout
      , callTimeout
      , callAt
        -- * Server-side interface
      , callResponse
      , callResponseWithCaller
      , callResponseAsync
      -- * Auxiliary helpers
      , callLocal
      ) where

import Control.Distributed.Process
import Control.Distributed.Process.Serializable (Serializable)

import Control.Concurrent.MVar
import Control.Exception (throwIO, SomeException)
import Data.Binary
import Data.Maybe
import Data.Typeable
import GHC.Generics (Generic)

-- XXX pending inclusion upstream.
callLocal :: Process a -> Process a
callLocal p = do
  mv <-liftIO $ newEmptyMVar
  self <- getSelfPid
  _ <- spawnLocal $ link self >> try p >>= liftIO . putMVar mv
  liftIO $ takeMVar mv
    >>= either (throwIO :: SomeException -> IO a) return

-- | A timeout is an amount of microseconds (@Just us@) or infinity (@Nothing@).
type Timeout = Maybe Int

-- | An internal structure for RPC request.
data RPCRequest a = RPCRequest { _rqCaller :: ProcessId
                               , rqPayload :: a
                               }
  deriving (Typeable, Generic)

instance Binary a => Binary (RPCRequest a)

-- | @callTimeout pid a t@ sends @a@ to process @pid@ and waits for an answer.
-- If the response does not arrive within the given timeout, it returns Nothing.
callTimeout :: (Serializable a, Serializable b)
            => ProcessId -> a -> Timeout -> Process (Maybe b)
callTimeout pid a timeOut =
    -- callLocal creates a temporary mailbox so late responses don't leak or
    -- interfere with other calls.
    callLocal $ do
      self <- getSelfPid
      send pid $ RPCRequest self a
      maybe (fmap Just expect) expectTimeout timeOut

-- | Like @callTimeout@ but blocks forever if the response does not arrive.
callAt :: (Serializable a, Serializable b) => ProcessId -> a -> Process (Maybe b)
callAt pid a = callTimeout pid a Nothing

-- | @callResponse f@ matches an RPC request and sends as response the
-- result of applying function @f@ to it.
callResponse :: (Serializable a, Serializable b)
              => (a -> Process (b, c)) -> Match c
callResponse = callResponseWithCaller . const

-- | Like @callResponse@ but also passes the process identifier of the caller.
callResponseWithCaller :: (Serializable a, Serializable b)
             => (ProcessId -> a -> Process (b, c)) -> Match c
callResponseWithCaller f =
    match $ \(RPCRequest caller a) -> do
              (b, c) <- f caller a
              send caller b
              return c

-- | @callResponseAsync p f@ matches an RPC request if @isJust p@.
-- It evaluates the result of applying @f@ to the request in a newly
-- spawned thread.
callResponseAsync :: (Serializable a,Serializable b)
                  => (a -> Maybe c) -> (a -> Process b) -> Match c
callResponseAsync p f =
   matchIf (isJust . p . rqPayload) $ \(RPCRequest s a) -> do
     _ <- spawnLocal $ f a >>= send s
     maybe (error "callResponseAsync: indecisive condition") return $ p a
