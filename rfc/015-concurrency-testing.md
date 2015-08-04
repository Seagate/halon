# RFC: Concurrency testing

## Introduction

Testing concurrent applications requires testing a relevant subset of the
possible interleavings.

So far we have been using distributed-process-scheduler as the mean to control
the order in which messages arrive and the order in which processes are
interleaved.

This document explains some directions in which d-p-scheduler could be improved.

## Constraints

The following list expresses some features of an ideal system for testing
concurrency.

* **Coverage report** It should be possible to assess how many classes of
  interleavings in the application have been visited. A class contains multiple
  interleavings which are similar in some sense to the tester, and we want to
  know if at least one of these interleavings was executed.

* **Systematic search** It should be possible to test systematically the
  possible interleavings by spreading the search over the whole search space.

* **Genericity** The approach should work with distributed-process but must be
  possible to use to test in other settings.

* **Modularity** The approach should allow to break down testing by module,
  rather than requiring all the dependencies to be the target of testing as
  well.

* **Timeouts** It should be possible to test behavior which depends on time.

* **Reproducibility** A failing test should be possible to reproduce.

## Description

### Modularity

Currently d-p-scheduler is hardwired to schedule processes that use the d-p
primitives. This makes it difficult to test a module which sits higher up in
the stack without testing the lower layers as well.

One approach to make this more flexible, is to separate the scheduling of
processes from the scheduling of message arrivals into separate subcomponents.
Some other component would have to coordinate them, but this would allow to
treat message arrival as a kind of environment that delivers events in various
possible orderings. This environment abstraction would enable modeling upper
layers too (e.g. consensus or replicated state machines) without having to
track the scheduling of all their internals when testing layers on top.

### Genericity

The solution to modularity might allow to use the scheduler in other settings
than d-p. The message-arrival environment depends on it. And the scheduling of
processes depends on some means to identify processes and get notified of their
lifetime.

Providing replacements for these things (e.g. `ThreadId` instead of `ProcessId`)
and a suitable environment (e.g. for `MVar` primitives), the rest of the
scheduler scaffolding could be reused.

### Timeouts

Let's say we want to test a leader election algorithm that relies on time
leases. This requires some coherence in the order in which timeouts are
triggered. If a process acquires the lease and the other processes timeout too
soon, then they will interfere with the leader before the end of the lease.

Thus, whatever the approach, timeouts need to be ordered and triggered not
before they are expired with respect to some logical clock.

The scheduler could be made parametric on the speed of the clock. After timeouts
expire, the scheduler is free to run a timeout handler or to ignore the timeout
for a while. Provided that the clock speed is not too fast, the application is
expected to complete execution.

Also, the scheduler could run tests with different clock speeds which should be
greater than a user-specified lower bound.

### Coverage report

Randomly choosing interleavings to test may increase the covered interleavings,
but may still be far from rehearsing many interesting possibilities.

Getting an idea of how well the tests cover the search space requires defining
what an interesting interleaving (a class) is, and then keeping track
of what classes were visited as they accumulate.

If an interleaving is defined as a list of pairs of process identifiers and
program fragments between preemption points, the simplest way to define the
class of an interleaving is as the singleton set containing the interleaving.

A blunt alternative is to define the class of an interleaving:

```Haskell
type Interleaving = [(ProcessId, ProgamFragment)]

classOf :: Interleaving -> [Interleaving]
classOf i = filter (((==) `on` removeCycles) i) allInterleavings
```

Here `removeCycles` can be regarded as a function that eliminates from an
interleaving any repetition of subsequences. e.g.:

```Haskell
removeCycles "aaabbbccc" = "abc"
removeCycles "abcabc" = "abc"
removeCycles "aaabbbcccabc" = "abc"
```

Another way to define classes is to consider interleavings in the same class as
another if they exchange the positions of elements which do not have a causal
relation. That is, `ab` is in the same class as `ba` if information produced by
executing `a` does not influence `b` and viceversa. For this to be determined,
it could be approximated by collecting runtime information about the flow of
information. Exact knowledge seems to require static analysis.

Estimating the total amount of classes can be done by observing the size of the
alphabet during testing (i.e. how many different ProcessId-ProgramFragments
pairs are found) and having the user describe somehow the impossible (or the
possible) interleavings.

Another problem to solve is how to indetify program fragments. d-p-scheduler
could provide some primitive for that, or some scheme based on the source code
file and line they start or finish on.

### Systematic search

Randomly selected interleavings are likely to progress slowly towards reaching
complete coverage. They will cluster around some probable set of interleavings
and neglect the rest.

A systematic search would ensure that executed interleavings spread more
reasonably over the search space. The scheduler could return a description of
the interleaving it executed and the possible variations. On the next run one of
the variations would be fed back to it, and it would provide another
description of the newly discovered variations.

The dumb approach is to do backtracking without any analysis to select the next
variation. As an interleaving may be inifinite due to unfair scheduling,
backtracking could be constrained to run interleavings of bounded length.

Reaching good coverage without running a lot of interleavings depends on doing
some intelligent choice of the order in which to feed interleaving variations
as they are discovered.
