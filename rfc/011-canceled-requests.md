# RFC: Canceling requests in replicated-log


## Introduction

This document contains a design proposal for supporting canceled requests
in replicated log.


## Purpose

In the current state of affairs, the loss of messages in replicated-log
internals would imply a client never receiving an answer. The client could stop
waiting for a reply when it takes too long. However, without some support from
replicated-log, two undesirable scenarios could occur:

1. If the client retries the request, the request can be duplicated and an
   update can be applied twice when it was intended to be applied just once.

2. The update of a canceled request is applied arbitrarily late, thus potentially
   modifying the outcome of requests issued after the cancellation.

This proposal attempts to solve (2), while leaving to the application dealing
with (1).

An example of (2):

* A client requests to remove a node A from the resource graph. Call this
  request 1.
* The client cancels request 1 and retries. The retried request now completes.
* Some time later, the client adds again node A.
* Now the first attempt of request 1 appears and completes, removing node A.

A more disastrous case could be having something similar occur with
reconfiguration requests.


## Constraints

1. The update of an abandoned request won't be applied after the updates of
   subsequent requests.

2. Clients are not expected to send a new request unless the previous request
   has been acknowledged or abandoned.


## Description

Each request will have a request identifier, henceforth `RequestId`, which is
different for every request. If a client submits an update twice, it will have
a different `RequestId` each time.

Each request is sent together with its `RequestId`. Acknowledgements to the
client will contain the `RequestId` of the acknowledged request.

Request are first sent to any replica. Then this replica will reply with the
ProcessId of the leader replica, unless it is the leader replica in which case
it will serve the request.

While a client cannot talk to the leader replica with a direct connection, it
cannot make any requests.


### Why direct connections to the leader?

Suppose the connection between a client and the leader replica fails, and the
client wants to find out if its request was applied or not. For this, the client
must read the state. But specifically, it wants to read the state with no danger
of the old request appearing afterwards.

A way to ensure that the read request will be processed after the interrupted
request, is to wait until the client can communicate with the leader again with
a direct connection.

Another approach could be to attach an expiration time to requests. But we do
not explore this further.


### Abandoning requests

A client abandons a request by sending another request before receiving an
acknowledgement. The leader replica makes sure that requests are served in
order of arrival.

Clients are expected to monitor the leader replica. When the connection to the
leader breaks, they must poll some other replica to learn of a new leader, or if
the disconnected leader is still alive, poll it until communication can be
reestablished.


### Changes to the ambassador

The ambassador is a process which receives requests from various clients in the
local node. Therefore, it is assigned the responsibility of finding which the
leader replica is. The ambassador will then forward requests only to this
replica until it is disconnected from it, in which case it will start polling
other replicas to stay updated of leader changes until it can talk to the leader
again.

A non-leader replica may receive requests if leadership changed recently. In
this case the replica will drop the request and will answer back with the
membership of the group which contains the last known leader at the head.


### RequestIds

Currently, each request is identified with the `ProcessId` of an ephemeral
process created with `callLocal`. Abandoning a request requires starting a new
request and a new ephemeral process. Cloud Haskell does not guarantee the order
in which messages arrive when sent by different processes, and thus there is no
guarantee that the abandoned request will arrive before the new one to the
ambassador.

An inspection of the current implementation of distributed-process, however,
indicates that messages sent with `usend` arrive in the order they were sent
even when using different processes. This is because all unreliable messages use
the same connection established between node controllers.

To be on the safe side, though, we will have the ambassador acknowledge each
message sent by an ephemeral process. An ephemeral process won't terminate
even if interrupted, until it receives the acknowledgement from the ambassador.


### Epochs

The term of each leader replica is called an epoch, and it is identified with
the `LegislatureId` of the legislature where the replica became a leader.

Each client sends the requests accompanied by the last known epoch. The leader
replica discards the requests which do not belong to the current epoch. For
the leader, there is no way to know if a request from a previous epoch has been
abandoned or not.

In principle, it is difficult for a leader to get a proposal from an earlier
epoch. But it is not impossible. A leader may lose the lease, and recover it
some time later. A request of the old epoch may delay enough to arrive at the
new epoch.
