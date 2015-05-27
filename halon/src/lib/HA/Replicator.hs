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
  , RStateView(..)
  ) where

import Control.Distributed.Process
           ( Process, Static, Closure, NodeId )
import Control.Distributed.Process.Serializable
           ( Serializable, SerializableDict )

import Data.Typeable ( Typeable )


-- | Functions which allow to update and query parts of
-- a replicated state.
--
-- In @RStateView st v@ the type @st@ is the type of states
-- and @v@ is the type of a particular view of those states.
--
-- It should hold: @prj . update f == f . prj@
--
data RStateView st v = Serializable v => RStateView
    { prj :: st -> v
    , update :: (v -> v) -> st -> st
    }
  deriving Typeable

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
            -> Int
            -> Int
            -> [NodeId]
            -> st
            -> Process (Closure (Process (g st)))

  -- | Like 'newRGroup' but only spawns a replica in the given node.
  --
  -- If the node does not form part of a group this operation fails.
  spawnReplica :: Serializable st
               => Static (SerializableDict st)
               -> NodeId
               -> Process (Closure (Process (g st)))

  -- | Releases any resources used by the replication group.
  stopRGroup :: g st -> Process ()

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
  updateStateWith :: g st -> Closure (st -> st) -> Process ()

  -- | Yields the local copy of the replicated state.
  getState :: g st -> Process st

  -- | Sets the view of the replicated state.
  viewRState :: Typeable v => Static (RStateView st v) -> g st -> g v

#if MIN_VERSION_base(4,7,0)
deriving instance Typeable Replica
#endif
