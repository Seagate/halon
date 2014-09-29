# Complex Event Processing: High-Level Design

## Introduction

CEP is a framework for writing complex event processors, i.e.
distributed components that can accept input events and produce output
events based on some computation potentially involving a history of
past events or other local state.

## Definitions

Process
:   A self-contained task that may receive or send messages.

(τ) event
:   A typed message (of type τ) indicating an occurrence somewhere on
    the network.

(τ) event producer
:   A process that may produce events (of type τ).

(τ) event consumer
:   A process that accepts events (of type τ).

Complex event
:   An event formed by the aggregation or analysis of multiple other
    events.

(Complex event) processor
:   A process that gathers events from a variety of event producers and
    combines them intelligently to produce output events, i.e. a
    generalization of both event producer and event consumer.


## Requirements

The requirements for CEP are defined in terms of its motivation,
Halon, a system for maintaining high availability of clusters in
high-performance computing environments.

[fr.composition]
:   Halon processes should be directly composable at both the intra- and
    inter-node level.

[fr.typing]
:   The language in which processes are written should be strongly
    typed, and statically forbid connecting components of mismatched
    types.

[fr.device-join]
:   Halon should detect and make use of new storage added to the
    network.

[fr.device-failure]
:   Halon should detect and initiate recovery from device failures.

[fr.node-join]
:   Halon should detect and configure a node newly joined to the
    network.

[fr.node-failure]
:   Halon should detect and initiate recovery from node failures.

[fr.logging]
:   Halon should log all failures and repair operations.

[fr.composite-failure]
:   Halon should diagnose and summarize complex failure events signalled
    by multiple errors.


## Quality Attributes

+ Responsiveness
+ Composability
+ Scalability
+ Availability

## Quality Attribute Scenarios

  ------------------- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
  [Tag]               qas.responsiveness.device
  Scenario            Halon should be able to rapidly trigger repair for failed devices.
  Attribute           responsiveness
  Attribute Concern   Data repair
  Stimulus            A number of errors from a device indicate that the device is no longer reliable.
  Stimulus Producer   Device
  Environment         The device is connected to a node, which is in turn able to access the tracking station.
  Artifact            Halon
  Response            A copy machine will be constructed for the lost data.
  Response Measure    The time between the device reporting its failure and the message being sent to begin construction of the copy machine should be drawn from a normal distribution with µ = 0.1 s and σ ≤ 0.3 s.
  ------------------- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

  ------------------- -------------------------------------------------------------------------------------------------------------
  [Tag]               qas.composability.node
  Scenario            Halon should be composed of a set of independent actors on nodes that function independent of other actors.
  Attribute           composability
  Attribute Concern   Adding nodes
  Stimulus            Wishes to add new nodes to the pool
  Stimulus Producer   System administrator
  Environment         A running SNS cluster.
  Artifact            Halon
  Response            The system administrator connects the new node, which begins participating in the system.
  Response Measure    The administrator does not need to alter any other nodes.
  ------------------- -------------------------------------------------------------------------------------------------------------

  ------------------- ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
  [Tag]               qas.scalability.local-repair
  Scenario            In the case where a node already has sufficient information locally to recover from a failure, the node should not require input from any external producer, ensuring that such cases put minimal load on the rest of the cluster.
  Attribute           scalability
  Attribute Concern   Data repair
  Stimulus            A failure occurs for whose correction all the necessary redundancy information is available locally.
  Stimulus Producer   Device
  Environment         A running node with connected devices, the remaining of which contain sufficient information to reconstruct the failed.
  Artifact            Node
  Response            The node constructs a local copy machine, without recourse to data found elsewhere, and reconstructs the data.
  Response Measure    The node does not need to consult data stored on any other nodes.
  ------------------- ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

  ------------------- -----------------------------------------------------------------------------------------------------------------------------------------
  [Tag]               qas.composability.circuit
  Scenario            The software on a node should be composed of recombinable circuits, and should itself be amenable to combination with other components.
  Attribute           composability
  Attribute Concern   Modification of code
  Stimulus            Wishes to make changes to the event-processing logic
  Stimulus Producer   Developer
  Environment         An SNS cluster
  Artifact            CEP framework
  Response            The developer composes a new circuit from existing components.
  Response Measure    The developer can directly incorporate existing circuits into the new circuit.
  ------------------- -----------------------------------------------------------------------------------------------------------------------------------------

  ------------------- ---------------------------------------------------------------------------
  [Tag]               qas.availability
  Scenario            Halon should be available to handle a vast majority of events.
  Attribute           availability
  Attribute Concern   Handling events
  Stimulus            An event occurs
  Stimulus Producer   Device or node
  Environment         A running SNS cluster
  Artifact            CEP framework
  Response            The event is registered and handled appropriately according to the logic.
  Response Measure    No more than one in ten thousand events should be dropped on average.
  ------------------- ---------------------------------------------------------------------------



