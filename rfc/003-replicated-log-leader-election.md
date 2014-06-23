# RFC: Leader election in replicated-log

## Introduction

This RFC defines how the replicated-log implementation can be optimized
by designating a leading replica which is granted leases periodically.

## Purpose

The current implementation of replicated-log suffers from the following
problems.

* When multiple clients submit updates to the log concurrently, there is
  contention among the replicas to get consensus on how to fill the next
  slot in the log.
* When a nullipotent request is submitted to a replica, it needs to be
  added to the log so the result is consistent with previous updates
  that the client could have submitted to other replicas.

Having a leading replica (from now on leader) could solve the above
issues by:

1. forwarding all requests to the leader, and
2. executing nullipotent requests in the leader without adding them to
   the log.

## Constraints

* Read requests should observe the effect of earlier updates issued by
  the same client.
* All clients should observe log updates happening in the same order.
* Leader election should not interfere with the processing of concurrent
  client requests submitted to replicas which have quorum.

## Description

In abstract terms, the leader election algorithm has all replicas
competing for a lease. When one of the replicas obtains the lease, it
becomes the leader and has a period of time during which it is allowed
to renew the lease and pass decrees.

If the lease expires, then all replicas can compete again to get it.

A lease is a guarantee that no replica will attempt to become a leader
during a certain period of time. This period starts at the moment the
replica submits the lease requests for consensus, and its length is
specified in the lease request.

When other replicas observe that the lease request passed consensus they
should stop requesting the lease for the duration of the lease period.
Note that unlike in the leader case, the lease period for non-leaders
starts only when the passed request is observed.

At any time, the replicas should be able to answer the following
questions based on their local state:

* Who the last known leader is.
* If the lease of the last know leader has expired.

To answer this questions, the head of the list of replicas in the local
state will be considered the leader. In addition, the local state will
be augmented with the time at which the last lease period started
according to the local clock.

Replicas will have a new input parameter which is the length of the
lease period they should use when requesting the lease by first time.
Later on, all replicas should adopt the lease period that the last
leader proposed. This behavior will make it possible to update the lease
period that the group uses without taking it off-line and accessing only
a quorum of replicas.

It is possible that the local state gets outdated if some passed decrees
are lost when communicated to the replica. In this case, the replica can
propose itself as leader, but before doing so, it must fill in any gaps
it has in the log. If while proposing itself, it discovers that there
are new passed decrees, it must retrieve those and execute them before
retrying to gain leadership.

Lease requests will be implemented with reconfiguration requests, which
will be extended with a field to indicate the lease period.

### Operation of the leader

The leader should serve nullipotent requests by skipping the consensus
step and should submit other requests for consensus. Before every
operation, it should check that it still has the lease.

For optimization purposes, a timer must be set so the lease is renewed
on time. Therefore, the timer needs to be shorter than the lease to
allow for the time that it takes to renew it.

### Operation of non-leaders

If a replica is not the leader, it should forward client requests to
whomever is. It is not necessary for correctness that the local clock be
checked before every such operation, but it could help the system to
recover if forwarding messages unnecessarily is avoided.

The non-leader replica must set a timer to learn when the leader lease
expired. When the timer triggers the replica can either update its log
or request the lease if the log is up-to-date.

If the leader lease has expired, the replica should keep on hold all
requests until a new leader is known.

When the log is up-to-date the replica should request the lease if there
is no leader. If the request fails, then the replica should consider its
log as outdated until more requests are executed.

## Pending issues

The above algorithm reduces contention among replicas when submitting
consensus proposals. Contention is not completely eliminated though.
Whenever non-leader replicas think that the leader has failed to renew
the lease, multiple replicas may try to submit lease requests for
consensus.

Thus, the consensus layer needs to be prepared to cope with this
situation, which will be addressed in separate RFCs.
