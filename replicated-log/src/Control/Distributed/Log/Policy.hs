-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Repository of nomination policy functions, used to compute a new list of
-- proposed group members following a greeting.
--
-- /NOTE:/ a nomination makes both positive and negative assertions. it asserts
-- membership of new replicas, but also that current members not in the
-- nomination list are dead.
--
-- This module is intended to be imported qualified.

{-# LANGUAGE TemplateHaskell #-}
module Control.Distributed.Log.Policy where

import Control.Distributed.Process (NodeId, ProcessId, processNodeId)
import Control.Distributed.Process.Closure

import Control.Arrow ((>>>), (***))

-- | When a new replica says "Hello!", it asks the recipients to review the
-- current group membership and propose a new one.
type NominationPolicy = ([ProcessId], [ProcessId]) -> ([ProcessId], [ProcessId])

-- | The simplest policy: add the greeter to the membership list without
-- otherwise modifying it.
meToo :: ProcessId -> ProcessId -> NominationPolicy
meToo α ρ = (α:) *** (ρ:)

notThem :: [ProcessId] -> [ProcessId] -> NominationPolicy
notThem αs ρs = filter (`notElem` αs) *** filter (`notElem` ρs)

-- | Propose to replace membership entirely, i.e. perform a coup d'état.
putsch :: [ProcessId] -> [ProcessId] -> NominationPolicy
putsch acceptors replicas = const acceptors *** const replicas

-- | Propose to be the sole member of the group.
dictator :: ProcessId -> ProcessId -> NominationPolicy
dictator α ρ = const [α] *** const [ρ]

-- | Remove all replicas on the given node.
notNode :: NodeId -> NominationPolicy
notNode nid =
    filter (\α' -> nid /= processNodeId α') ***
    filter (\ρ' -> nid /= processNodeId ρ')

-- | The "(Only) One Replica Per Node" program.
orpn :: ProcessId -> ProcessId -> NominationPolicy
orpn α ρ
    | processNodeId α == processNodeId ρ =
        notNode (processNodeId α) >>> (α :) *** (ρ :)
    | otherwise = error "orpn policy: acceptor and replica must be on same node."

-- | Nominate the null membership list. This is useful to stop a replicated
-- state machine.
stop :: ProcessId -> ProcessId -> NominationPolicy
stop _ _ = const ([], [])

remotable ['meToo, 'notThem, 'putsch, 'dictator, 'notNode, 'orpn, 'stop]