## Design Highlights

+ The core `cep` package managing transport of events has relatively
  few dependencies, and is designed to be extended with a high-level
  event handling abstraction of choice, thereby smoothly extending
  that abstraction to process events across multiple distributed
  nodes.

+ On top of the `cep` package is built the `cep-sodium` package,
  providing a high-level interface based on the [Sodium][sodium]
  functional reactive programming library, to which actual logic
  is delegated.

+ We can't use broadcasting in an HPC environment, so CEP uses a
  pre-known set of broker processes to relay publish/subscribe
  requests between event processors.

+ Events are categorized by their (Haskell) type, using the existing
  `Serializable` machinery made available by Cloud Haskell, so events
  are type-checked and the types can be omitted where inferrable,
  getting the Haskell type inferrer to do the work.

## Functional Specification

### Communication

When an event producer wishes to emit an event, it must notify every
subscriber of which it is aware.  Therefore, processors keep a local
mapping

    EventType → Set ProcessId

indicating which processors have subscribed to which events (that the
processor publishes).  This mapping is updated when the processor
receives a `SubscribeRequest` or `NodeRemoval` event.

### Brokers

Processors interested in receiving events need to subscribe to the
processors that provide those events, but there is a bootstrapping
problem here, since one side needs to be able to find the other in
order to talk to it.  Brokers solve this problem.  A broker is a very
simple process whose address is known in advance to all processors in
the cluster.  Subscription requests for τ events are sent to all the
brokers of which the processor is aware; the brokers are responsible
for forwarding the message on to all τ-event producers.

In order to register as a τ-event producer, a processor may also send
the broker a τ publish request, which should result in the broker
forwarding the processor every τ subscription request from consumers it
believes to be live.

As an optimization, brokers also know about a node removal event,
which they can use to prune their state of dead processors if
informed.

### Processing

The core of a processor is written using Sodium, a functional reactive
programming library.  Sodium provides an abstraction for composable
event processing, including manipulation of streams of discrete events
and also continuous behaviours that can be updated based upon those
events.

## Logical Specification

The CEP implementation is split into two layers.

`cep`
:   The `cep` package comprises the core of CEP and encompasses all the
    technologies necessary to write processors and brokers.

`cep-sodium`
:   The `cep-sodium` package is a friendly and composable API for
    building processors, based on the Sodium FRP package.


## Interfaces

### `cep`

#### Types

````
type NetworkMessage a

payload ∷ Lens' (NetworkMessage a) a
producer  ∷ Lens' (NetworkMessage a) ProcessId

type SubscribeRequest
type PublishRequest
type NodeRemoval
type BrokerReconf
````

Types are important in CEP.  As Haskell types are used to classify
event types, this module implicitly defines the *protocol* used to
communicate between processors and brokers, at the infrastructure
level.

All CEP events, at the library- or user-level, are automatically
wrapped in `NetworkMessage` on sending.  `NetworkMessage a` represents
a message of type `a` tagged with metadata about the message, such as
its producer, which can be accessed through the lenses exported here.

The remaining four types represent various infrastructure events:
respectively,

+ A processor wishes to register as an event consumer;
+ A processor wishes to register as an event producer;
+ A processor no longer exists on the network;
+ The set of available brokers has changed.

#### Broker

````
type Broker = ProcessId

broker ∷ Process ()
````

