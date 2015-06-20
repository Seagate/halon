# RFC: Reconfiguration in replicated-log


## Introduction

This document contains a design proposal for preserving consistency when
changing the membership of a group of replicas.


## Purpose

Currently, reconfiguring a group can compromise consistency in the following
situations.

1. Adding or removing replicas when there is no quorum

2. Removing replicas when there is quorum

3. Recovering crashed replicas with no quorum

In this RFC we propose changes to the reconfiguration protocol so all of these
situations do not endanger consistency.


### (1) explained: Adding or removing replicas when there is no quorum

When the replicas have no quorum, they may pass reconfiguration decrees to
remove dead replicas.

For this sake they use for consensus an intersection of the acceptors known to
it and the ones that should exist after reconfiguration.

The problem with this approach is that if the replica is delayed, it may be
unaware of what the last membership is, thus computing the intersection with
an obsolete membership. It could end-up using a wrong quorum.

Adding replicas is equally dangerous without quorum.


### (2) explained: Removing replicas when there is quorum

Here is an example of how the state can diverge.

* Suppose we have a group of five replicas A, B, C, D, E.
* A, B, C know the latest decrees, and D, E are delayed.
* The administrator removes A and B using as quorum D, E.

Now the group is composed of C, D, E, but only C knows the latest decrees.
Moreover, because D, E passed a reconfiguration decree to remove A and B while
delayed, their history has diverged from the history in C!

Divergence can happen afterwards with other decrees even if reconfiguration
doesn't cause divergence. Any request that uses the delayed replicas D and E as
quorum will cause the state copies to diverge.


### (3) explained: Recovering crashed replicas with no quorum

If crashed replicas need to be restored and for some reason they cannot spawn in
the same location, replicas can be spawned elsewhere using the state of the
crashed replicas.

Since there is no quorum, there is the risk that the states of the crashed
replicas and the survivor replicas diverge if they pass a reconfiguration
decree.


## Constraints

Any change of the membership must ensure the replicated state is the same in
all replicas eventually.

No passed decrees should be lost provided that the states of at least half the
replicas in the old membership is still available.


## Description

We split the discussion in two cases: when the group has quorum and when it
doesn't.


### The group has quorum

In this case we propose to stop using the intersection of acceptors to pass the
reconfiguration, and instead use the old membership. This solves (2).


### The group has no quorum

The goal in this case is to regain quorum. For this the administrator must state
explicitly the new membership.

Enough replicas of the old membership need to be in the new membership so it can
be ensured that all decrees are recovered. For this sake we request that at
least half of the replicas in the old membership take part in the new one. Here
replicas of the old membership means a replica located anywhere and seeded with
the state of a replica in the old membership.

By asking all the acceptors in the new membership to be online, we can scan the
acceptors for any accepted decrees and propagate them to a quorum of acceptors.

From then on it is safe to submit a reconfiguration request with the new
membership.

As replicas are relocated in a single reconfiguration decree, this ensures a safe
transition in situation (3).

After quorum is regained situation (1) can be handled like situation (2).


### Consensus and replicated-log API changes

Add new fields to the `Protocol` data type:

```Haskell
-- | @prl_sync acceptors@ has the group of acceptors consider passed any decrees
-- known to any acceptor.
--
-- This is useful to resize a group of acceptors where the state of individuals
-- suffices to reconstruct the history but collectively there is not enough
-- redundancy to determine the value of each decree.
--
-- All acceptors are scanned for existing decrees so they all need to be online.
--
-- This may have the effect of "completing" some proposals that were
-- interrupted.
--
-- After this call, any value successfully proposed in the past is guaranteed to
-- be remembered by the group.
--
-- Because it may not be possible to reconstruct the history for any possible
-- change of the membership, it is up to the implementation to define the valid
-- resizings.
--
prl_sync :: [n] -> Process ()

-- | @prl_query acceptors d@ yields the values accepted by the given acceptors
-- at or above the given decree.
prl_query :: [n] -> DecreeId -> Process [(DecreeId, a)]
```

Add a function:

```Haskell
-- ^ @recover h newMembership@
--
-- Makes the given membership the current one. Completes only if all replicas
-- are online.
-- 
-- Recovering is safe only if at least half of the replicas of the current
-- membership take part in the new membership (recovered replicas count as
-- replicas in the old membership).
--
recover :: Handle a -> [NodeId] -> Process ()
```

Have `reconfigure` succeed only when there is quorum.

Acceptors need now the ability to contact other acceptors for synchronization
purposes. This implies that they need to get the same `sendA` function that
proposers have.
