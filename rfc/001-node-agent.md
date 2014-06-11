# RFC: the Node Agent

## Introduction

Define the role of the node agent and how it should be implemented
using distributed-process. This is a high-level design, not an API
spec.

## Purpose

Each node in the cluster that is to be managed by Halon must be able
to receive commands and notifications from the Recovery Coordinator.
Conversely, each node in the cluster must also be able to notify the
Recovery Coordinator following local observations such as service,
disk or network failures.

## Constraints

* Low resource usage (memory, CPU).

## Context

The Halon architecture makes the choice of using Cloud Haskell
messaging for all cross node communication that is internal to Halon.
Satellites don't communicate with the tracking station using an
externally specified request/reply protocol (such as HTTP). Cloud
Haskell messages are more lightweight, use up fewer network resources
and contain enough information to make handling them typesafe.

## Definitions

* **System daemon:** a long running process, where *process* is to be
  taken in the sense of the unit of concurrency of the operating
  system.

* **System service:** a collection of system daemons (often just one)
    providing a particular function for the OS or for applications
    (e.g. HTTP server, an IPC bus, *etc*).

* **Cloud Haskell node:** a virtualization of a physical host (or any
    system-level virtualization thereof) in Cloud Haskell. Not to be
    confused with a *node*, which more commonly refers abstractly to
    a networked physical host.

* **(Cloud Haskell) process:** the unit of concurrency in Cloud
    Haskell. A system daemon may be implemented as a Cloud Haskell
    node, itself hosting any number of processes.

## Description

System services and monitors on satellites and in the tracking station
are not normally expected to know the Cloud Haskell wire format.
Furthermore, it is useful to virtualize (represent) a node (physical
hosts) as a single Cloud Haskell node (as opposed to many, say one per
service). Therefore, a single instance of the Cloud Haskell runtime,
in the form of a system daemon, runs on each node: this instance
implements the node.

A Cloud Haskell node can receive any number of commands drawn from
a fixed set determined by the implementation. Insofar as these
commands are sufficient for the purposes of Halon, it is not necessary
to introduce an explicit node agent process *within* the Cloud Haskell
node to interpret commands emanating from the tracking station: the
tracking station can instead send said commands to the node, not any
process sitting on top.

In particular, if services running on the satellite are to be modelled
as processes running on the Cloud Haskell node, then starting and
stopping a service map to the `spawn` and `kill` commands. One might
be tempted to introduce a node agent process regardless to support
additional commands. But such a process would ultimately be a mere
broker between the tracking station and the individual services, since
all such commands would have one or more of the services as targets or
at any rate subjects of such commands.

A broker process may on occasion be useful for some commands, but that
is not to say that a *single*, *long lived* and *universal* broker is
appropriate. Process creation is cheap, so self-contained, bespoke
brokers can always be spawned on a case-by-case basis to facilitate or
optimize some commands (e.g. killing all services on a node). This
latter model of communication with satelites has one crucial
advantage: while a command interpreting broker has an *a priori fixed
set of commands* that it can interpret, the set of brokers itself is
*arbitrary*. This means that the tracking station can perform
arbitrary actions on satellites, even ones that had not originally
been foreseen when implementing the satellites.

This discussion leads to the following design:

* No node agent process. The Cloud Haskell node itself is the "Node
  Agent".

* Services are modelled as Cloud Haskell processes. This makes it
  possible to encapsulate all knowledge and especially all state
  involved in communicating with a given service be self-contained
  and concurrent.

* Commands to start a service spawn a new process. Other service
  commands are sent directly to this process.

* Actions on multiple services at once are performed by
  self-contained, short-lived processes spawned asynchronously,
  locally or remotely.

* As stated in the architecture, all service commands *must* be
  idempotent.

### Identifying a service

Services are just processes. In principle, there is therefore nothing
stopping the Recovery Coordinator from spawning multiple instances of
the same process on a node. This is undesirable, however, since many
system services typically rely on shared global resources, for which
they demand exclusive access.

