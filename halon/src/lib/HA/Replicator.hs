-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Replication interface
--
-- This interface provides operations to control a set of processes
-- that mantain the same replicated state.
--

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE CPP #-}
module HA.Replicator
  ( RGroup(..)
  , retryRGroup
  , withRGroupMonitoring
  ) where

import Control.Distributed.Process
           ( Process, Static, Closure, NodeId, MonitorRef )
import Control.Distributed.Process.Serializable
           ( Serializable, SerializableDict )
import Control.Distributed.Process.Monitor

import Data.Typeable ( Typeable )


-- | Interface of replication groups.
--
-- A replication group is composed of one or more processes called replicas.
--
class RGroup g where

  data Replica g

  -- | @newRGroup t ns onCreation st@ creates a replication group which
  -- saves snapshots of the distributed state every @t@ updates.
  --
  -- The initial state is @st@ and each replica is created on a node of @ns@.
  --
  -- A closure which produces a handle to the group is returned.
  --
  newRGroup :: Serializable st
            => Static (SerializableDict st)
            -> String -- ^ name of the group
            -> Int
            -> Int
            -> [NodeId]
            -> st
            -> Process (Closure (Process (g st)))

  -- | Like 'newRGroup' but only spawns a replica in the given node.
  --
  -- If the node does not form part of a group with the given name, this
  -- operation fails.
  --
  spawnReplica :: Serializable st
               => Static (SerializableDict st)
               -> String  -- ^ Name of the group
               -> NodeId
               -> Process (Closure (Process (g st)))

  -- | Releases any resources used by the replication group.
  killReplica :: g st -> NodeId -> Process ()

  -- | @getRGroupMembers ms@ queries the replicated state for info on the
  --   current members of the RGroup.
  getRGroupMembers :: g st -> Process (Maybe [NodeId])

  -- | @setRGroupMembers ns inGroup@ creates a new replica on every node in @ns@
  -- and adds it to the group, then it removes every replica running on a node
  -- not satisfying predicate @inGroup@.
  --
  -- If a node in @ns@ is already in the group, it will replace any old replica
  -- in the node with a new one. Make sure the old replica is defunct or
  -- replication guarantees will be lost.
  --
  -- Newly added replicas will adopt the state of the group.
  --
  -- The list of new replicas is returned.
  --
  -- Quorum size is defined to be @length rs `div` 2 + 1@.
  --
  -- Throws an exception if contact with the group is lost.
  --
  setRGroupMembers :: g st -> [NodeId] -> Closure (NodeId -> Bool)
                   -> Process [Replica g]

  -- | Indicates to the group handle that it should talk to the given Replica.
  updateRGroup :: g st -> Replica g -> Process ()

  -- | Modifies the replicated state with an update operation.
  --
  -- The result of the update is evaluated to HNF form after the update is
  -- applied.
  --
  -- Blocks indefinitely if contact with the group is lost, until contact
  -- can be reestablished.
  --
  -- May throw an exception if the replica is stopped before or during the call
  -- or if the replica is no longer in a group.
  --
  updateStateWith :: g st -> Closure (st -> st) -> Process Bool

  -- | Yields the replicated state.
  getState :: g st -> Process (Maybe st)

  -- | Reads the replicated state using the given function.
  getStateWith :: g st -> Closure (st -> Process ()) -> Process Bool

  -- | Monitors the group. When connectivity to the group is lost a process
  -- monitor notification is sent to the caller. Lost connectivity could mean
  -- that there was a connection failure or that a request was dropped for
  -- internal reasons.
  --
  monitorRGroup :: g st -> Process MonitorRef

retryRGroup :: RGroup g => g st -> Int -> Process (Maybe a) -> Process a
retryRGroup = retryMonitoring . monitorRGroup

withRGroupMonitoring :: RGroup g => g st -> Process a -> Process (Maybe a)
withRGroupMonitoring = withMonitoring . monitorRGroup

#if MIN_VERSION_base(4,7,0)
deriving instance Typeable Replica
#endif
