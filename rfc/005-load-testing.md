# Load Testing

## Introduction

The title of this RFC is "Load testing", but the subject of it is more
generally performance testing of a distributed service.

I will use Replicated Log as the example service, but most of the
observations apply generally.

## Purpose

Measuring the performance of a service is critical for creating an
efficient distributed service. We cannot improve something if we
cannot measure it.

Load-testing is also important for operating a distributed service. We
need to know the range of parameters, under which the service performs
well, to manage the capacity of the service. And we need to know how
the service behaves when we leave the safe range to install the
necessary protection measures.

## Constraints

* Load-testing should provide meaningful data to satisfy the two
  purposes: direct the efficiency improvement work, and establish the
  safe operating range of the system

* Load-testing should be "cheap". It should be easy and fast to
  run. Ideally, it should be part of the continuous integration
  ecosystem.

## Description

### What do we measure

There are two related, but different things that are important to
measure in a distributed service.

1. Performance under regular circumstances. It's easy to underestimate
   the importance of this. If we want to understand how the service
   will perform, we have to measure in circumstances as close to
   "real" conditions as possible.

   In case of replicated log this means that, if we are going to run
   5 replicas on 5 different boxes with 100 clients talking to the
   service, each performing 0.01 queries per second (QPS), then this
   is how we should test the system. Preferably, we should do so with
   a mix of traffic similar to real (read/write dominated etc). Even
   if 1 QPS of aggregate load seems trivial.

   The reason for this maxim is that distributed systems are complex
   and it's hard to guess which part of the complexity have how big of
   an effect.

2. Range of acceptable performance. We usually want to understand how
   far can we push the system. How many clients/connections/QPS can it
   support without the performance degrading? When the performance
   starts to degrade how does it degrade? Gracefully, or suddenly and
   abruptly collapsing under load?

   Understanding this is important to know if/how to protect the
   system against adversary conditions. Pushing the system to the
   limit also tends to uncover more bugs. :)

In practice points #1 and #2 don't have to be clearly separated. We
might not have a precise idea of "regular circumstances", but if load
testing shows that the system performs well in a broad range of
parameters, that definitively covers everything we might want, that
might be enough.

#### What are the important parameters to measure?

So, if the maximum throughput of the system is not the important
parameter, what is the important things to measure? The most important
parameter is the end-to-end latency, ie. the time elapsed from the
client sending the request to receiving an answer (including all the
necessary redirections, retries and all).  When measuring latency we
want to see that the mean latency is low and the shape of the latency
distribution is "good". The later mostly means that latency doesn't
have a long tail (eg. 99th percentile is close to the mean), but we
should look out for other issues too. For example a bimodal latency
distribution is not a problem per se, but might be an indication of a
deeper problem.

#### How does a good scaling look like?

While this doesn't strictly belong here, it good to understand this,
because:
 * You'll know how to present the result of a load-test in the most
   useful way.
 * You'll know what to look at in the results of a load-test. Or even
   if the "results" show you enough of the story.

Imagine the system performing normally. We have a few client sending
requests to it (possibly of a different mix or at a different rate...)
The system performs well, ie. requests a processed and answered
reliably and timely. Now imagine that we start cranking up the load:
we have more-and-more clients, or the clients sending requests at
higher-and-higher rates (or both).

A perfect (in terms of scalability/degradation) system responds in the
following way:

* until the limit of the system is reached the request are answered at
  the same speed (the latency distribution is unaffected).

  * after the limit is reached it slows down, obviously, but in a way
  that maintains _a constant rate of requests_. That is, it doesn't
  take more and more time to process _one_ request just because there
  are more of them.

  Additionally, the system "pushes back" on the clients fairly. (The
  nature of the push-back depends on the nature of communication. If
  the communication is synchronous, it usually means the requests are
  answered more slowly. If the communication is asynchronous, it
  usually means that requests are dropped.) What fair means is for
  system designers to decide: it might mean uniform push-back on all
  clients or on all requests. But, for example, ignoring all, but the
  "loudest" clients (those who send the most requests) is probably bad
  in all situations. Or, a different example, for a system that drops
  requests under load: processing the old, queued-up requests and
  dropping the most recent ones is probably very bad: the system's
  state becomes obsolete and it's very slow to recover from a load
  spike.

So, for a good system a load-test graph shows a constant latency
increasing gradually after some point and a linearly rising QPS
graph that stays flat after that point.

Bad behaviors on the other hand, are: suddenly increasing latency
tail, significant drop in QPS, significant differences for different
clients etc.

### How to measure

There are several conflicting requirements here. On the one hand we
want to cover a broad range of conditions, but on the other hand the
load-test should be easy to run and shouldn't take too long. Otherwise
it won't be used (or hurt productivity, or both).

I suggest the following infrastructure:

* A load test coordinator that spawns the server processes and a few
  clients;

* instructs the clients to maintain a constant load for a short period
  of time (few seconds) and collect measurements, receives and
  aggregates the measurements from the clients;

* in relatively big steps cover a broad range of loads;

* do a few extreme measurements, eg. all the clients going as fast as
  they can; one (or all) clients dumping a lot of requests
  asynchronously (to measure how the system deals with queue
  build-up).

Possibility to simulate network delays and run a "benchmark" on
a laptop is very important, but should be taken with a grain of salt.
Care should be taken to only delay messages between processes on
different nodes, but not processes withing the same node.

The maxim #1 (that we should test as close to reality as possible)
also apply to code. The code that we measure should be as close to
real as possible. Ideally, the system that we test should be run in
the same way as the production system. If that's not possibly (it
might be an overkill because of complexity of setting it up), I
suggest the following:

* Write the client and the server code _separately_ from the
  benchmark/load-test code;

* the server code should be completely clean, and not very "toy";

* the client code should come with the ability to plug in some
  instrumentation, but otherwise look like a client code (that sends
  a relatively sensible mixture of randomly generated requests).

Client instrumentation could look something like:

``` haskell
client :: (forall a. String -> Process a -> Process a) -> Process ()
client measure = do something

measureNoop :: String -> Process a -> Process a
measureNoop tag op = op

measureReal :: String -> Process a -> Process a
measureReal = something
```

and wrap with `measure tag` all the "send request, wait for reply"
parts. With tags that identify the kinds of requests (read, write,
write_big, etc.)

### Who measures the measurer (aka. effects of the instrumentation on performance)

Measurement always have an effect on the thing being measured.
Quantifying this effect is not always easy. One potential way of
addressing this issue -- is to not address it at all.

Make the instrumentation for measurement unobtrusive enough that you
can just always write the code together with the instrumentation. And
leave the instrumentation in. That is, collect performance statistics
in the production code too. This can actually turn into a valuable
source of information about performance improvements/regressions if we
make these easy to collect.
