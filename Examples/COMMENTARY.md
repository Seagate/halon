# Packet 3: complex event processing

## Synopsis

An embedded domain specific language (EDSL) and supporting engine for
tracking and analyzing (processing) streams of events and deriving a
conclusion from them. Complex event processing (CEP) combines data
from multiple sources to infer events or patterns and take appropriate
action as quickly as possible. For the needs of RAS, this EDSL can be
made cross language and available from Python.  The aim of the Complex
Event Processing API is to provide a composable and extensible
interface to processing streamed data about the status of the nodes in
a High Availability cluster.

## Role

The Mero recovery coordinator must implement policies that are
inherently dynamic and depend on temporal conditions defined in terms
of external events such as timeout notifications, software crashes,
faulty hardware, network partitions and RAS policy updates. The
proposed EDSL is a framework within which to conveniently implement
the Mero recovery coordinator as declaratively as possible, by means
of composing circuits of processes into larger and arbitrarily complex
circuits for intelligent processing of sometimes seemingly unrelated
but simultaneous events. This EDSL is reactive, because cluster
configuration and recovery policies change over time and very quick
processing of events is of the essence for achieving the highest
levels of availability.

Factoring out the event processing necessary for Mero into a
principled framework is an enabling ingredient to leverage some of the
same machinery for another component that also performs complex event
processing: RAS.

The processors built using this EDSL maintain state across event
histories. This state will be replicated across several "supernodes"
across the cluster using the "state replicator" component in Packet 2,
so that processors can be restarted anywhere else in the cluster upon
failure, without any noticeable downtime.

## Discussion

The sheer size of clusters at exascale, involving millions of hardware
parts and several orders of magnitude more software threads, means
that manual decision making and intervention by operators is nigh
impossible. But more importantly, there cannot exist perfect fault
detectors, so that false negatives and false positives will be
legion. Even more importantly, faults are dependent, so that one fault
in the system may in fact be the symptom of some other root cause
(think node timeout vs network partitions). The fact that extremely
high levels of availability can only be achieved if each fault is
recovered in a matter of seconds compounds the importance of
intelligent analysis of vast amounts of data, as opposed to having to
wait.

The finance industry has already been facing the problem of having to
take quick but intelligent automated decisions based on a substantial
amount of data. Traditional SQL databases don't scale, or incur
latencies that are too high for fast decision making. Therefore, a
handful of bespoke tools have been developed to address some of these
needs. But most are in-house, some are prohibitively expensive
(e.g. Oracle CEP, Streambase) and one (Esper) has open source
components that cannot ensure high availability and are tightly
tied to the Java ecosystem. Moreover these tools are complex to
program against: queries are performed in a custom SQL-like language
with a custom syntax, stream processors are not particularly
composable and they must be pieced together by authoring a number of
XML files that may or may not be dynamically reconfigurable with no
downtime.

Beyond their complexity, cost and relative unavailability, existing
CEP systems are moreover poorly integrated into programming
languages. This matter of fact further compounds complexity, much in
the same way that having to build raw SQL request strings
programmatically is error prone, a security hazard (SQL injections)
and inflexible.

However, there also exists much more lightweight and integrated
alternatives. A paradigm that originally emerged from the functional
programming community 20 years ago called functional reactive
programming (FRP) focuses precisely on the same problem space:
expressing efficient computations to analyze streams of data and
produce streams of commands. The difference is that FRP systems are
usually language specific libraries dressed up as embedded DSLs,
focusing on building computations compositionally from smaller
pieces. Compositionality is a crucial property in software design to
simplify reasoning about the correctness of the computations and
enhance maintainability. FRP has by now far exceeded the realm of
functional programming alone. There exist many dozens of libraries
for most popular programming languages, from Python to Javascript to
C#. We propose to build our EDSL based on an existing design
already proven by Haskell FRP systems called Netwire and Nettle, the
latter currently applied to reactive network control and software
defined networking (SDN).

These are high performance libraries: Nettle has been used to build
McNettle, an SDN controller in Haskell that has been measured to
scale to 40+ cores and process 20M requests/s, hence being the fastest
SDN controller to date. Furthermore, programming against them in
Haskell does not require learning any additional languages and
benefits from strong static type checking, since all processors are
written in pure Haskell. An embedding of the library into another
language, e.g. Python, would likewise allow processors to be written
declaratively yet still purely within Python, with no mix of
languages.

## Functional specification

