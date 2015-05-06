# RFC: Recovery Coordinator

## Introduction

The Recovery Coordinator is the component of Halon responsible for
encoding all business logic; the HA rules used to keep Halon and the
rest of the cluster operational. As such, the RC itself needs to be
resilient to failure; we need a high degree of assurance as to what
decisions it is making.

At the same time, the recovery rules need to be extensible to handle
the various types of failures which may be seen in a running system.
More than other components of the system, the Recovery Coordinator will
be programmed by multiple people, some of whom may be unfamiliar with
Halon, Haskell, FRP or any of the other concepts used in the design.
Writing rules must therefore remain simple and accessible to these
people.

The current design of the recovery coordinator does well at the second
aspect, and has so far been able to encode simple rules/action flows.
However, experimentation with more complex rules has shown it to be
very fragile in the face of race conditions and interactions between
events. We therefore need to think about how we can adapt the system
to reduce the likelihood of these events, whilst retaining the extensibility
and accessibility of the current design.

## Constraints

* Rules should be composable and modular. A component should be able to
  express a set of rules independently of other rules and expose this
  functionality for composition into the recovery coordinator.

* Rules should be simple to write for somebody not expert in Halon or
  Haskell. We currently achieve this well by providing chunks of
  pre-written functionality in the form of 'primitives'.

* We must be able to handle sequences of rules; or, equivalently, rules
  which span multiple messages. As an example, we consider the following
  sequence for rebooting a physical node:

  1. Firstly, attempt to contact the local SSPL agent on the node and issue
     a restart request via systemd.
  2. If this fails (or after a certain period of time the node is still up),
     attempt to issue a restart command through the local Halon agent on the
     node (e.g. calling 'shutdown -r now').
  3. If this fails, or we cannot contact the local Halon process,
     or after a certain period of time the node is still up, attempt to
     issue an IPMI call to power-cycle the node via another node in the
     same rack.
  4. If this fails, we need to declare the node as dead, evict it from the
     cluster, and send an IEM to report this to Seagate.

* We need to support the idea of guaranteed exit from a sequence. In the
  above example, an acknowledgement of the initial need to restart the
  node should imply a guarantee that this rule will eventually end
  in a node restart or declaring the node dead and sending a message. The
  rule cannot get stuck in the middle. This guarantee must be preserved
  through message loss and RC loss/migration to another machine.

* The RC is at the moment single-threaded and responsible for keeping the
  cluster operational, potentially with sub-second response times. As such, it
  must not block on operations.

* The RC will potentially be handling multiple 'threads' of rules at any one
  time. No thread should interfere (unless explicitly) with another.

* We may receive messages for which we have no handler, potentially due to
  previous missing messages or misbehaviour in the sender. These must be
  aged off at some point to avoid arbitrarily growing the message queue.

* Whatever we do must be amenable to methods of testing (or better still,
  proof).

## Description

### Problems

* Missing messages
* Repeat messages
* Out-of-order messages
* Hanging state machines
* Loops
* Local vs global dependencies
* Unwanted messages
* Message flooding

### Diagnosis

Looking at these problems suggests two underlying questions:

1. How do we best represent the state machine/machines underlying transitions
   in the Recovery Coordinator? At the moment, we treat this as one giant
   state machine whose states are possible configurations of the resource graph.
   This has the advantage of an easy, generalised abstraction of the state, but
   this state is very global and not easy to add to.
2. How do we best deal with the lack of ordering or delivery guarantees on
   messages?

### Ideas

* Decouple process mailbox from CEP stream. The idea behind this is that it
  potentially gives us more flexibility in how we handle the messages. For
  example, we can implement prioritisation to allow certain messages to be
  handled first, as well as making our "window" much more adjustable.
* matchIfM - we definitely need some form of this back, to avoid dequeueing
  messages which we will subsequently not be processed.
* local/global `become` - global `become` may be an appropriate tool for
  handling the very start of the system, when we have an explicit global
  state machine. However, it's too coarse for much of the rest of the system,
  when we only wish to change a subset of the RC functionality. For that case,
  we need some local variant of `become` - but the problem is surely in
  deliniating the scope. This also has the problem that we would need to be
  capable of recording the current state of the Processor and including it in
  the replicated state.
* Explicit state machines - for sequential rules we describe an explicit
  state machine in the form of a Process and some serialisable state. Instead
  of handling messages at the top layer, the RC decodes only enough of the
  message to access the correct state machine, which reads its state and handles
  the message. The advantage of this is that we get very local state with far
  fewer constraints upon it than if it were in the resource graph, and we get
  an easy way to handle the hanging problem, since we have an explicit
  representation of the state of a thread. But this doesn't directly address
  the out of order message issue; either they would have to be queued in the
  state or we would have to use something else to inhibit their processing.
* promulgateSync/promulgateTimeout - `promulgate` is very much a rough beast
  at the moment. Give it a message to send, and it will either send it or sit
  forever trying. This means that we have no guarantees about when a message
  will be delivered, and potentially a memory leak in the undying process. We
  could work around this by introducing wrapped variants.
* Messages embodying continuations.
* Cron - or some similar service allowing us to schedule events to happen at
  particular times.
* Typed channels - I haven't thought about this much, but can they help us?
  For example, could we use one explicitly for timer messages to ensure they
  get fired at the correct time?
* Delayed acknowledgement. At the moment, we acknowledge each message delivered
  to the RC when it is processed. But for longer running scenarios, we might
  wish to delay the original acknowledgement until the chain has fully been
  processed.

### Proposal

The first critical piece of functionality is to restore `matchIf` or something
akin to it, to allow us to make decision as to whether to process a message
or not.
