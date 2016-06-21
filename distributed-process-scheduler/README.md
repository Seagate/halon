This is the source code distribution of distributed-process-scheduler, a package
that makes it possible to write reproducible randomized tests for programs using
the distributed-process package.

The goal of randomized tests is to show that concurrent algorithms yield correct
results in many possible interleavings of the concurrent steps. Moreover,
randomized tests provide a way to reproduce the executions which yield incorrect
results.

## Overview

If the processes in a cloud haskell application communicate with
each other exclusively through messages, this library offers a
scheduler that can be used to sequentialize delivery and processing
of messages in repeatable fashion (i.e. so executions are reproducible).

We loosely define an _execution_ as a list of state transitions in a system
composed of a set of processes. Each process has an internal state that is not
accessible to other processes. Communication happens only through exchanges
of messages.

A transition occurs on every occurrence of the following events:

  1. a message arrives to a process mailbox, or

  2. a process removes a message from its mailbox.

Executions are generated online as the algorithm runs. The processes of the
application send messages and eventually test for messages in their mailboxes.
There is a scheduler process that intercepts the messages and decides in which
order they arrive, and when processes should remove them from the mailbox.

Only one process is allowed to run at a time. When a process tests the mailbox,
it blocks until the scheduler signals that it can take a message. This way the
stream of events is kept deterministic, and can be reproduced by using the same
seed to initialize the random number generator that the scheduler uses to decide
among the multiple possible transitions.

The scheduler monitors creation and termination of processes. This allows
the scheduler to determine how many processes the application has and when
all of them are blocked waiting for a scheduler decision. Only when all
processes are blocked, the scheduler chooses the next transition requests.

## Building and installation

cabal install distributed-process-scheduler

## Testing with distributed-process-scheduler

The `distributed-process-scheduler` package is a wrapper around
`distributed-process`, so you have to use the functions and the type
signatures from the scheduler packages instead of the upstream DP.

Randomized tests and the user libraries they test should list
`distributed-process-scheduler` as a dependency rather than
`distributed-process`.

Once you've changed your `.cabal` files accordingly and recompiled
everything, you're able to enable the scheduler with setting the
`DP_SCHEDULER_ENABLED` environment variable to `1`.  By default, the
scheduler is disabled.

Suppose we have the following function which computes the sum of two natural
numbers.

```Haskell
addition :: Int -> Int -> Process Int
addition m n = do
   pid <- getSelfPid
  serverPid <- spawnLocal $ server m (n+1)
  replicateM_ n $ do
    receiveTimeout 1000 []
    spawnLocal $ do
      i <- readServer serverPid
      writeServer serverPid (i + 1)
      send pid ()
  replicateM_ n (expect :: Process ())
  readServer serverPid
```

The function starts by creating a "server" process which keeps an integer state.
This state is initialized with the value of the first parameter. The server is
also told to terminate after serving `n+1` read requests of the state.

Then the function creates as many processes as the second parameter indicates,
where each process will increase by one the state of server process.

When all the processes are done, the function reads and returns the state of the
server process.

The line featuring the call to `receiveTimeout` has the function wait between
spawning two processes, so they do not interfere with each other when reading
and writing the state. Of course, there is a race condition here where different
interleavings of the concurrent processes lead to different sums despite of the
delay. Execution in an unloaded machine yields the right result, but we expect
to hit the race condition by using the scheduler.

The implementation of the server and the state read and write primitives follow:

```Haskell
server :: Int -> Int -> Process ()
server _ 0 = return ()
server i n = do
  e <- expect
  case e of
    Left pid -> send pid i >> server i (n - 1)
    Right i' -> server i' n

readServer :: ProcessId -> Process Int
readServer serverPid = do
  self <- getSelfPid
  send serverPid (Left self :: Either ProcessId Int)
  expect

writeServer :: ProcessId -> Int -> Process ()
writeServer serverPid i =
  send serverPid (Right i :: Either ProcessId Int)
```

We write now a test for the `addition` function which uses the scheduler:

```Haskell
runTest :: Int -> Transport -> IO ()
runTest s tr = withScheduler s clockSpeed numNodes tr remoteTable $ \_ -> do
    let n = 2
    result <- addition n n
    liftIO $ do
      putStr $ if result == 2*n then "PASS" else "FAIL"
      putStrLn $ ": " ++ show s
  where
    clockSpeed :: Int
    clockSpeed = 10000

    numNodes :: Int
    numNodes = 1

    -- Don't forget to include the remote table from the scheduler
    remoteTable :: RemoteTable
    remoteTable = Control.Distributed.Process.Scheduler.__remoteTable
                  initRemoteTable

```