The Complex Event Processor is built by composing individual units
called "wires" into more sophisticated networks of wires.  It is an
example of the use of the Reactive approach to data processing
embedded in a functional language, that is "Functional Reactive
Programming" or "FRP".

Conceptually a "wire" represents a process that at any given time
contains some internal state.  It will receive a value on its input
channel, update its internal state and yield a value on its output
channel.  The notion of input and output "values" is very broad.  A
single value can itself consist of tuples or record types of multiple
values thus allowing a wire to effectively input and output many
values at once.  Inputs and outputs can be both events, like the event
that "we received a timeout message about machine X", and observables
of the system, for example the current time, or a value containing the
most recent heartbeat from all machines.

Wires are composed either in series, by feeding the output of one wire
into the input of another wire, or in parallel by taking a pair of
inputs, feeding one into one wire, one into another, and collecting
their outputs as another pair.  The result of composing two wires is
another wire thus this API is an example of the ["flat design"
paradigm](http://www.haskellforall.com/2014/04/scalable-program-architectures.html)
which is recognised as an effective means of taming complexity and
promoting code reuse.

This ability to compose in parallel and series makes the wire datatype
an instance of Haskell's Arrow typeclass and so we can take advantage
of the arrow syntax and combinator libraries that Haskell provides for
working with Arrows.

## Logical specification

The `Wire` datatype is isomorphic to the the following Haskell newtype
declaration

    newtype Wire a b = Wire (\a -> (b, Wire a b))

This is essentially the approach taken by both the Netwire and Nettle
Haskell FRP libraries.

The time of the current tick is passed into the network explicitly as
an input observable.

### Representing events

Events, be they real-world events such as a node heartbeat, timeout
report or notice of a network partition, be they CEP administration
events such as the logging of a message, or be they output events such
as the instruction to reboot a node, can by their nature happen zero,
one or many times during each tick.  Thus we represent an event of
type `a` by the Haskell type of lists of `a`.  This is a slight
departure from the Netwire 5.0 and Nettle approach.  They both
represent events of type `a` by the Haskell type `Maybe a`, that is,
events may occur either zero or one times and they are unable to
process event types that may occur multiple times.  Since we may want,
for example, a log processor to process many log message events at
once we believe our approach is more appropriate here.

## Composability and code reuse

The benefit of implementing a reactive system as a domain-specific
language embedded inside a functional programming language is that we
can take advantage of all the benefits of composability and code reuse
that the functional programming language provides natively.  Haskell
is a pure and lazy language and these two features are widely regarded
as increasing the composability of code, even above and beyond the
level provided by superficially similar functional languages such as
OCaml.

One example of improved code reuse is in a reactive network component
for calculating the mean and variance of a observable that varies with
time.  The following code for `statistics` implements that component.
`statistics` is a `Wire` which takes a pair of inputs: the
time-varying value to calculate the statistics of, and the current
clock time.  It outputs a value of type `Statistics` which contains
both the mean and variance of the time-varying value.

Note that because `statistics` is a `Wire` it can be reused throughout
the code to calculate statistics for any number of different
time-varying observables.  This code sample also demonstrates reuse
itself.  The implementation of statistics reuses the reactive
components `stepSize` and `sum'` which respectively calculate the
difference in a time-varying value between two ticks of the network
and the sum of all time-varying values observed so far.

    statistics :: Wire (Double, ClockTime) Statistics
    statistics = proc (n, theTime) -> do
      dt <- stepSize -< theTime
      totalDeadTime <- sum' -< n * dt
      totalSquareDeadtime <- sum' -< (n ^ 2) * dt
    
      let avgDeadTime' = totalDeadTime / theTime
    
      returnA -< Statistics { avgDeadTime = avgDeadTime'
                            , varDeadTime = totalSquareDeadtime / theTime
                                            - (avgDeadTime' ^ 2) }


The definitive example of composability is the following demonstration
of a simplified, high-level model of the event flow through a reactive
network which processes messages from nodes in a high-availability
cluster.

In brief the implementation of `flow` proceeds by extracting the
events and the clock time from its input.  Then it calculates the most
recent heartbeat it has heard from each node and the most recent
timeout reports it has received about nodes from other nodes.  A
machine is considered dead if a heartbeat has not been heard in the
last 5 time units.  Then the network signals all nodes to be rebooted
that are either timed out or dead, except those machines that are
being rebooted already.  The dead machine statistics are also produced
and also a count of the number of heartbeats received in a given time
frame.

    flow :: Wire Input Output
    flow = proc input -> do
      let events' = eventsOfInput input
          heartbeats = (catMaybes . map heartbeatOfInput) events'
          timeouts = (catMaybes . map timeoutOfInput) events'
          theTime = clockTime input
    
      m <- mostRecentHeartbeat -< heartbeats
      h <- heartbeatsInLast 20 -< (heartbeats, theTime)
      t <- recentTimeouts -< (timeouts, theTime)
      let timedOutNodes = failuresOfReports t
    
      deadMachines <- noHeartbeatInLast 5 -< (m, theTime)
    
      let toReboot' = (timedOutNodes `union` deadMachines) \\ rebooting input
    
      statistics' <- statistics -< (fromIntegral (Set.size deadMachines), theTime)
    
      returnA -< Output { odied = deadMachines
                        , otimeouts = timedOutNodes
                        , ostatistics = statistics'
                        , toReboot = toReboot'
                        , recentHeartbeats = countHeartbeats h }

The benefit of implementing reactive systems in this fashion is that
our code can be structured in a highly modular fashion whilst taking
advantage of all the other features of our supporting programming
language, Haskell, too.


## Comparison of Netwire/Nettle approach with Reactive-Banana

Functional Reactive Programming is an approach to using functional
programming languages for implementing systems that process and
respond to streams of incoming events.  There are two successful and
popular FRP frameworks for Haskell, Netwire and Reactive-Banana.  The
Haskell Group at Yale has developed an FRP framework called "Nettle"
whose design is similar to Netwire.  In this section we summarise the
key differences between Netwire/Nettle approach and the
Reactive-Banana approach and highlight the drawback of Reactive-Banana
that led us to prefer a Netwire-inspired FRP framework design.

The API to Reactive-Banana is not based on arrows.  Instead reactive
networks are constructed by passing around and manipulating `Event`
and `Behavior` types as pure values, not wrapped in any datatype
providing the arrow, applicative or monad typeclass.

The reason that Reactive-Banana can avoid the arrow approach is
two-fold.

Firstly the networks that it creates are pure, whereas Netwire's
`Wire` type can have effects when it process an input (by contrast
nettle's equivalent of the `Wire` type, and the `Wire` type we propose
above, do *not* have effects).

Secondly Netwire and Nettle lean on the arrow abstraction as a means
of guaranteeing that "timeleaks" do not occur.  Timeleaks are an
adverse behavior whereby some networks of wires take much longer to
run than one might expect.  Reactive-Banana instead uses a phantom
type parameter to address this issue, in much the same way as
Haskell's [ST monad](http://www.haskell.org/haskellwiki/Monad/ST).  An
observable, or "behavior" of type `a` is thus represented by a type
`Behavior t a` where `t` is the phantom parameter.

A translation between Reactive-Banana's types and the `Wire` type
given above is as follows:

* An event that can occur zero or more times during any tick of the
  network is `Event t a` in Reactive-Banana and `Wire () [a]` in our
  approach.

* An observable of type `a` is `Behavior t a` in Reactive-Banana and
  `Wire () a` in our approach.


### The major drawback of Reactive-Banana

The major drawback of Reactive-Banana is that when the value of a
Behavior is updated by the occurrence of an Event, the new value of the
Behavior is not visible during the processing of the same Event.  For
example the `stepper` combinator updates the value of a `Behavior` to
be equal to the value of the `Event` that triggers the update:

    latestValue :: Behavior t a
    latestValue = stepper event

However, if we also use `event` to trigger reading from `latestValue`

    latestValueEvent :: Event t a
    latestValueEvent = latestValue <@ event

then `latestValueEvent` does not contain the same value that `event`
contains.  Instead it contains the *previous* value of `event`.  This
functionality of Reactive-Banana makes it easier to define `Behavior`s
recursively without creating infinite loops.  However it also leads to
unnecessary awkwardness when trying to understand data-flow through an
event-processing network, thus we recommend taking the approach of
Netwire's and Nettle here.

## Tasks

1. Design EDSL: produce high-level design documentation for all
   primitives of the language and any additional composition operators
   required.

2. Implement EDSL as an arrow API based on the Netwire/Nettle
   approach.

3. Test and validate fault tolerance of stream processors.

4. Performance testing and tuning: demonstrate that simple processor
   networks can process upwards of several hundreds of thousands of
   events every second.

5. Python bindings (optional, see Packet 5): it can be useful to embed
   the DSL not just into Haskell but also in Python if other
   components such as RAS are to also use stream processing as
   implemented here.
