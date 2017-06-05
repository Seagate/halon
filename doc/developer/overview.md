% Halon Architectural Overview
% Nicholas Clarke
% 2015-11-30

# Halon Architectural Overview

## Background concepts

### Paxos

Paxos is a protocol designed to solve the problem of distributed consensus
in the face of failure. Broadly speaking, Paxos allows for a number of
(remote) processes to agree on some shared state, even in the presence of
message loss, delay, or the failure of some of those processes.

Halon uses Paxos to ensure the high availability of its core component, the
recovery coordinator. It does this by ensuring that the recovery coordinator's
state is shared with other processes which are able to take over from the
recovery coordinator in the event of its failure.

Further reading:
[Paxos (Wikipedia)](https://en.wikipedia.org/wiki/Paxos_(computer_science))
[Replication HLD](../hld/replication/hld.rst)

### Cloud Haskell

Cloud Haskell (otherwise known as distributed-process, and abbreviated as C-H
or D-P) is an implementation of Erlang OTP in Haskell. It may also be considered
as an implementation of the Actor model. It presents a view of the system as a
set of communicating _processes_. Processes may exchange messages, take (local)
actions, spawn new processes etc.

To Halon, Cloud Haskell provides the ability to write code for a distributed
system without needing to know where exactly each component is running. Thus
we may talk between components in the system without worrying whether they are
running on the same node or a remote node.

Every component of Halon can be seen as consisting of one or more C-H processes.
For this reason, we shall use the term 'Process' to refer to a C-H process,
and append the term 'System' when we wish to refer to a Unix level process.

Further reading:
[Erlang OTP](http://learnyousomeerlang.com/what-is-otp)
[Actor model (Wikipedia)](https://en.wikipedia.org/wiki/Actor_model)
[Cloud Haskell](http://haskell-distributed.github.io/)

## Layer View

We may (loosely) think of Halon as operating on a number of layers:

Services
Recovery
Event queue
Replicator
Paxos
Cloud Haskell

We describe these layers in inverse order, starting with the bottom layer:

### Cloud Haskell

Cloud Haskell provides the abstraction on top of which all other layers sit.
Crucially, it provides the functionality to:

- Spawn processes on local or remote nodes.
- Send messages between processes.
- Monitor processes for failure.

All other layers are implemented as some collection of C-H processes running
on one or more nodes.

Code pointers:

To begin understanding the structure of C-H code:
[Cloud Haskell](http://haskell-distributed.github.io/)
[distributed-process documentation](http://hackage.haskell.org/package/distributed-process-0.5.5.1)

There is little of this layer implemented within Halon itself, but you may
consider `halond`, which is the executable which starts a C-H system-level
process on a node. A network of `halond` instances, whilst doing nothing
themselves, will come to host all of Halon's functionality.

 - `mero-halon/src/halond`

### Paxos

Atop the C-H layer sits a network of processes implementing the Paxos algorithm.
The Paxos layer defines means by which a number of processes may agree on
updates to a shared state. This layer does not care about precisely what that
state is.

Code pointers:

The code implementing the Paxos layer lives in three packages:
- `consensus` provides a basis on which to implement an abstract protocol for
  managing consensus.
- `consensus-paxos` provides an implementation of the `consensus` interface
  using Paxos.
- `replicated-log` extends the Paxos implementation to multi-Paxos, allowing
  for a log of decrees. At each 'round' of Paxos, a single value is agreed upon
  by the processes participating in Paxos. `replicated-log` allows for a list
  of such decrees.

Further reading:
[Replication HLD](../replication/hld.rst)

### Replicator

The purpose of the replicator is to provide a simple interface to the paxos
code. The replicator allows us to address the group of consensus processes in
the manner of a simple data store.

Code pointers:

- `halon/src/lib/HA/Replicator.hs` defines the basic interface to a replication
  group. In particular, see `getState` and `updateStateWith`.
- `halon/src/lib/HA/Replicator/Log.hs` implements the replication group interface
  atop the `replicated-log` package.
- `halon/src/lib/HA/Replicator/Mock.hs` implements the replication group interface
  atop a simple in-memory value. This is used in testing of higher-level
  components when running Paxos is unimportant.

### Event queue

The event queue (EQ) provides a guaranteed delivery message queue, built atop
the replicator. Messages acknowledged by the event queue are guaranteed to be
delivered (at some point) to the recovery coordinator, and to be resilient to
the loss of up to half of the Paxos nodes.

Code pointers:

- `halon/src/lib/HA/EventQueue.hs` provides the code for the event queue itself.
- `halon/src/lib/HA/EventQueue/Producer.hs` provides the functions which are
  used to send messages to the event queue, and verify acknowledgement.
- `halon/src/lib/HA/EQtracker.hs` is not directly related to the EQ, but is a
  separate process running on each node which is responsible for tracking the
  location of nodes running the EQ. This is used to simplify sending messages to
  the EQ.

Further reading:
[Event Queue component](components/event-queue.rst)

### Recovery

The recovery layer consists of a single process known as the recovery
coordinator and a collection of processes which stand ready to respawn the
recovery coordinator should it die, known as recovery supervisors.

The recovery coordinator implements the central logic of Halon; it takes a
stream of messages from the EQ and runs a set of rules which embody
our failure handling logic. In order to do this, the recovery coordinator
additionally has access to shared state (the 'Resource Graph') which is held
consistent amongst multiple nodes through use of the replicator.

In addition to the single recovery coordinator, we have multiple recovery
supervisors. These monitor (and routinely ping) the recovery coordinator, and
if they detect its failure are responsible for spawning a new one. Use of the
replicator ensures both that only one new recovery coordinator is started and
that the new recovery coordinator has access to the same state as the dead one.

Code pointers:

The recovery coordinator is the most complex part of Halon, and much of its
code consists of the recovery rules, which are implemented in their own DSL
(domain specific language). As such, we provide only basic pointers to parts
of the recovery mechanism:

- `mero-halon/src/lib/RecoveryCoordinator/Mero.hs` is the entry point for the
  recovery coordinator.
- `mero-halon/src/lib/RecoveryCoordinator/Rules` contains the various rules
  by which recovery logic is implemented.
- `mero-halon/src/lib/RecoveryCoordinator/Actions` contains the primitive
  actions and queries which make up rules.
- `halon/src/lib/HA/RecoverySupervisor.hs` implements the recovery supervisor.

