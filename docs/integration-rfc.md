# RFC: Halon<=>CEP Integration

## Introduction

Halon is a library for high-availability distributed computation.  CEP
is a library for writing interactive processors for complex events; we
would like to use this library to implement Halon, abstracting out the
event-processing machinery to allow us to write the business logic in
a composable, declarative manner.  This RFC aims to list places in
which CEP can be used in place of existing functionality, and detail
how the replacement could take place.

## Purpose

Halon currently contains a lot of bureaucracy around disseminating and
handling events, generally handled through impure constructs such as
`IO`.  CEP provides an alternative that handles event dissemination
mostly transparently, allowing us to express event-handling processes
as compositions of pure networks of event transformers and
time-varying values.

## Constraints

The CEP integrations must preserve the original functionality of
Halon.

## Description

### Event Queues

Halon currently contains a component called `EventQueue` that is
responsible for replicating seen events between recovery coordinator
instances.  This can be translated quite straightforwardly to the CEP
framework.  In addition, `EventQueue` contains machinery implementing
event sources and sinks as described in the
[CEP HLD document](hld.md); this machinery can be replaced wholesale
with CEP's, hiding some of the moving parts.

### Node Agents/Tracking Station

Event queues currently use the local `NodeAgent` to coordinate with
the distributed tracker processes.  CEP already handles this
functionality with a slightly different protocol (it expects a list of
‘broker’ processes analogous to `EventQueue`'s ‘trackers’), but
currently notifies *all* brokers of requests; to be precisely
feature-equivalent to `EventQueue`+`NodeAgent`, CEP needs to implement
a more intelligent notion of ‘preferred node’ as `NodeAgent` currently
does, increasing efficiency.

### Recovery Coördinator

The Halon (Mero) recovery coordinator is a distributed process that
listens for events happening around the cluster and takes decisions to
initiate various kinds of recovery based on perceived complex
failures.  Currently we have a stub implementation, which:

+ Keeps track of the cluster topology in a resource graph
+ Respawns failed nodes
+ Responds to striping errors by broadcasting an epoch transition
+ Applies epoch transitions

These tasks can all be expressed quite nicely in terms of the CEP
framework; particularly, the resource graph is a `Behaviour`, a pure
time-varying value.

### Services

The RC is not the only party interested in events.  The design
documents for Mero specify that when sufficient resources are
available on the individual node to perform repair, the node should be
able to diagnose the problem and initiate and perform repair by
itself, without recourse to networked resources.  It makes sense,
then, for each node to run its own per-node service capable of
diagnosing local errors, reporting to the resource coordinator only
for logging.
