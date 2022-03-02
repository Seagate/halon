-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
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

  -- | @newRGroup name t snapshotTimeout leaseTimeout ns onCreation st@ creates
  -- a replication group with the given @name@ which saves snapshots of the
  -- distributed state every @t@ updates and gives up saving a snapshot if it
  -- takes longer than @snapshotTimeout@.
  --
  -- Leader leases last @leaseTimeout@ microseconds, the longer this value, the
  -- longer it will take to elect a leader. But too short a value would prevent
  -- leaders from doing any useful work before the lease is over.
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

  -- | Monitors the local replica and sends a 'ProcessMonitorNotification' to
  -- the caller when the local replica is not a leader anymore.
  monitorLocalLeader :: g st -> Process MonitorRef

  -- | Returns the 'NodeId' of the leader replica if known.
  getLeaderReplica :: g st -> Process (Maybe NodeId)

retryRGroup :: RGroup g => g st -> Int -> Process (Maybe a) -> Process a
retryRGroup = retryMonitoring . monitorRGroup

withRGroupMonitoring :: RGroup g => g st -> Process a -> Process (Maybe a)
withRGroupMonitoring = withMonitoring . monitorRGroup

#if MIN_VERSION_base(4,7,0)
deriving instance Typeable Replica
#endif