`runTest` takes a seed value that is used to initialize the scheduler.
Changing the seed value has the scheduler pick a different set of choices
whenever it reaches a branching point.

The `clockSpeed` argument indicates the speed of an internal virtual clock.
This clock is used to determine when timeouts have expired and it is ok to
execute their handlers. The virtual clock is accesible via
`distributed-process-scheduler:System.Clock`.

The argument `numNodes` indicates the amount of nodes to use in the test and
the arguments to create the nodes follow. The nodes are allocated by
`withScheduler` to make harder to hit some limitations regarding ordering of
node ids and destroying nodes. In short, the user is not allowed to create
other nodes for a test than those provided by `withScheduler`. See the section
on limitations below for the rationale.

The function `withScheduler` starts the scheduler and executes the closure
provided as argument, in our case this is our test. Whatever the test result
is, we always print the seed value. Since we are interested mostly in detecting
failures, we could as well just print it only when a failure occurs.

Now we write the main function which calls `runTest` with different seeds. We also
provide the list of imports for completeness.

```Haskell
import Control.Distributed.Process
  ( getSelfPid, spawnLocal, send, expect, liftIO, Process, ProcessId, kill
  , RemoteTable
  )
import Control.Distributed.Process.Scheduler ( withScheduler )
import qualified Control.Distributed.Process.Scheduler ( __remoteTable )
import Control.Distributed.Process.Node

import Control.Concurrent ( threadDelay )
import Control.Exception ( bracket )
import Control.Monad ( replicateM_, forM_ )
import Network.Transport ( closeTransport )
import Network.Transport.TCP
import System.Random ( mkStdGen, randoms )

main :: IO ()
main = withTCPTransport $ \tr ->
    forM_ (take 10 $ randoms $ mkStdGen 0) (runTest tr)

withTCPTransport :: (Transport -> IO ()) -> IO ()
withTCPTransport p =
  bracket
    (createTransport "127.0.0.1" "8080" defaultTCPParameters)
    (either (const (return ())) closeTransport)
    $ \(Right transport) -> p transport
```

We then set the DP_SCHEDULER_ENABLED variable with
`export DP_SCHEDULER_ENABLED=1` and run this program.
We get an output similar to what follows:

```
FAIL: -117157315039303149
FAIL: -8854136653200549331
FAIL: -2598893763451025729
PASS: -2104942133312634771
FAIL: -1118254845754885878
FAIL: 6972749008210911846
FAIL: -335309270675936609
FAIL: -3525632887272275069
FAIL: -3460092035149905767
FAIL: -8674267892396669880
```

It can be seen that most interleavings lead to incorrect results. Fortunately,
with the seed value, we can run `runTest` and reproduce the exact same
interleaving that caused a failure, where running the test without the
scheduler would hardly hit the race condition.

### Network failures

It is possible to simulate network failures during tests, to also test resilience
of an application.

`Control.Distributed.Process.Scheduler` offers the following interface
```Haskell
-- | Have messages between pairs of nodes drop with some probability.
--
-- @((n0, n1), p)@ indicates that messages from @n0@ to @n1@ should be
-- dropped with probability @p@.
addFailures :: [((NodeId, NodeId), Double)] -> Process ()

-- | Have messages between pairs of nodes never drop.
--
-- @(n0, n1)@ means that messages from @n0@ to @n1@ shouldn't be dropped
-- anymore.
removeFailures :: [(NodeId, NodeId)] -> Process ()
```

These functions can be called anywhere during the execution of a test.
To drop a message, a network failure is simulated, which causes monitor
notifications and link exceptions to be sent to all involved monitors.

A notable difference with a real execution of the application is that monitor
notifications are produced immediately. In a real network, the monitor
notifications would be produced with some transport-dependent delay after
messages start being dropped.

## Limitations

The scheduler can handle many primitives of `distributed-process` but not all.
Support for this primitives is added as needed.

Non-supported primitives are not exported by `Control.Distributed.Process` in
`distributed-process-scheduler`.

### Other synchronization primitives