A broker process; see [Brokers](#brokers).  For now there is only one
module implementing this interface, but there may be more at a future
time.

#### Processor

````
type Processor s a
type Config
type ProcessorState

Config          ∷ [Broker] → Config
runProcessor    ∷ Transport → Config → (∀ s. Processor s ()) → IO ()
onExit          ∷ Processor s () → Processor s ()
getProcessorPid ∷ Processor s ProcessId
````

Each processor is run in a single instance of the `Processor` monad,
using `runProcessor`, which has a phantom session parameter `s`.  This
ensures that messages cannot be sent when their recipient is in the
wrong state (e.g. emitting an event when the broker does not have the
processor registered as a publisher of that event, so the event will
be silently lost).  Calls to `runProcessor` will set up the processing
callbacks according to the parameter, and then begin processing events
in an endless loop — that is, `runProcessor` *will not return* in
common usage, and should be forked if further processing is necessary.

Since calls to `runProcessor` do not terminate, the value returned
from the monadic value passed into `runProcessor` is *discarded*, not
returned, and therefore it is not possible to return a value out of
`runProcessor`.

`getProcessorPid` will produce the Cloud Haskell `ProcessId` used to
communicate with the outside world, which may not be the same as the
current processor's `ProcessId` found with `liftProcess getSelfPid`.

#### Callback Interface

````
publish   ∷ Serializable a ⇒ Processor s (a → Processor s ())
subscribe ∷ Serializable a
          ⇒ (NetworkMessage a → Processor s ()) → Processor s ()
````

An interface should implement these two functions to allow publishing
of and subscription to event types.  Note that it is the event *type*
that is published, not the event itself: publishing an event type
informs the broker and simultaneously returns a callback that can be
used to emit an event of that type.

### `cep-sodium`

````
publish      ∷ Serializable a ⇒ Event a → Processor s ()
subscribe    ∷ Serializable a ⇒ Processor s (Event (NetworkMessage a))

liftReactive ∷ Reactive a → Processor s a
dieOn        ∷ Event a → Processor s ()
````

Confusingly, the name ‘event’ is used in FRP terminology for event
*producers*, so `Event a` here refers (unlike elsewhere in the CEP
framework) not to a single event but to a whole stream of potential
events.

In addition to the `publish`/`subscribe` functions, two additional
functions are provided here.  The first merely allows Sodium
`Reactive` code to be embedded into a processor's logic.  The second
can be used to trigger processor termination on the first occurrence
of an event, which is used in the `TemperatureRandom` example as we
must dynamically create and destroy nodes.  It is not anticipated that
this function will be useful in practice.

The usual structure of a processor written with Sodium is to subscribe
to one or more inputs, then use the bound names to produce one or more
output `Event`s, which are then published.  That is,

````
someProcessor ∷ Processor s ()
someProcessor = do
  evt₀ ← subscribe
  evt₁ ← subscribe
  …

  publish <=< liftReactive $ do
    produceEvent₁ evt₀ evt₁ …
  publish <=< liftReactive $ do
    produceEvent₂ evt₀ evt₁ …
  …
````

`Processor` is an instance of `MonadIO`, so `IO` actions can be used
to set up further local inputs.  For example, many interesting
operations require a clock-time producer, which can be produced in `IO`
(using a utility function `timeLoop` from the `sodium-utils` package):

````
timeProcessor ∷ Processor s ()
timeProcessor = do
  (time, pushTime) ← liftReactive newEvent
  now              ← getCurrentTime >>= sync . flip hold time
  liftIO . forkIO . timeLoop 0.05 . const $
    getCurrentTime >>= sync . pushTime

  …
````

## Conformance

[fr.composition]
:   Sodium provides composability of event-processing mechanisms, even
    across sampling rates [2]; the CEP framework extends this capability
    across the network for discrete events.

[fr.typing]
:   Our implementation language is Haskell, which has a strong typing
    discipline; Sodium forbids local composition of components with
    mismatched types, and the CEP framework requires received messages
    to have the expected type before processing begins.

[fr.device-join]
:   A device can notify all interested parties of new devices as an
    event, allowing them to make immediate use of it.

[fr.device-failure]
:   Simple and complex failures of devices can be diagnosed by
    supervisors or the nodes themselves, and can then be communicated to
    interested nodes to begin recovery.

[fr.node-join]
:   A newly joined processor can notify the brokers and other interested
    parties of its presence, allowing them to make use of it.

[fr.node-failure]
:   As [fr.device-failure], but diagnosis requires a supervisor process.

[fr.logging]
:   All events are sent to all interested parties; a logging processor
    can easily be constructed that listens for and records all events of
    interest.

[fr.composite-failure]
:   The FRP formalism we have used is capable of making decisions based
    on input from multiple producers, arbitrarily far into the past.




## Use Cases

+--------------------------------------+--------------------------------------+
| [Tag]                                | ucs.transient.block                  |
+--------------------------------------+--------------------------------------+
| Description                          | A failure occurs at the device on    |
|                                      | reading/writing a block.             |
+--------------------------------------+--------------------------------------+
| References                           | HLD [1] §4.1                         |
+--------------------------------------+--------------------------------------+
| Actors                               | -   Node                             |
|                                      | -   Device                           |
|                                      | -   Tracking station                 |
+--------------------------------------+--------------------------------------+
| Prerequisites & Assumptions          | -   The node is connected to the     |
|                                      |     device.                          |
|                                      | -   The tracking station is          |
|                                      |     available to the node.           |
+--------------------------------------+--------------------------------------+
| Steps                                | 1.  The node attempts to perform IO  |
|                                      |     on the device.                   |
|                                      | 2.  The device reports an IO error   |
|                                      |     to the node.                     |
|                                      | 3.  The node reports the error to    |
|                                      |     the tracking station, including  |
|                                      |     its identity, the identity of    |
|                                      |     the affected device, and the     |
|                                      |     nature of the error.             |
|                                      | 4.  The node retries the IO          |
|                                      |     operation.                       |
+--------------------------------------+--------------------------------------+
| Variations                           | Rather than the device reporting an  |
|                                      | error, another health-monitoring     |
|                                      | layer may detect a problem with the  |
|                                      | retrieved data, e.g. failure to      |
|                                      | checksum or decrypt.                 |
+--------------------------------------+--------------------------------------+
| Quality Attributes                   | availability, reliability            |
+--------------------------------------+--------------------------------------+
| Issues                               |                                      |
+--------------------------------------+--------------------------------------+


+--------------------------------------+--------------------------------------+
| [Tag]                                | ucs.transient.device                 |
+--------------------------------------+--------------------------------------+
| Description                          | A node tries to communicate with a   |
|                                      | device, but fails.                   |
+--------------------------------------+--------------------------------------+
| References                           | HLD [1] §4.1                         |
+--------------------------------------+--------------------------------------+
| Actors                               | -   Node                             |
|                                      | -   Device                           |
|                                      | -   Tracking station                 |
+--------------------------------------+--------------------------------------+
| Prerequisites & Assumptions          | The tracking station is available to |
|                                      | the node.                            |
+--------------------------------------+--------------------------------------+
| Steps                                | 1.  The node attempts to read or     |
|                                      |     write data.                      |
|                                      | 2.  The device does not respond      |
|                                      |     within t milliseconds.           |
|                                      | 3.  The node reports the failure to  |
|                                      |     the tracking station.            |
|                                      | 4.  The node attempts to perform the |
|                                      |     operation again.                 |
+--------------------------------------+--------------------------------------+
| Variations                           |                                      |
+--------------------------------------+--------------------------------------+
| Quality Attributes                   | availability                         |
+--------------------------------------+--------------------------------------+
| Issues                               | -   What are appropriate values for  |
|                                      |     t?                               |
+--------------------------------------+--------------------------------------+

+--------------------------------------+--------------------------------------+
| [Tag]                                | ucs.transient.node                   |
+--------------------------------------+--------------------------------------+
| Description                          | A node fails to contact another      |
|                                      | node.                                |
+--------------------------------------+--------------------------------------+
| References                           | HLD [1] §4.1                         |
+--------------------------------------+--------------------------------------+
| Actors                               | -   Node A                           |
|                                      | -   Node B                           |
|                                      | -   Tracking station                 |
+--------------------------------------+--------------------------------------+
| Prerequisites & Assumptions          | The tracking station is available to |
|                                      | node A.                              |
+--------------------------------------+--------------------------------------+
| Steps                                | 1.  Node A attempts to contact node  |
|                                      |     B.                               |
|                                      | 2.  Node B does not respond within t |
|                                      |     milliseconds.                    |
|                                      | 3.  Node A reports the failure to    |
|                                      |     the tracking station.            |
|                                      | 4.  Node A attempts to contact node  |
|                                      |     B again.                         |
+--------------------------------------+--------------------------------------+
| Variations                           |                                      |
+--------------------------------------+--------------------------------------+
| Quality Attributes                   | availability                         |
+--------------------------------------+--------------------------------------+
| Issues                               | -   What are appropriate values for  |
|                                      |     t?                               |
+--------------------------------------+--------------------------------------+

+--------------------------------------+--------------------------------------+
| [Tag]                                | ucs.permanent.device                 |
+--------------------------------------+--------------------------------------+
| Description                          | A device issues a type or volume of  |
|                                      | errors that indicates that it is no  |
|                                      | longer reliable.                     |
+--------------------------------------+--------------------------------------+
| References                           | HLD [1] §4.9                         |
+--------------------------------------+--------------------------------------+
| Actors                               | -   Node                             |
|                                      | -   Tracking station                 |
+--------------------------------------+--------------------------------------+
| Prerequisites & Assumptions          | -   The node is connected to the     |
|                                      |     affected device.                 |
|                                      | -   There is a path between the node |
|                                      |     and the tracking station.        |
+--------------------------------------+--------------------------------------+
| Steps                                | 1.  The tracking station receives    |
|                                      |     more than n device errors from a |
|                                      |     given device within t            |
|                                      |     milliseconds.                    |
|                                      | 2.  The tracking station indicates   |
|                                      |     that the node should stop        |
|                                      |     retrying the device.             |
|                                      | 3.  The tracking station broadcasts  |
|                                      |     the device’s removal from the    |
|                                      |     network.                         |
+--------------------------------------+--------------------------------------+
| Variations                           | There are a variety of device errors |
|                                      | that can render a device unusable,   |
|                                      | including corrupted data, persistent |
|                                      | read/write IO failures, and          |
|                                      | connection errors.                   |
+--------------------------------------+--------------------------------------+
| Quality Attributes                   | availability, reliability            |
+--------------------------------------+--------------------------------------+
| Issues                               | -   What are appropriate values for  |
|                                      |     n and t?                         |
|                                      | -   The number or type of error that |
|                                      |     indicates a catastrophic failure |
|                                      |     will vary depending on the       |
|                                      |     drive.                           |
|                                      | -   Perhaps attach the tolerances    |
|                                      |     for the device to the failure    |
|                                      |     events themselves? This saves us |
|                                      |     some state.                      |
+--------------------------------------+--------------------------------------+

+--------------------------------------+--------------------------------------+
| [Tag]                                | ucs.permanent.connection             |
+--------------------------------------+--------------------------------------+
| Description                          | A node is persistently incapable of  |
|                                      | accessing another node.              |
+--------------------------------------+--------------------------------------+
| References                           |                                      |
+--------------------------------------+--------------------------------------+
| Actors                               | -   Node A                           |
|                                      | -   Node B                           |
|                                      | -   Tracking station                 |
+--------------------------------------+--------------------------------------+
| Prerequisites & Assumptions          | The tracking station is available to |
|                                      | node A.                              |
+--------------------------------------+--------------------------------------+
| Steps                                | 1.  The tracking station receives n  |
|                                      |     connection errors from node A    |
|                                      |     relating to node B within t      |
|                                      |     milliseconds.                    |
|                                      | 2.  The tracking station requests    |
|                                      |     that a number of other nodes     |
|                                      |     also ping node B.                |
+--------------------------------------+--------------------------------------+
| Variations                           |                                      |
+--------------------------------------+--------------------------------------+
| Quality Attributes                   | availability                         |
+--------------------------------------+--------------------------------------+
| Issues                               | -   What are appropriate values for  |
|                                      |     n and t?                         |
+--------------------------------------+--------------------------------------+

+--------------------------------------+--------------------------------------+
| [Tag]                                | ucs.permanent.node                   |
+--------------------------------------+--------------------------------------+
| Description                          | A node is no longer available to     |
|                                      | multiple nodes on the network.       |
+--------------------------------------+--------------------------------------+
| References                           | HLD [1] §4.9                         |
+--------------------------------------+--------------------------------------+
| Actors                               | -   Tracking station                 |
|                                      | -   Target node                      |
|                                      | -   Other nodes                      |
+--------------------------------------+--------------------------------------+
| Prerequisites & Assumptions          | The tracking node is available to    |
|                                      | most nodes in the cluster.           |
+--------------------------------------+--------------------------------------+
| Steps                                | 1.  The tracking station receives m  |
|                                      |     connection errors each from n    |
|                                      |     nodes in t milliseconds.         |
|                                      | 2.  The tracking station invokes     |
|                                      |     Repair to remove all the devices |
|                                      |     attached to the affected node    |
|                                      |     from all intersecting layouts on |
|                                      |     the cluster, rebuilding from     |
|                                      |     redundancy if necessary.         |
|                                      | 3.  The tracking station broadcasts  |
|                                      |     the removal of each of the       |
|                                      |     devices attached to the node.    |
|                                      | 4.  The tracking station broadcasts  |
|                                      |     the removal of the node from the |
|                                      |     cluster.                         |
+--------------------------------------+--------------------------------------+
| Variations                           |                                      |
+--------------------------------------+--------------------------------------+
| Quality Attributes                   | availability                         |
+--------------------------------------+--------------------------------------+
| Issues                               | -   What are appropriate values for  |
|                                      |     m, n, and t?                     |
+--------------------------------------+--------------------------------------+

+--------------------------------------+--------------------------------------+
| [Tag]                                | ucs.permanent.local                  |
+--------------------------------------+--------------------------------------+
| Description                          | Failure occurs locally and should be |
|                                      | handled locally.                     |
+--------------------------------------+--------------------------------------+
| References                           |                                      |
+--------------------------------------+--------------------------------------+
| Actors                               | -   Node                             |
|                                      | -   Tracking station                 |
+--------------------------------------+--------------------------------------+
| Prerequisites & Assumptions          | The node is connected to the         |
|                                      | tracking station.                    |
+--------------------------------------+--------------------------------------+
| Steps                                | 1.  The node diagnoses a failure     |
|                                      |     that can be fixed with only      |
|                                      |     locally-available information.   |
|                                      | 2.  The node reports the failure to  |
|                                      |     the tracking station, indicating |
|                                      |     that it intends to fix the       |
|                                      |     failure.                         |
|                                      | 3.  The node fixes the failure       |
|                                      |     locally.                         |
|                                      | 4.  The node reports the fix to the  |
|                                      |     tracking station.                |
+--------------------------------------+--------------------------------------+
| Variations                           | There are a variety of operations    |
|                                      | that can be fixed locally, such as   |
|                                      | disk controllers needing to be reset |
|                                      | (triggered by a number of errors     |
|                                      | from disks on the same controller)   |
|                                      | or data being lost that can be       |
|                                      | reconstructed entirely from local    |
|                                      | redundancy data.                     |
+--------------------------------------+--------------------------------------+
| Quality Attributes                   | scalability, responsiveness          |
+--------------------------------------+--------------------------------------+
| Issues                               |                                      |
+--------------------------------------+--------------------------------------+

+--------------------------------------+--------------------------------------+
| [Tag]                                | ucs.node-join                        |
+--------------------------------------+--------------------------------------+
| Description                          | A new node joins the network and     |
|                                      | should have its events handled.      |
+--------------------------------------+--------------------------------------+
| References                           |                                      |
+--------------------------------------+--------------------------------------+
| Actors                               | -   Node                             |
|                                      | -   Other nodes                      |
|                                      | -   Tracking station                 |
+--------------------------------------+--------------------------------------+
| Prerequisites & Assumptions          | The tracking station is available    |
|                                      | from the pool.                       |
+--------------------------------------+--------------------------------------+
| Steps                                | 1.  The node is connected to the     |
|                                      |     pool.                            |
|                                      | 2.  The node broadcasts its presence |
|                                      |     to the other nodes.              |
|                                      | 3.  The other nodes begin tracking   |
|                                      |     its events.                      |
+--------------------------------------+--------------------------------------+
| Variations                           | Devices can also be added to a node, |
|                                      | with similar effects.                |
+--------------------------------------+--------------------------------------+
| Quality Attributes                   | scalability, composability,          |
|                                      | responsiveness                       |
+--------------------------------------+--------------------------------------+
| Issues                               |                                      |
+--------------------------------------+--------------------------------------+



## References

1. Hua, Huang and Danilov, Nikita. "High Level Design of SNS
   Repair". Internal document. (2012).
2. Elliott, Conal. "Push-pull functional reactive
   programming". Haskell Symposium. (2009).

[repair-hld]: https://docs.google.com/a/tweag.io/file/d/0B-mqorebq7hKZHJKd3FsQXFncEFfbzRweGR6X2RKMEF5T1pv/edit
              "HLD of SNS Repair, version 2.0"
[push-pull]:  http://conal.net/papers/push-pull-frp/
              "Push-pull functional reactive programming"

[sodium]:     https://hackage.haskell.org/package/sodium "Hackage: sodium"
