-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
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

import Control.Distributed.Process (NodeId)
import Control.Distributed.Process.Closure

import Control.Arrow ((>>>))

-- | When a new replica says "Hello!", it asks the recipients to review the
-- current group membership and propose a new one.
type NominationPolicy = [NodeId] -> [NodeId]

-- | The simplest policy: add the greeter to the membership list without
-- otherwise modifying it.
meToo :: NodeId -> NominationPolicy
meToo = (:)

notThem :: [NodeId] -> NominationPolicy
notThem ρs = filter (`notElem` ρs)

-- | Propose to replace membership entirely, i.e. perform a coup d'état.
putsch :: [NodeId] -> NominationPolicy
putsch = const

-- | Propose to be the sole member of the group.
dictator :: NodeId -> NominationPolicy
dictator ρ = const [ρ]

-- | Remove all replicas on the given node.
notNode :: NodeId -> NominationPolicy
notNode nid = filter (nid /=)

-- | The "(Only) One Replica Per Node" program.
orpn :: NodeId -> NominationPolicy
orpn ρ = notNode ρ >>> (ρ :)

-- | Nominate the null membership list. This is useful to stop a replicated
-- state machine.
stop :: NodeId -> NominationPolicy
stop _ = const []

remotable ['meToo, 'notThem, 'putsch, 'dictator, 'notNode, 'orpn, 'stop]
