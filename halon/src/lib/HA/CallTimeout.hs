-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- All @*call*Timeout@ functions guarantee:
-- - The function executes synchronously.
-- - The function waits at least @timeout@ microseconds for a reply, but it may
--   not return promptly after the timeout expires.
-- - The function spawns at most one temporary process.
--
-- None of these functions guarantee multiple calls made by the same caller will
-- not interfere with each other. Additionally, using these functions may cause
-- late or duplicate messages to be sent to the caller and accumulate in its
-- mailbox. The caller must be prepared to handle these issues. One solution is
-- to wrap each use of these functions with 'callLocal'.
{-# LANGUAGE CPP #-}
#if __GLASGOW_HASKELL__ < 710
{-# LANGUAGE OverlappingInstances #-}
#endif

module HA.CallTimeout
  ( -- * Helpers
    callLocal

    -- * Calling processes
  , callTimeout
  , callAnyTimeout
  , callAnyStaggerTimeout
  , callAnyPreferTimeout

    -- * Calling named processes
  , ncallRemoteTimeout
  , ncallRemoteAnyTimeout
  , ncallRemoteAnyStaggerTimeout
  , ncallRemoteAnyPreferTimeout
  ) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Distributed.Process hiding (callLocal, send)
import Control.Distributed.Process.Serializable (Serializable)
import Control.Exception (throwIO, SomeException)
import Control.Monad (forM_, void)

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- | Run a process locally and wait for a return value.
-- Local version of 'call'. Running a process in this way isolates it from
-- messages sent to the caller process, and also allows silently dropping late
-- or duplicate messages sent to the isolated process after it exits.
-- Silently dropping messages may not always be the best approach.
callLocal ::
     Process a  -- ^ Process to run
  -> Process a  -- ^ Value returned
callLocal proc = do
    mv <- liftIO newEmptyMVar
    self <- getSelfPid
    _runner <- spawnLocal $ do
      link self
      try proc >>= liftIO . putMVar mv
    liftIO $ takeMVar mv >>=
      either (throwIO :: SomeException -> IO a) return

--------------------------------------------------------------------------------
-- Calling processes
--------------------------------------------------------------------------------

-- | Send @(self, msg)@ to @pid@ and wait for a reply.
-- Returns @Just reply@, or @Nothing@ if no reply arrives within at least
-- @timeout@.
callTimeout :: (Serializable a, Serializable b) =>
     Int                -- ^ Timeout, in microseconds
  -> ProcessId          -- ^ Target process
  -> a                  -- ^ Message to send
  -> Process (Maybe b)  -- ^ Reply received, if any
callTimeout timeout pid msg = do
    self <- getSelfPid
    usend pid (self, msg)
    expectTimeout timeout

-- | Send @(self, msg)@ to one or more @pids@ and wait for a reply.
-- Returns @Just reply@, or @Nothing@ if no reply arrives within at least
-- @timeout@.
-- Messages are sent all at the same time.
callAnyTimeout :: (Serializable a, Serializable b) =>
     Int                -- ^ Timeout, in microseconds
  -> [ProcessId]        -- ^ Target processes
  -> a                  -- ^ Message to send
  -> Process (Maybe b)  -- ^ Reply received, if any
callAnyTimeout timeout pids msg = do
    self <- getSelfPid
    forM_ pids $ \pid -> usend pid (self, msg)
    expectTimeout timeout

-- | Send @(self, msg)@ to one or more @pids@ and wait for a reply.
-- Returns @Just reply@, or @Nothing@ if no reply arrives within at least
-- @timeout@.
-- Messages are sent one at a time, preserving the order of @pids@, and using a
-- temporary process to send at most one message within at least each
-- @softTimeout@.
callAnyStaggerTimeout :: (Serializable a, Serializable b) =>
     Int                -- ^ Soft timeout, in microseconds
  -> Int                -- ^ Timeout, in microseconds
  -> [ProcessId]        -- ^ Target processes
  -> a                  -- ^ Message to send
  -> Process (Maybe b)  -- ^ Reply received, if any
callAnyStaggerTimeout softTimeout timeout pids msg = do
    self <- getSelfPid
    sender <- spawnLocal $ do
      link self
      forM_ pids $ \pid -> do
        usend pid (self, msg)
        void $ receiveTimeout softTimeout []
    result <- expectTimeout timeout
    kill sender "done"
    return result

-- | Send @(self, msg)@ to one or more @preferPids@ and @pids@ and wait for a
-- reply.
-- Returns @Just reply@, or @Nothing@ if no reply arrives within at least
-- @timeout@.
-- Two-stage version of 'callAnyTimeout'. Messages are first sent to all
-- @preferPids@ at the same time, then, if no reply arrives within at least
-- @softTimeout@, to all @pids@ at the same time.
callAnyPreferTimeout :: (Serializable a, Serializable b) =>
     Int                -- ^ Soft timeout, in microseconds
  -> Int                -- ^ Timeout, in microseconds
  -> [ProcessId]        -- ^ Preferred target processes
  -> [ProcessId]        -- ^ Target processes
  -> a                  -- ^ Message to send
  -> Process (Maybe b)  -- ^ Reply received, if any
callAnyPreferTimeout softTimeout timeout preferPids pids msg = do
    self <- getSelfPid
    sender <- spawnLocal $ do
      link self
      forM_ preferPids $ \pid -> usend pid (self, msg)
      void $ receiveTimeout softTimeout []
      forM_ pids $ \pid -> usend pid (self, msg)
    result <- expectTimeout timeout
    kill sender "done"
    return result

--------------------------------------------------------------------------------
-- Calling named processes
--------------------------------------------------------------------------------

-- | Send @(self, msg)@ to the named process @label@ on @node@ and wait for a
-- reply.
-- Returns @Just reply@, or @Nothing@ if no reply arrives within at least
-- @timeout@.
-- Named process version of 'callTimeout'.
ncallRemoteTimeout :: (Serializable a, Serializable b) =>
     Int                -- ^ Timeout, in microseconds
  -> NodeId             -- ^ Target node
  -> String             -- ^ Target process label
  -> a                  -- ^ Message to send
  -> Process (Maybe b)  -- ^ Reply received, if any
ncallRemoteTimeout timeout node label msg = do
    self <- getSelfPid
    nsendRemote node label (self, msg)
    expectTimeout timeout

-- | Send @(self, msg)@ to one or more named processes @label@ on @nodes@ and
-- wait for a reply.
-- Returns @Just reply@, @Nothing@ if no reply arrives within at least
-- @timeout@.
-- Named process version of 'callAnyTimeout'. Messages are sent all at the same
-- time.
ncallRemoteAnyTimeout :: (Serializable a, Serializable b) =>
     Int                -- ^ Timeout, in microseconds
  -> [NodeId]           -- ^ Target nodes
  -> String             -- ^ Target process label
  -> a                  -- ^ Message to send
  -> Process (Maybe b)  -- ^ Reply received, if any
ncallRemoteAnyTimeout timeout nodes label msg = do
    self <- getSelfPid
    forM_ nodes $ \node -> nsendRemote node label (self, msg)
    expectTimeout timeout

-- | Send @(self, msg)@ to one or more named processes @label@ on @nodes@ and
-- wait for a reply.
-- Returns @Just reply@, or @Nothing@ if no reply arrives within at least
-- @timeout@.
-- Named process version of 'callAnyStaggerTimeout'. Messages are sent one at a
-- time, preserving the order of @nodes@, using a temporary process to send at
-- most one message within at least each @softTimeout@.
ncallRemoteAnyStaggerTimeout :: (Serializable a, Serializable b) =>
     Int                -- ^ Soft timeout, in microseconds
  -> Int                -- ^ Timeout, in microseconds
  -> [NodeId]           -- ^ Target nodes
  -> String             -- ^ Target process label
  -> a                  -- ^ Message to send
  -> Process (Maybe b)  -- ^ Reply received, if any
ncallRemoteAnyStaggerTimeout softTimeout timeout nodes label msg = do
    self <- getSelfPid
    sender <- spawnLocal $ do
      link self
      forM_ nodes $ \node -> do
        nsendRemote node label (self, msg)
        void $ receiveTimeout softTimeout []
    result <- expectTimeout timeout
    kill sender "done"
    return result

-- | Send @(self, msg)@ to one or more named processes @label@ on @preferNodes@
-- and @nodes@ and wait for a reply.
-- Returns @Just reply@, or @Nothing@ if no reply arrives within at least
-- @timeout@.
-- Two-stage version of 'ncallRemoteAnyTimeout', and named process version of
-- 'callAnyPreferTimeout'. Messages are first sent to all @preferNodes@ at the
-- same time, then, if no reply arrives within at least @softTimeout@, to all
-- @nodes@ at the same time.
ncallRemoteAnyPreferTimeout :: (Serializable a, Serializable b) =>
     Int                -- ^ Soft timeout, in microseconds
  -> Int                -- ^ Timeout, in microseconds
  -> [NodeId]           -- ^ Preferred target nodes
  -> [NodeId]           -- ^ Target nodes
  -> String             -- ^ Target process label
  -> a                  -- ^ Message to send
  -> Process (Maybe b)  -- ^ Reply received, if any
ncallRemoteAnyPreferTimeout softTimeout timeout preferNodes nodes label msg = do
    self <- getSelfPid
    sender <- spawnLocal $ do
      link self
      forM_ preferNodes $ \node -> nsendRemote node label (self, msg)
      void $ receiveTimeout softTimeout []
      forM_ nodes $ \node -> nsendRemote node label (self, msg)
    result <- expectTimeout timeout
    kill sender "done"
    return result
