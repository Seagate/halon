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

We start by identifying the core items we will need to put in place to solve
the identified challenges. We can then derive from these some additional
dependencies, from which we can hope to synthesize a set of tasks.

Firstly, in order to handle local state in an easy and maintainable way, we
will need to introduce some form of local state machine abstraction. We must
additionally support the means of persisting this state machine to cope with
RC failure during state machine operation.

State machines must support some concept of forking, since the same rule SM may
be in a different state for particular resources or sets of resources. For
example, we may be handling a node restart rule for multiple machines at
once, each of which may be in a different phase of operation.

In order to deal with the issue of multiple rules needing access to the same
event, we must change the CEP design to ensure that the same event is delivered
to all interested rules (rather than the first `match`).

In order to deal with out-of-order messages, we propose altering the receive
semantics of a rule to allow it to consume and buffer *all* events in which it
may subsequently be interested. This would be a separate step to actually
consuming the message for use. Buffering should be configurable by rule;
for example, one rule might require a 5-minute buffer on events in which
it is interested, whereas another may simply desire the last 5 events of a
requisite type. By moving the buffering to the rule level, rather than globally,
we can support this flexible concept of history.

Since we now have multiple local state machines running at once, we must do
one of two things: implement a means of task switching between the multiple
running processes (see for example
http://citeseerx.ist.psu.edu/viewdoc/summary?doi=10.1.1.39.8039), or use
Haskell's multithreading support and alter the resource graph to support
concurrent access.

Given the buffering of messages by state machines, we would need either to
support persisting that buffer or altering the semantics of the EQ to support
more than the simple 'ack' process we have now.

Since we are now buffering all messages per rule, we may immediately discard
any message which is not handled by a rule. This solves the issue of our
needing to deal with unhandled messages.

State machines must all support timeout, which must be triggered automatically.
This is used to guarantee that all rules terminate after some fixed time in the
event of message loss or compound failures.


#### Example Rule

We give the following example rule in a pseudo-syntax for the 'node restart'
scenario above:

```Haskell
define "node-restart" $ do

  want (Proxy :: Proxy HostRestartRequest)
  want (Proxy :: Proxy HostPoweringDown)
  want (Proxy :: Proxy HostPoweringUp)

  softSSPLRestart <- phaseHandle "soft-sspl-restart"
  softDirectRestart <- phaseHandle "soft-direct-restart"
  hardRestart <- phaseHandle "hard-restart"
  failure <- phaseHandle "failure"
  success <- phaseHandle "success"

  setPhase softSSPL $ match \(HostRestartRequest host) ->
    when (getHostStatus host /= "restarting") $ fork NoBuffer $ do
      set host
      setHostStatus "restarting" host
      nodes <- nodesOnHost host
            >>= filterM (\nid -> isServiceRunning nid "sspl")
      case nodes of
        n:_ -> sendSystemdRequest RestartNode n
            >> switch [success, timeout (5 * min) softDirectRestart]
        _ -> continue softDirectRestart

  setPhase softDirectRestart $ directly $ do
    host <- get
    nodes <- nodesOnHost host
    case nodes of
      n:_ -> shellRestart n
          >> switch [success, (timeout (5 * min) hardRestart)]
      _ -> continue hardRestart

  setPhase hardRestart $ directly $ do
    host <- get
    ipmiRestart host
    switch [success, timeout (5*min) failure]

  setPhase success $ matchSequentialIf
    \(HostPoweringDown host1, HostPoweringUp host2) ->
      get >>= \host -> return $ host == host1 == host2
    \(HostPoweringDown host1, HostPoweringUp host2) -> do
      host <- get
      setHostStatus "online" host

  setPhase failure $ directly $ get >>= promulgate . HostRestartFailed

  start softSSPL
```

This aims to draw out the following points:

1. Local state (we store the hostname between stages)
2. A continuation based approach - each time we call 'continue' we temporarily
   'park' the state machine until it is woken by one of the provided
   continuation states.
3. The use of `switch` to allow alternative paths based on which messages
   arrive; the first branch to 'commit' by changing phase will be committed.
4. The use of `want`: each call to `want` or one of its derivatives must
   register the event type for interest such that these get delivered
   and buffered by the state machine even if it is not currently in an accepting
   state.
5. More complex triggers - for example, in this case we require for `success`
   that we see an event notifying of the host powering down followed by an
   event notifying the host coming up.
6. The use of `timeout t action`. This should resolve to firing `action` after
   the specified timeout.
7. The use of `fork` to fork the state machine after processing the first
   part of the rule.

#### Interpretation

For an example interpretation, consider that we have the following:

```
type SM a = SM Rule Phase Buffer a
```
e.g. a State Machine is a rule in a current phase, with a buffer of events
and some state `a`. The RC shall (approximately) consist of a set of state
machines, along with a map instructing which messages are `want`-ed by
which state machines.
```
type RC = [SM, (forall a. Typeable a => Map (Proxy a) Rule)]
```

We consider that the above rule is the only rule implemented, and give an
approximate interpretation of its execution.

```
wantMap =
rcInitial = [SM "node-restart" softSSPL [] undefined
            , Map ( NodeRestartRequest -> "node-restart"
                  , HostPoweringDown -> "node-restart"
                  , HostPoweringUp -> "node-restart"
                  )]
```
The initial recovery co-ordinator consists of a single state machine in its
first phase, with no messages in the buffer and some undefined state.

Now let us suppose that a `NodeRestartRequest node1` message arrives. The type
of message is looked up in the map, and the state machine(s) corresponding to
that rule are looked up and run. The execution of the state machine takes three
steps:

1. Add the message to the buffer.
2. Execute the next step of the state machine.
3. Return some number of new state machines to continue running.

Since the first step forks, it executes the phase but also forks a copy of the
phase as is. Since we specify `NoBuffer`, the forked copy does not share a
buffer with the original.

Suppose that SSPL is running. Then we send a request to restart using SSPL,
and use `switch` to potentially branch the computation. So the RC after this
first event looks like the following:

```
rc1 = [ SM "node-restart"
            (Switch [success, timeout (5 * min) softDirectRestart])
            [NodeRestartRequest node1]
            node1
      , SM "node-restart" softSSPL [] undefined
      ]
```

We now have two state machines for the same rule; one has received an event
and is waiting on the next phase. Both `success` and `timeout ....` are
currently suspending, since their `match` clauses are not satisfied.

Now suppose a second `HostRestartRequest node2` arrives. This is delivered
to all relevant state machines, as expected, and added to both their buffers.
However, our first state machine is not waiting for such a message, and does
not act upon it. Our second state machine is ready to await such a thing, and so
does. In this case, there is no Halon `Node` running on `Host node2`, and hence
we jump through `softDirectRestart` and into `hardRestart`

```
rc2 = [ SM "node-restart"
            (Switch [success, timeout (5 * min) softDirectRestart])
            [NodeRestartRequest node1, NodeRestartRequest node2]
            node1
      , SM "node-restart"
            (Switch [success, timeout (5*min) failure])
            [NodeRestartRequest node2]
            node2
      , SM "node-restart" softSSPL [] undefined
      ]
```

Note that since the second state machine called `fork`, we again have a machine
in initial phase waiting for `NodeRestartRequest`s.

Now suppose that five minutes has passed since the initial SM called `timeout`.
An ephemeral Timer process sends a `Timeout` to the RC, which is passed to the
relevant SM. Let us suppose that the system is clever enough to not buffer
`Timeout` messages! This causes the `timeout` branch to succeed and continue
processing. The next step (`softDirectRestart`) does not wait for a message
(it has `directly` instead of a `match` clause), so immediately runs to its next
instruction. So our rc now looks like the following:

```
rc3 = [ SM "node-restart"
            (Switch [success, (timeout (5 * min) hardRestart)])
            [NodeRestartRequest node1, NodeRestartRequest node2]
            node1
      , SM "node-restart"
            (Switch [success, timeout (5*min) failure])
            [NodeRestartRequest node2]
            node2
      , SM "node-restart" softSSPL [] undefined
      ]
```

Now suppose our command to do a soft direct restart was partially successful,
and we receive a `NodePoweringDown node1` message to the RC. This is buffered
at all SMs, but ignored in all cases. The last two SMs are not waiting for this
message, and the first SM is waiting for this and another message, and so does
not pass its `matchSequential` clause. So we are not much altered:

```
rc4 = [ SM "node-restart"
            (Switch [success, (timeout (5 * min) hardRestart)])
            [ NodeRestartRequest node1, NodeRestartRequest node2
            , NodePoweringDown node1
            ]
            node1
      , SM "node-restart"
            (Switch [success, timeout (5*min) failure])
            [NodeRestartRequest node2, NodePoweringDown node1]
            node2
      , SM "node-restart" softSSPL [NodePoweringDown node1] undefined
      ]
```

Finally, notification of the node powering up arrives in the form of a
`NodePoweringUp node1` message. This is delivered to all buffers and acted
upon by the first SM. Since its buffer now consists of

```
[ NodeRestartRequest node1, NodeRestartRequest node2
, NodePoweringDown node1 , NodePoweringUp node1
]
```

,the `matchSequentialIf` clause is satisfied, and so the rest of the phase
is executed. This phase does not end in a `continue` or `switch` instruction,
and so processing of this state machine ends. So we have the following:

```
rc5 = [ SM "node-restart"
            (Switch [success, timeout (5*min) failure])
            [ NodeRestartRequest node2
            , NodePoweringDown node1
            , NodePoweringUp node1]
            node2
      , SM "node-restart" softSSPL  [ NodePoweringDown node1
                                    , NodePoweringUp node1] undefined
      ]
```
The first state machine is completed and has been removed from the list;
others remain in a waiting state for new events.

#### Tasks

1. (Optional) Implement concurrent (STM-like) access to the resource graph.
   This should support non-blocking reads of the graph, and blocking
   transactional writes.

2. Implement basic syntax for local state machines. This would require
   the implementation of, approximately, `match`, `continue` and `mkRule` from
   the above example. For an initial implementation, `match` could read
   directly from the appropriate channel or mailbox.

3. Implementing a persistent store for local state machines. State should
   consist of a continuation `CEP LocalState ()` and a `LocalState`. These
   should be persisted whenever `continue` is called.

4. Registration of all possible events. For example, `match` would now have
   to declare a set of interested events and expose this to `mkRule`. `mkRule`
   would be responsible for buffering any important events until they are
   consumed by the second half of `match`, which would read out of this buffer.

5. (Optional) Use the EQ for the buffer mentioned above, rather than buffering
   locally. When an event arrives at the RC, it is proferred to all running
   state machines. Each one increments an 'interested' counter in the EQ. When
   each machine has processed an event (at the end of that 'phase'),
   the counter should be decremented. When the counter on an event reaches 0,
   it should be trimmed from the EQ.

6. Implement `timeout`.

7. Modify CEP/the RC to send events to all interested consumers, rather than
   the first.


