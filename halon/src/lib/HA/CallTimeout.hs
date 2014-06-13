-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- All @*call*Timeout@ functions guarantee:
-- - The function executes synchronously.
-- - The function waits at least @timeout@ microseconds for a reply, but there
--   is no guarantee the function will return promptly after the timeout
--   expires.
-- - The function spawns a constant, minimal number of processes.
-- - The function does not cause any messages to be sent to the caller
--   process.

{-# LANGUAGE OverlappingInstances #-}

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
import Control.Distributed.Process
import Control.Distributed.Process.Serializable (Serializable)
import Control.Exception (throwIO, SomeException)
import Control.Monad (forM_, void)

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- | Run a process locally and wait for a return value.
-- Local version of 'call'. Running a process in this way isolates it from
-- messages sent to the caller process, and also allows silently dropping late
-- or duplicate messages sent to the isolated process after it exits. Note that
-- silently dropping messages may not always be the best approach.
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

-- | Spawn a temporary @receiver@ and send @(receiver, msg)@ to @pid@, expecting
-- a reply to be sent to @receiver@.
-- Returns @Just reply@, or @Nothing@ if no reply arrives within at least
-- @timeout@.
-- Late or duplicate replies are silently dropped.
callTimeout :: (Serializable a, Serializable b) =>
     Int                -- ^ Timeout, in microseconds
  -> ProcessId          -- ^ Target process
  -> a                  -- ^ Message to send
  -> Process (Maybe b)  -- ^ Reply received, if any
callTimeout timeout pid msg =
    callLocal $ do
      receiver <- getSelfPid
      send pid (receiver, msg)
      expectTimeout timeout

-- | Spawn a temporary @receiver@ and send @(receiver, msg)@ to one or more
-- @pids@, expecting a reply to be sent to @receiver@.
-- Returns @Just reply@, or @Nothing@ if no reply arrives within at least
-- @timeout@.
-- Messages are sent all at the same time. Late or duplicate replies are
-- silently dropped.
callAnyTimeout :: (Serializable a, Serializable b) =>
     Int                -- ^ Timeout, in microseconds
  -> [ProcessId]        -- ^ Target processes
  -> a                  -- ^ Message to send
  -> Process (Maybe b)  -- ^ Reply received, if any
callAnyTimeout timeout pids msg =
    callLocal $ do
      receiver <- getSelfPid
      forM_ pids $ \pid -> send pid (receiver, msg)
      expectTimeout timeout

-- | Spawn a temporary @receiver@ and send @(receiver, msg)@ to one or more
-- @pids@, expecting a reply to be sent to @receiver@.
-- Returns @Just reply@, or @Nothing@ if no reply arrives within at least
-- @timeout@.
-- Messages are sent one at a time, using a temporary @_sender@ process to send
-- at most one message within at least each @softTimeout@, preserving the order
-- of @pids@. Late or duplicate replies are silently dropped.
callAnyStaggerTimeout :: (Serializable a, Serializable b) =>
     Int                -- ^ Soft timeout, in microseconds
  -> Int                -- ^ Timeout, in microseconds
  -> [ProcessId]        -- ^ Target processes
  -> a                  -- ^ Message to send
  -> Process (Maybe b)  -- ^ Reply received, if any
callAnyStaggerTimeout softTimeout timeout pids msg =
    callLocal $ do
      receiver <- getSelfPid
      _sender <- spawnLocal $ do
        link receiver
        forM_ pids $ \pid -> do
          send pid (receiver, msg)
          void (receiveTimeout softTimeout [])
      expectTimeout timeout

-- | Spawn a temporary @receiver@ and send @(receiver, msg)@ to one or more
-- @preferPids@ and @pids@, expecting a reply to be sent to @receiver@.
-- Returns @Just reply@, or @Nothing@ if no reply arrives within at least
-- @timeout@.
-- Two-stage version of 'callAnyTimeout'. Messages are first sent to all
-- @preferPids@ at the same time, then, if no reply arrives within at least
-- @softTimeout@, to all @pids@ at the same time. Late or duplicate replies are
-- silently dropped.
callAnyPreferTimeout :: (Serializable a, Serializable b) =>
     Int                -- ^ Soft timeout, in microseconds
  -> Int                -- ^ Timeout, in microseconds
  -> [ProcessId]        -- ^ Preferred target processes
  -> [ProcessId]        -- ^ Target processes
  -> a                  -- ^ Message to send
  -> Process (Maybe b)  -- ^ Reply received, if any
callAnyPreferTimeout softTimeout timeout preferPids pids msg =
    callLocal $ do
      receiver <- getSelfPid
      _sender <- spawnLocal $ do
        link receiver
        forM_ preferPids $ \pid -> send pid (receiver, msg)
        void (receiveTimeout softTimeout [])
        forM_ pids $ \pid -> send pid (receiver, msg)
      expectTimeout timeout

--------------------------------------------------------------------------------
-- Calling named processes
--------------------------------------------------------------------------------

-- | Spawn a temporary @receiver@ and send @(receiver, msg)@ to the named
-- process @label@ on @node@, expecting a reply to be sent to @receiver@.
-- Returns @Just reply@, or @Nothing@ if no reply arrives within at least
-- @timeout@.
-- Named process version of 'callTimeout'. Late or duplicate replies are
-- silently dropped.
ncallRemoteTimeout :: (Serializable a, Serializable b) =>
     Int                -- ^ Timeout, in microseconds
  -> NodeId             -- ^ Target node
  -> String             -- ^ Target process label
  -> a                  -- ^ Message to send
  -> Process (Maybe b)  -- ^ Reply received, if any
ncallRemoteTimeout timeout node label msg =
    callLocal $ do
      receiver <- getSelfPid
      nsendRemote node label (receiver, msg)
      expectTimeout timeout

-- | Spawn a temporary @receiver@ and send @(receiver, msg)@ to one or more
-- named processes @label@ on @nodes@, expecting a reply to be sent to
-- @receiver@.
-- Returns @Just reply@, @Nothing@ if no reply arrives within at least
-- @timeout@.
-- Named process version of 'callAnyTimeout'. Messages are sent all at the same
-- time. Late or duplicate replies are silently dropped.
ncallRemoteAnyTimeout :: (Serializable a, Serializable b) =>
     Int                -- ^ Timeout, in microseconds
  -> [NodeId]           -- ^ Target nodes
  -> String             -- ^ Target process label
  -> a                  -- ^ Message to send
  -> Process (Maybe b)  -- ^ Reply received, if any
ncallRemoteAnyTimeout timeout nodes label msg =
    callLocal $ do
      receiver <- getSelfPid
      forM_ nodes $ \node -> nsendRemote node label (receiver, msg)
      expectTimeout timeout

-- | Spawn a temporary @receiver@ process and send @(receiver, msg)@ to one or
-- more named processes @label@ on @nodes@, expecting a reply to be sent to
-- @receiver@.
-- Returns @Just reply@, or @Nothing@ if no reply arrives within at least
-- @timeout@.
-- Named process version of 'callAnyStaggerTimeout'. Messages are sent one at a
-- time, using a temporary @_sender@ process to send at most one message within
-- at least each @softTimeout@, preserving the order of @nodes@. Late or
-- duplicate replies are silently dropped.
ncallRemoteAnyStaggerTimeout :: (Serializable a, Serializable b) =>
     Int                -- ^ Soft timeout, in microseconds
  -> Int                -- ^ Timeout, in microseconds
  -> [NodeId]           -- ^ Target nodes
  -> String             -- ^ Target process label
  -> a                  -- ^ Message to send
  -> Process (Maybe b)  -- ^ Reply received, if any
ncallRemoteAnyStaggerTimeout softTimeout timeout nodes label msg =
    callLocal $ do
      receiver <- getSelfPid
      _sender <- spawnLocal $ do
        link receiver
        forM_ nodes $ \node -> do
          nsendRemote node label (receiver, msg)
          void (receiveTimeout softTimeout [])
      expectTimeout timeout

-- | Spawn a temporary @receiver@ process and send @(receiver, msg)@ to one or
-- more named processes @label@ on @preferNodes@ and @nodes@, expecting a
-- reply to be sent to @receiver@.
-- Returns @Just reply@, or @Nothing@ if no reply arrives within at least
-- @timeout@.
-- Two-stage version of 'ncallRemoteAnyTimeout', and named process version of
-- 'callAnyPreferTimeout'. Messages are first sent to all @preferNodes@ at the
-- same time, then, if no reply arrives within at least @softTimeout@, to all
-- @nodes@ at the same time. Late or duplicate replies are silently dropped.
ncallRemoteAnyPreferTimeout :: (Serializable a, Serializable b) =>
     Int                -- ^ Soft timeout, in microseconds
  -> Int                -- ^ Timeout, in microseconds
  -> [NodeId]           -- ^ Preferred target nodes
  -> [NodeId]           -- ^ Target nodes
  -> String             -- ^ Target process label
  -> a                  -- ^ Message to send
  -> Process (Maybe b)  -- ^ Reply received, if any
ncallRemoteAnyPreferTimeout softTimeout timeout preferNodes nodes label msg =
    callLocal $ do
      receiver <- getSelfPid
      _sender <- spawnLocal $ do
        link receiver
        forM_ preferNodes $ \node -> nsendRemote node label (receiver, msg)
        void (receiveTimeout softTimeout [])
        forM_ nodes $ \node -> nsendRemote node label (receiver, msg)
      expectTimeout timeout