Processes are expected to synchronize exclusively through `distributed-process`
primitives. Should you need to use locks, `MVars` or whatever, processes cannot
block on them without blocking execution of the whole program. The scheduler
learns that a process is about to block when it calls one of the primitives for
receiving messages (e.g. the wrapped `expect`, `receiveWait`, etc). If the
process blocks otherwise, the scheduler will think the process is still running,
and it will never activate another process.

This is possible to circumvent sometimes. Consider a couple of processes that
intend to communicate with an MVar. The following is a simplified version of
`callLocal` from `distributed-process` which does not deal with exceptinos.

```Haskell
-- | Runs a computation in a newly spawned process.
--
-- Note the absence of a `Serializable` constraint.
callLocal :: Process a -> Process a
callLocal p = do
    mv <- liftIO newEmptyMVar
    (sp, rp) <- newChan
    spawnLocal $ do
      when schedulerIsEnabled $ sendChan sp ()
      p >>= liftIO . putMVar mv

    when schedulerIsEnabled $ receiveChan rp
    liftIO $ takeMVar mv
```

Here `callLocal` is using an `MVar` to pass the result from the worker
process to the caller process. When the scheduler is enabled, the caller does
not block on the `MVar`, but it blocks instead on a call to `receiveChan` that
the scheduler will notice.

`schedulerIsEnabled` is a constant exported by
`distributed-process-scheduler:Control.Distributed.Process.Scheduler` that
indicates whether the scheduler is enabled. Thus, blocking on the MVar is
allowed when the scheduler is not enabled.

### Ordering of NodeIds

Another limitation involves NodeIds. NodeIds are sorted lexicographically by the
scheduler. A consistent order of the nodes used in tests is important to
reproduce the test with the same seed regardless of the state of the transport.
The order of node identifiers must be uniquely determined by the order in which
nodes start interacting with the scheduler.

Unfortunately, the lexicographic order of node identifiers can violate this
constraint, as transports do not necessarily create node ids in lexicographic
order. One workaround is to make sure the transport is always in the same state
when `withScheduler` is evaluated (e.g. the transport was just created). Another
workaround is to make sure that for the range of node identifiers that the test
uses, the node identifiers always end up sorted in the same way (e.g. if the
identifier is just an integer, then all identifiers use the same amount of
digits and the transport produces them in sequence).

The approach that `withScheduler` uses is to always sort the nodes by NodeId,
before passing the list to the application. This works well at the expense of
requiring all nodes to be created upfront, and the application shouldn't scan
`NodeId`s to drive its behavior.

### Other limitations

Nodes used in a test cannot be destroyed until the test completes. The scheduler
might try to interact with the nodes if some process sends a message to them.
But if the node is dead and therefore unable to reply to registry queries, for
instance, then the scheduler might block.

`spawnLocal` inherits the masking state but the spawned thread can still be
interrupted before executing it. This needs to be fixed.

`matchSTM` might produce incorrect behavior if there is more than one consumer
for the same transactional resource (e.g. multiple processes trying to read the
same `TChan` with `matchSTM`).

`send` is treated the same as `usend` in the presence of (simulated) network
failures. This needs to be fixed.

## Finding a bug

A failing test may either report a failure or block. There might be a bug in
the application, but first it could save some time considering if the
application is using unsupported synchronization primitives or if communication
between processes occurs by other means than sending messages.

If a test fails with a given seed, a first thing to check is whether the test
fails always with the given seed. If the test exectutes twice in sequence, the
first execution is successful and the next fails, this could be indicating that
the first execution is not releasing some resources that the second needs.

Calls to `liftIO $ threadDelay t` should be replaced with calls to
`receiveTimeout t []`. The scheduler can fast-forward the time to an interesting
event when using `receiveTimeout` and the system is still. On the contrary,
`threadDelay` will have the scheduler delay until the delayed thread wakes up,
and this could cause a test to fail and to take longer to complete.

Usually tests should use `withScheduler` to create nodes and start an initial
process. Having a process use `liftIO . runProcess n` explicitly can cause
execution to block. However, `forkProcess` is safe to use and
`liftIO. runProcess n` can be simulated with a combination of `forkProcess n`
and typed channels.

Since the scheduler does not provide any tracing capabilities, the
application code has to be instrumeted to report what is happening during
a particular execution. The package distributed-process offers a tracing
mechanism documented in the module `Control.Distributed.Process.Debug`.
