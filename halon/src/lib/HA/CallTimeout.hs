-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
--
{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
#if __GLASGOW_HASKELL__ < 710
{-# LANGUAGE OverlappingInstances #-}
#endif
{-# LANGUAGE MonoLocalBinds #-}

module HA.CallTimeout
  ( callTimeout
    -- * Calling named processes
  , ncallRemoteSome
  , ncallRemoteSomePrefer
  , withLabeledProcesses
  , receiveFrom
  ) where

import HA.Logger (mkHalonTracer)

import Control.Distributed.Process
import Control.Distributed.Process.Serializable (Serializable)

import Control.Distributed.Process.Timeout (timeout)

import Control.Monad (forM_)
import qualified Control.Monad.Catch as C
import Data.Function (fix)
import Data.IORef (newIORef, readIORef, modifyIORef)
import Data.List (delete, partition)


callTrace :: String -> Process ()
callTrace = mkHalonTracer "call"

--------------------------------------------------------------------------------
-- Calling processes
--------------------------------------------------------------------------------

-- | Send @(self, msg)@ to @pid@ and wait for a reply.
-- Returns @Just reply@, or @Nothing@ if no reply arrives within at least
-- @t@ microseconds. 'callTimeout' provides following guarantees:
--
--   * The function executes synchronously.
--   * The function waits at least @timeout@ microseconds for a reply, but it may
--     not return promptly after the timeout expires.
--   * The function spawns at most one temporary process.
--
-- This function does not guarantee that multiple calls that are made by the same
-- caller will not interfere with each other. Additionally, using this functions may
-- cause late or duplicate messages to be sent to the caller and accumulate in its
-- mailbox. The caller must be prepared to handle these issues. One solution is
-- to wrap each use of these functions with 'callLocal'.
callTimeout :: (Serializable a, Serializable b) =>
     Int                -- ^ Timeout, in microseconds
  -> ProcessId          -- ^ Target process
  -> a                  -- ^ Message to send
  -> Process (Maybe b)  -- ^ Reply received, if any
callTimeout t pid msg = do
    self <- getSelfPid
    usend pid (self, msg)
    expectTimeout t

--------------------------------------------------------------------------------
-- Calling named processes
--------------------------------------------------------------------------------

-- | Send @(self, msg)@ to one or more named processes @label@ on @nodes@ and
-- wait for a reply satisfying the given predicate.
--
-- Returns a reply satisfying the predicate at the head of the resulting
-- list if any, followed by other replies not satisfying the predicate.
--
-- Each reply must contain the NodeId of the replying node.
--
-- Messages are sent all at the same time.
--
ncallRemoteSome :: (Serializable a, Serializable b) =>
     Int                -- ^ Timeout in microseconds to find pids
  -> [NodeId]           -- ^ Target nodes
  -> String             -- ^ Target process label
  -> a                  -- ^ Message to send
  -> ((NodeId, b) -> Bool) -- ^ A predicate that indicates the desired answer in
                           -- case multiple answers are received.
  -> Process [(NodeId, b)]  -- ^ Replies received, if any
ncallRemoteSome t nodes label msg p = withLabeledProcesses t nodes label $ \case
    []   -> return []
    pids -> do
      self <- getSelfPid
      forM_ pids $ \pid -> usend pid (self, msg)
      receiveFrom p pids

-- | Looks up the processes with the given labels in the given nodes.
-- It calls the action with whatever processes where found within the given
-- timeout.
--
withLabeledProcesses ::
     Int                -- ^ Timeout in microseconds to find pids
  -> [NodeId]           -- ^ Target nodes
  -> String             -- ^ Target process label
  -> ([ProcessId] -> Process a) -- ^ Action to perform
  -> Process a
withLabeledProcesses t nodes label action = (action =<<) $ callLocal $
    C.bracket (mapM monitorNode nodes)
              (mapM_ unmonitor)        $ \_ -> do
    forM_ nodes $ \node -> whereisRemoteAsync node label
    r <- liftIO $ newIORef []
    _ <- timeout t (forM_ nodes $ const $ receiveWait
      [ match $ \(_ :: ProcessMonitorNotification) -> return ()
      , match $ \case
          WhereIsReply _ (Just pid) -> liftIO $ modifyIORef r (pid:)
          _                         -> return ()
      ])
    liftIO $ readIORef r

-- | Expects a message of type @(NodeId, b)@ from the given list of pids,
-- one pid is expected per node.
--
-- If a message satisfying the given predicate is received, then
-- @(nid, b)@ is returned at the head of the resulting list, where @nid@ is the
-- 'NodeId' of the node which replied. Other received messages not satisfying
-- the predicate are returned as well.
--
-- The nodes are monitored so the function can return the empty list when nodes
-- are unavailable or when all replies are rejected by the given predicate.
--
receiveFrom :: Serializable b
             => ((NodeId, b) -> Bool)
             -> [ProcessId]
             -> Process [(NodeId, b)]
receiveFrom p pids = C.bracket (mapM monitor pids) (mapM unmonitor) $ \refs -> do
    callTrace $ "receiveFrom: " ++ show pids
    (\a b c -> fix c a b) []  (zip (map processNodeId pids) refs) $ \loop
                          acc nrefs                                       ->
      case nrefs of
        [] -> return acc
        _  -> receiveWait
          [ matchIf (\(ProcessMonitorNotification ref _ _) ->
                        any ((== ref) . snd) nrefs
                    )
                    $ \pmn@(ProcessMonitorNotification ref pid _) -> do
                        callTrace $ "receiveFrom: " ++ show pmn
                        loop acc $ delete (processNodeId pid, ref) nrefs
          , match $ \b -> if p b then do
                              callTrace $ "receiveFrom: " ++ show (fst b, p b)
                              return $ b : acc
                            else do
                              callTrace $ "receiveFrom: " ++ show (fst b, p b)
                              loop (b : acc) $ filter ((fst b /=) . fst) nrefs
          ]

-- | Send @(self, msg)@ to one or more named processes @label@ on @preferNodes@
-- and @nodes@ and wait for a reply satisfying the given predicate.
--
-- Returns a reply satisfying the predicate at the head of the resulting
-- list if any, followed by other replies not satisfying the predicate.
--
-- Each reply must contain the NodeId of the replying node.
--
-- Two-stage version of 'ncallRemoteAnyTimeout'. Messages are first sent to all
-- @preferNodes@ at the same time, then, if no reply arrives within at least
-- @softTimeout@, to all @nodes@ at the same time.
ncallRemoteSomePrefer :: (Serializable a, Serializable b) =>
     Int                -- ^ Soft timeout, in microseconds
  -> Int                -- ^ Timeout in microseconds to find pids
  -> [NodeId]           -- ^ Preferred target nodes
  -> [NodeId]           -- ^ Target nodes
  -> String             -- ^ Target process label
  -> a                  -- ^ Message to send
  -> ((NodeId, b) -> Bool) -- ^ A predicate that indicates the desired answer in
                           -- case multiple answers are received.
  -> Process [(NodeId, b)]  -- ^ Replies received, if any
ncallRemoteSomePrefer softTimeout t preferNodes nodes label msg p =
    withLabeledProcesses t (preferNodes ++ nodes) label $ \case
      []   -> return []
      pids -> do
        let (preferred, rest) = partition ((`elem` preferNodes) . processNodeId)
                                          pids
        self <- getSelfPid
        C.bracket (spawnLocal $ do
            _ <- receiveTimeout softTimeout []
            forM_ rest $ \pid -> usend pid (self, msg)
          )
          (`exit` "ncallRemoteAnyPreferTimeout terminated")
          $ const $ do
            forM_ preferred $ \pid -> usend pid (self, msg)
            receiveFrom p pids

-- [Removed Functonality]
--
-- Many of the functions were unused and deleted after:
--     4dbde755af00ef451409a0c69459b8d434020376
-- They are:
--   * callAnyTimeout            -- Messages are sent all at the same time.
--   * callAnyStaggerTimeout     -- Messages are sent one at a time, preserving
--        the order of @pids@, and using a temporary process to send at most one
--        message within at least each
--   * callAnyPreferTimeout      -- Two-stage version of 'callAnyTimeout'. Messages
--        are first sent to all @preferPids@ at the same time, then, if no reply
--        arrives within at least @softTimeout@, to all @pids@ at the same time.
--   * ncallRemoteTimeout        -- Named process version of 'callTimeout'.
--   * ncallRemoteAnyStaggerTimeout -- Named process version of 'callAnyStaggerTimeout'.
