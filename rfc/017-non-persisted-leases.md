# RFC: Non-persisted leases


## Introduction

This document describes changes necessary to replicated-log so it does not
persist leases.

Disk IO can present high latencies, and writing leases can delay granting of
the lease beyond the current lease the leader has. This causes the group to
stop processing requests until a new leader is elected.

However, there is no good reason to halt the group. Leases do not need to be
remembered. Only the current lease is of interest.

Changing leaders unnecessarily is also undesirable because there are plans to
expose knowledge of which the leader replica is. This information is used to
spawn leaders of upper layers, and moving these leaders of node could be
expensive.

Not persisting the leases is not enough to achieve survival of the leader in the
face of IO congestion. Any processes that participate in granting leases must
not block on IO either.

## General scheme

All lease requests will use a single decree. When the lease expires, it is
removed from the (in-memory) state of the acceptor store. Thus, replicas can
always query and compete for the same decree and learn if a lease is in effect.

Since leases are not persisted, a newly spawned node cannot know if if granted
a lease in the past which is still active. Because of this, acceptors should
refrain from answering any lease requests until a full lease period has elapsed
since they went live. Otherwise, consider what would happen if acceptors
responded from the start. 

Let's say we have nodes [1, 2, 3, 4]. Node 1 asks the lease and the acceptors
of 1, 2 and 3 accept it. Now nodes 2 and 3 crash and restart. Now node 4 asks
for the lease, and acceptors in nodes 2, 3 and 4 accept it. If the lease granted
to node 1 is still in effect, there are two nodes who claim to have the lease.

## Changes in replicas

Replicas will use an exclusive decree for lease requests. These decrees won't be
inserted in the log. 

Replicas perform IO when storing log entries, when reading log entries and when
restoring snapshots. Of these operations, the later two do not allow the replica
to lead until they complete. But the former we could do asynchronously. We will
use d-p-async for storing log entries and limiting the amount of asynchronous
threads which are created.

## Changes in acceptors

Acceptors are currently doing disk IO and network IO. The store interface will
be modified so writing is asynchronous. The write operation will take a callback
to execute when the write completes.

This should keep the acceptor code concerned only with the Paxos protocol, avoids
blocking the acceptor on IO and allows the store to recognize lease requests and
not persist them.

The store might have to spawn new threads to deal with blocking calls, but this is
a concern of the store which knows which values need to be persisted and how.
