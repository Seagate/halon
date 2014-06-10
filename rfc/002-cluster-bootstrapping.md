# RFC: Cluster bootstrapping

## Introduction

Bootstrapping is the process of making the cluster reach steady state.
This document specifies the boostrapping process for the cluster, as
well as for individual nodes.

## Purpose

Halon makes the cluster resilient to crashing services, faulty
hardware and temporary network conditions, but only after reaching
steady state. The tracking station brings services back up through
a node agent installed on the target node, but who brings the node
agent back up? Who brings up the tracking station and how?

## Constraints

* Cluster and node bootstrapping must be completely automated - no
  operator intervention required barring exceptional circumstances.

* Boostrapping must be small - the rest of cluster initialization and
  node initialization should be considered a recovery action, no
  different from any other recovery action.

* As much bootstrapping as possible must be shared between tracking
  station nodes and satellites.

* Deploying Halon should be easy: in the best case, as easy as copying
  a single executable binary file onto a node.
  
## Context

* Interaction with any node in a Halon cluster is done through the
  `halonctl` shell command.

## Description

## General principles

* Those tracking station components that map to processes are
  considered services, just like any other service, and therefore
  respect the same protocol as services.

### Boostrapping a node

The following bootstrapping procedure applies equally to tracking
station replicas as to satellites.

1. The node boots up.

1. System initializes.

1. The `halond` command is executed as part of the system
   initialization sequence. `halond` is a system daemon implemented as
   a Cloud Haskell node.

1. `halond` does one thing and one thing only: it creates a Cloud
   Haskell node. This implies setting up the network transport
   according to the configuration parameters provided (e.g. on the
   command line, in a text file, or compiled in). The *only*
   configuration data necessary is for the bootstrapping process
   alone: i.e. network transport parameters. All other configuration
   data should be provided centrally, by the tracking station.

1. Services (including tracking station components, see above) are
   managed on one or more nodes at once using the `halonctl` command. It
   is through the `halonctl` command that the tracking station is
   bootstrapped. It is through the `halonctl` command that satellites are
   told to phone home to the tracking station.

1. When the `halonctl` command is told to bootstrap a tracking station
   node, it spawns a single process called the Recovery Supervisor.

1. When the `halonctl` command is told to bootstrap a satellite, it
   spawns a single process that sends "node up" events to the tracking
   station in a loop. This process will eventually be killed by the
   Recovery Coordinator as part of recovery.

1. The Recovery Supervisor in turn spawns other components of the
   tracking station. It may need to wait for quorum before spawning
   some such components (e.g. the Recovery Coordinator).

1. The tracking station is considered bootstrapped once it has reached
   quorum. At this point, the recovery supervisors elect a master
   node. The Recovery Coordinator is spawned on the master node.

1. The Recovery Coordinator starts responding to "node up" events
   emanating from satellites. From this point onwards, making a node
   reach its steady state is an instance of recovery.

### Example scenario: coordinated deployment of a tracking station

```Shell
$ pdsh -a halond              # start on all nodes in the cluster
$ halonctl -e 'readGendersFile >>= filterPeers >>= \peers ->
               mapM_ (`spawn` recoverySupervisor peers) peers'
```

where the `-a` flag to `pdsh` instructs it to run the given command on
all hosts in some default genders file. A tracking station node is
also called a *peer*, hence the name of the flag to provide 

In the above, we use `halonctl`'s ability to interpret arbitrary Haskell
expressions to program the cluster, but command line flags for common
operations could just as well be used, for those that would rather not
write Haskell. Or indeed, `pdsh` to run the `halonctl` command on each
peer.

### Example scenario: uncoordinated deployment of the tracking station

In the example above, the entire tracking station is spawned
simultaneously, from a single `halonctl` command. But the point of
separating node initialization (the `halond` command) from the rest of
the bootstrapping process is that `halonctl` can be run from anywhere,
and multiple times, depending on the particular deployment. That is,
`halonctl` could be invoked once centrally, or on each individual host
as part of system initialization, along the lines of the following:

```Shell
$ halonctl -e 'readGendersFile >>= filterPeers >>= spawn localnode recoverySupervisor'
```