Strictly speaking, a process is a service *instance*. However,
a *service* can be identified to a *service instance* if there can
only ever be one such instance on any given node. A service is
identified by name. Any process that is an instance of this service
must take ownership of that name.

The relationship between a service instance and the name of the
service to which it pertains is recorded in the resource graph. The
obvious choice would be to instead use Cloud Haskell's registry for
this. The resource graph is a better option, because:

1. A name is really a resource like any other: a limited number (one)
   of processes may own it.

1. Rather than scatter the state regarding resource ownership across
   different subsystems, we keep to a unified representation of
   ownership, allowing a single set of querying facilities to be
   brought to bear.

1. Storing this information in the global resource graph makes it
   possible to transparently retarget where the information is located
   in the cluster. We can have the entire resource graph be stored
   centrally in the tracking station. Or for efficiency's sake, we can
   have some resources stored locally only. In other words, federate
   parts of the global resource graph across the cluster.

### Generic services

Services are processes like any other. Just like any other process,
one can send message to them, kill them and so on. In fact, different
services accept many of the same messages, to which they respond in
much the same way. Any service must respond to at least the following
messages:

* `Check`: respond with a message indicating the health of the service.
* `Status`: a message asking for the service to log status info immediately.

Services, being processes, can be spawned. They can also be killed.
Spawning, killing, `Check` and `Status` loosely correspond to the four
mandatory "resource agent actions" that [OCF services][ocf-spec] must
support (called `{start|stop|monitor|meta-data}`).

Note that it would be silly to reimplement behaviours for each service
indepedently. But independent processes need not have completely
independent implementations: one can of course define a *generic
service*, in much the same style as Erlang's `gen_server` for generic
servers, and managed processes in `distributed-process-platform`.
Exactly how the implementation of services is factored is outside of
the scope of this RFC.

### Starting a service

Services are started like any other process, using the `spawnAsync`
primitive. Services *must* ensure that the starting action is
idempotent. That is, the process implementing the service must make
sure that it is unique on the node. This can conceivably be done by
acquiring a node-local lock, in whatever shape or form. Locks *should
not* be used to identify services: the resource graph alone is the
authority with regards to the identity of a service.

### Stopping a service

Services are killed the way any other Cloud Haskell process is killed.

Services must *always* acquire resources in an exception safe manner
(e.g. using the `bracket` primitive). Indeed, any service can be
killed, and killing uses asynchronous exceptions.

### Broadcasting state

Global state is normally only stored centrally in the resource graph
maintained by the tracking station. However, satellites may want to
maintain their own weakly consistent view of this state for the sake
of efficiency (fewer network roundtrips just to query the state). Some
parts of the global state in fact *must* be replicated in this
fashion, to avoid infinite regress: the locations of the tracking
station nodes (since that data is necessary to query the data).

Consequently, whenever the set of tracking station nodes changes, the
recovery coordinator should coordinate a cluster wide broadcast
letting other nodes know about the change. Because all service
instances (aka processes) are stored in the global resource graph, the
recovery coordinator has all the information at hand to contact all
services on all nodes in one fell swoop.

For large cluster sizes, it is usually not possible to contact all
nodes at once: chances are some are failing concurrently to the
broadcast. This is not a problem in practice, since again, only
a weakly consistent (or *eventually consistent*) view of the state is
required. Just how long does "eventually" mean is up to the recovery
coordinator and the services. (One can imagine simply ignoring
unreachable services, in which case inconsistencies survive until at
least the next broadcast, or using epochs to detect out of date state
slightly earlier.)

If very many services coexist on a single node, then better network
utilization can be achieved by introducing one level of indirection.
The Recovery Coordinator can spawn a broker process on any given node,
parameterized by the identifiers of the processes that ought to be
notified. It is up to the Recovery Coordinator which method it
chooses. It might well decide to use both.

[ocf-spec]:
http://www.opencf.org/cgi-bin/viewcvs.cgi/specs/ra/resource-agent-api.txt?rev=HEAD
