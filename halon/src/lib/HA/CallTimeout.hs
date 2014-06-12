{-|
Copyright : (C) 2014 Xyratex Technology Limited.
License   : All rights reserved.

All @call*Timeout@ functions guarantee:
- The function executes synchronously, taking at most @timeout@ microseconds
  to return.
- The function spawns a minimal constant number of processes.
- The function does not cause any messages to be sent to the caller process.
-}

{-# LANGUAGE OverlappingInstances #-}

module HA.CallTimeout where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Distributed.Process
import Control.Distributed.Process.Serializable (Serializable)
import Control.Exception (throwIO, SomeException)
import Control.Monad (forM_, forever)




-- | @Timeout@ is an amount of microseconds.
type Timeout = Int


-- | @Label@ is a human-readable indentifier, unique per node.
type Label = String




{-| @runLocal@ runs a short-life locally-spawned process and returns its
result.
Used to avoid causing messages to be sent to a long-life process.
-}
runLocal :: Process a -> Process a
runLocal proc = do
    mv <- liftIO newEmptyMVar
    self <- getSelfPid
    _runner <- spawnLocal $ do
      link self
      try proc >>= liftIO . putMVar mv
    liftIO $ takeMVar mv >>=
      either (throwIO :: SomeException -> IO a) return




{-| @callTimeout@ sends @(receiver, msg)@ to @pid@, expecting a reply to be
sent to @receiver@.
Returns @Just reply@, or @Nothing@ if no reply arrives within @timeout@.
-}
callTimeout :: (Serializable a, Serializable b) =>
  ProcessId -> a -> Timeout -> Process (Maybe b)
callTimeout pid msg timeout =
    runLocal $ do
      receiver <- getSelfPid
      send pid (receiver, msg)
      expectTimeout timeout


{-| @parallelCallTimeout@ sends @(receiver, msg)@ to all @pids@, expecting
a reply to be sent to @receiver@.
All messages are sent at the same time.
Returns @Just reply@, or @Nothing@ if no reply arrives within @timeout@.
Late replies are ignored.
-}
parallelCallTimeout :: (Serializable a, Serializable b) =>
  [ProcessId] -> a -> Timeout -> Process (Maybe b)
parallelCallTimeout pids msg timeout =
    runLocal $ do
      receiver <- getSelfPid
      forM_ pids $ \pid -> send pid (receiver, msg)
      expectTimeout timeout


{-| @serialCallTimeout@ sends @(receiver, msg)@ to all @pids@, expecting
a reply to be sent to @receiver@.
The messages are sent one at a time, continuing if no reply arrives within
@softTimeout@.
The messages are sent preserving the order of @pids@.
Returns @Just reply@, or @Nothing@ if no reply arrives within @timeout@.
Late replies are ignored.
-}
serialCallTimeout :: (Serializable a, Serializable b) =>
  [ProcessId] -> a -> Timeout -> Timeout -> Process (Maybe b)
serialCallTimeout pids msg softTimeout timeout =
    runLocal $ do
      receiver <- getSelfPid
      _sender <- spawnLocal $ do
        link receiver
        forM_ pids $ \pid -> do
          send pid (receiver, msg)
          _ <- receiveTimeout softTimeout []
          return ()
      expectTimeout timeout


{-| @mixedCallTimeout@ sends @(receiver, msg)@ to all @pids@, expecting
a reply to be sent to @receiver@.
The message is first sent to the first process, continuing if no reply
arrives within @softTimeout@, then to all remaining processes at the same
time.
Returns @Just reply@, or @Nothing@ if no reply arrives within @timeout@.
-}
mixedCallTimeout :: (Serializable a, Serializable b) =>
  [ProcessId] -> a -> Timeout -> Timeout -> Process (Maybe b)
mixedCallTimeout [] _ _ _ = return Nothing
mixedCallTimeout (pid1 : pids) msg softTimeout timeout =
    runLocal $ do
      receiver <- getSelfPid
      _sender <- spawnLocal $ do
        link receiver
        send pid1 (receiver, msg)
        _ <- receiveTimeout softTimeout []
        forM_ pids $ \pid ->
          send pid (receiver, msg)
      expectTimeout timeout




{-| @callNodeTimeout@ sends @(receiver, msg)@ to the process registered on
@node@ under @label@, expecting a reply to be sent to @receiver@.
The message is sent as soon as @node@ provides the @pid@ of the process.
Returns @Just reply@, or @Nothing@ if no reply arrives within @timeout@.
-}
callNodeTimeout :: (Serializable a, Serializable b) =>
  NodeId -> Label -> a -> Timeout -> Process (Maybe b)
callNodeTimeout node label msg timeout =
    runLocal $ do
      receiver <- getSelfPid
      _sender <- spawnLocal $ do
        link receiver
        whereisRemoteAsync node label
        receiveWait [
          match $
            \(WhereIsReply _ mpid) ->
              case mpid of
                Just pid -> send pid (receiver, msg)
                _ -> return ()]
      expectTimeout timeout


{-| @parallelCallNodesTimeout@ sends @(receiver, msg)@ to each process
registered under @label@ on all @nodes@, expecting a reply to be sent to
@receiver@.
Each message is sent as soon as @node@ provides the @pid@ of each process.
Returns @Just reply@, @Nothing@ if no reply arrives within @timeout@.
-}
parallelCallNodesTimeout :: (Serializable a, Serializable b) =>
  [NodeId] -> Label -> a -> Timeout -> Process (Maybe b)
parallelCallNodesTimeout nodes label msg timeout =
    runLocal $ do
      receiver <- getSelfPid
      _sender <- spawnLocal $ do
        link receiver
        forM_ nodes $ \node ->
          whereisRemoteAsync node label
        forever $
          receiveWait [
            match $
              \(WhereIsReply _ mpid) ->
                case mpid of
                  Just pid -> send pid (receiver, msg)
                  _ -> return ()]
      expectTimeout timeout


{-| @serialCallNodesTimeout@ sends @(receiver, msg)@ to each process
registered under @label@ on all @nodes@, expecting a reply to be sent to
@receiver@.
The messages are sent one at a time, as soon as @node@ provides the @pid@
of each process, continuing with the next process if no reply arrives within
@softTimeout@.
The messages are sent preserving the order of @nodes@.
Returns @Just reply@, or @Nothing@ if no reply arrives within @timeout@.
-}
serialCallNodesTimeout :: (Serializable a, Serializable b) =>
  [NodeId] -> Label -> a -> Timeout -> Timeout -> Process (Maybe b)
serialCallNodesTimeout nodes label msg softTimeout timeout =
    runLocal $ do
      receiver <- getSelfPid
      _sender <- spawnLocal $ do
        link receiver
        forM_ nodes $ \node ->
          whereisRemoteAsync node label
        forever $
          receiveWait [ -- FIXME: This does not preserve @nodes@ order yet.
            match $
              \(WhereIsReply _ mpid) ->
                case mpid of
                  Just pid -> do
                    send pid (receiver, msg)
                    _ <- receiveTimeout softTimeout []
                    return ()
                  _ -> return ()]
      expectTimeout timeout


-- | @mixedCallNodesTimeout nodes0 nodes1 label msg softTimeout timeout@
-- sends @(receiver, msg)@ to each process registered under @label@ on all
-- of @nodes0@ and @nodes1@, expecting a reply to be sent to @receiver@.
--
-- @receiver@ is a temporary process spawned solely for the purpose of
-- this call.
--
-- The message is first sent to each process in @nodes0@, as soon as
-- the @pid@ of the process is obtained, continuing if no reply arrives
-- within @softTimeout@, then to all remaining processes as soon as
-- their @pid@s are known.
--
-- Returns @Just reply@, or @Nothing@ if no reply arrives within
-- @timeout@.
--
mixedCallNodesTimeout :: (Serializable a, Serializable b) =>
  [NodeId] -> [NodeId] -> Label -> a -> Timeout -> Timeout -> Process (Maybe b)
mixedCallNodesTimeout [] [] _ _ _ _ = return Nothing
mixedCallNodesTimeout nodes0 nodes1 label msg softTimeout timeout =
    runLocal $ do
      receiver <- getSelfPid
      -- run the first round that will contact nodes0
      _ <- spawnLocal $ do
        link receiver
        forM_ nodes0 $ \node -> whereisRemoteAsync node label
        forever $
          receiveWait [ matchIf
            (\(WhereIsReply _ mpid) ->
              maybe False (\pid -> elem (processNodeId pid) nodes0) mpid)
            (\(WhereIsReply _ mpid) ->
              maybe (return ()) (\pid -> send pid (receiver, msg)) mpid)
          ]
      _ <- spawnLocal $ do
        link receiver
        -- spawn the second round that will contact nodes1
        _ <- receiveTimeout softTimeout []
        forM_ nodes1 $ \node -> whereisRemoteAsync node label
        forever $
          receiveWait [
            match $ \(WhereIsReply _ mpid) ->
              case mpid of
                Just pid -> send pid (receiver, msg)
                _ -> return ()]
      expectTimeout timeout
