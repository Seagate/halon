# RFC: CEP-Style Topology

## Introduction

This document aims to propose a new topology for Halon that takes
advantage of the CEP framework's capabilities.

## Purpose

With the addition of CEP to the Halon technology stack, some of the
existing infrastructure becomes unnecessary, or can be simplified.
Conversely, some of the existing infrastructure imposes requirements
on the CEP framework that must be discharged before implementation.

## Constraints

The existing topology looks like this:

+ A recovery supervisor listens to events from the recovery
  coordinator and its monitors.
+ The recovery coordinator listens to events from the event queue.
+ The event queue listens to events from individual node agents.
+ The node agent listens to events from individual services.

The event queue provides an availability guarantee: every event in the
event queue must be eventually handled, and will not be removed from
the event queue until it has been handled successfully.  We must
retain this guarantee.

## Description

This RFC proposes a slightly altered topology based on the
capabilities of the CEP framework.

+ A recovery supervisor listens to events from the recovery
  coordinator and its monitors.
+ The recovery coordinator uses the event queue as a broker.  When the
  recovery coordinator subscribes to an event, the request is sent to
  the event queue, which stores the subscription and *itself*
  subscribes to the event on the broker used by the services.
+ When an event is emitted, it will be sent to the event queue, which
  will wrap the event in a special `Synchronous` type, including an
  event ID, and forward it on to the recovery coordinator.
+ When the event queue receives an acknowledgement message from the
  recovery coordinator, it will remove the acknowledged event from the
  queue.

### Implementation

As it stands, CEP does not send ACK messages, which is necessary for
correct implementation of the event queue.  It will need to be
extended to support publishing of and subscription to synchronous
events, by adding `publishSync` and `subscribeSync` primitives, which
have an identical interface to the existing `publish` and `subscribe`
primitives, but will transparently produce and handle synchronous
events, sending back an acknowledgement to the source on successful
processing.

The remainder can be implemented straightforwardly in terms of
`cep-sodium`.  Acknowledgement messages can be handled as normal
events; the queue of events itself can simply be a `Behaviour` of a
list of existentials.
