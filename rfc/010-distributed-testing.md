# RFC: Distributed testing infrastructure

## Introduction

This document aims to define the most important aspects of a framework for
testing Halon and its components in a distributed setup (running on more than a
single machine) and proposes ways to implement such an infrastructure.

## Purpose

Since Halon is a distributed system, testing and benchmarking it in distributed
setup is necessary to have confidence in its functionality and to have a good
understanding of its performance. Moreover, making the development of Halon more
test driven can make the common understanding of the goals more clear and
development more focused. Therefore, a good framework for defining distributed
tests and benchmarks is vitally important.

## Constraints

There are many different aspects that make a testing infrastructure good or
bad. The following list is probably incomplete:

* Versatility. The framework should make it possible (and easy) to define the
  full range of tests that we would want to implement. For this, a number of
  use-cases should be defined and kept in mind while designing and implementing
  it. (I used the tests defined in the "Halon Autumn 2014 requirement" document
  and a simple distributed benchmarking use-case as the basis of my
  design. --Mihaly)

* Maintainability. Written tests should be easy to understand and maintain. This
  requirement is two-fold: the test scaffolding should not unnecessarily
  obscure the essence of the test. Secondly, the test infrastructure should be
  simple (easy to understand and follow).

* Documenting power. Although it is not the primary _goal_ of tests, good tests
  also serve as a documentation for the interface of the system they are
  testing. Mostly this translates to the same kind of requirements as the
  previous point (maintainability), but not completely.  It also means that
  tests should be relatively easy to understand for someone who is not a primary
  developer of the system. (In case of Halon's distributed integration tests this
  points against implementing them in Haskell; rather, they should be described
  in something that is more broadly understood.)

* Flexible support of distributed setups. Halon is going to be tested in at
  least two different distributed environments: Digital Ocean and on Xyratex
  clusters. Therefore, the framework should be flexible/abstract enough to
  support at least these two and potentially more.

## Description

Before describing the proposal in details, I need to tackle an issue which is
not strictly part of testing, but is still intimately tied to it.

### Building binaries for testing

Currently, Halon doesn't prescribe any specific environment for development.
Which is nice, as developers are free to choose any setup they are familiar and
comfortable with. But, this poses an additional requirement for distributed
testing: the binaries to be tested has to be built in the "cloud", as the
binaries built on the developers' machines might not run there. Even though we
only need to concentrate on one architecture (linux, x86_64), the
incompatibilities between distributions and basic libraries (think libc and
libgmp) would often preclude a Haskell binary built on one machine from running
on another.

Therefore, the testing infrastructure would need to have a facility to "upload"
the developer's checked out working copy to one of the machines where the
testing will be done. (Carefully avoiding any build artifacts in the working
copy, as those tend to be relatively big and thus slow to upload.) And compile
the code there.

This means that the images that we use for testing should be customized to
contain a GHC and everything that is needed to compile Halon. And, to avoid the
process being painfully slow, the GHC should contain a large preinstalled set of
libraries that are needed, or there needs to be a backed up sandbox ready to be
used for Halon build.

Keeping these system images up-to-date is, of course, an additional maintenance
burden. Which should be properly automated and documented. (This is outside the
scope of the current document.)

Alternatively, if Nix is adopted in some form for building Halon, it would
dissolve this issue too: the binaries built would be distro-independent and
compatible across machines. This is an additional advantage of Nix over the
properly hermetic and efficient builds.

The form/degree to which Nix is adopted can be varied from the whole build
system being replaced by a Nix-based one, to only GHC (and the non-vendor part
of the sandbox) being provided by Nix and the build system staying basically
unchanged.  (This later model is basically what I currently use.)  The
portability of binaries across machines would work with either.

Also, using Nix would probably greatly simplify the maintenance of the system
images.

### Testing framework proposal

My proposal is to structure the testing around a collection of simple
standardized (within the Halon project) shell based tools.

Basically, to create a small set of "verbs", which are implemented as bash
scripts (some generic, some dependent on the "cloud provider") and express the
tests in term of those verbs. Let me demonstrate this by an example:

``` bash
provisionMachines 5

buildBinaries halon/halond halon/halontest

extendProfile 'replicas=$ip1:3900,$ip2:3900,$ip3:3900'

launchOn 1,2,3 'halond replica $ip:3900 $replicas'
launchOn 4,5 'halond satelite $ip:4001 $replicas'

waitOn 4 'halontest $ip:4001 something | fgrep -q IsOn'
expectOn 5 'service.*Other' 'halontest $ip:4001 queryServices'

pause "Before killing 1st replica"

killOn 1 halond
expectOn 5 '...' ...
```

The above would constitute the entirety of a test, which could be run with
something like `test-distributed/digital-ocean test` or
`test-distributed/xyretex test`.

Let's consider a few details here:

1. The setup presupposes a lot of "standardization". It is achieved by the test
   drivers setting up a test directory, environment variables, PATH, etc., and
   running the test script in this rich "environment".

2. The `provisionMachines` does the heavy-lifting of issuing appropriate
   requests to the cloud provider (creating droplets), waiting till the machines
   are up, and populating them with a similar environment.

3. Machines are referred by their ordinal numbers; their parameters (like
   internal/external ip addresses) are available in environment variables.

4. All the necessary meta information about the machines is stored in the test
   directory, and cleanup is automatically performed after the test script
   finishes (so there is no explicit cleanup in the test script).

5. `buildBinaries` does the heavy-lifting of transferring the code to, say by
   convention, first test machine, building it there and distributing the
   necessary binaries to all of the test machines.

6. Hooks for debugging: The `pause` in the example facilitates
   developing/debugging test scripts. It just drops the developer into a shell
   set up with the same test environment where he can use the same verbs (and
   probably some additional convenience verbs, like `login 3`).

   The test environment should be simple and discoverable enough that this can
   also be done just by looking around in it (and sourcing the "profile").

Some implementation details.

* Other than the two heavy-lifting verbs, all other verbs correspond to simple
  shell commands run on different machines.

* To make running a lot of remote commands very efficient, we set up a local ssh
  config in the test environment and use ssh's `ControlPersist` and
  co. functionality. (This makes ssh keep the connections open in the background
  and multiplex several ssh commands to the same host over the same connection.
  Making it virtually overhead free. Disadvantage: it assumes that modern ssh
  will be available on all "cloud providers".)

* For interfacing with Digital Ocean I would suggest using one of the existing
  command line utilities. If none of the existing tools are appropriate, factor
  out Facundo's code and use that.

## Discussion

In this section I will discuss my rationale behind some design decisions.

### Why shell?

My main reason for promoting a shell-based solution is the "documentation"
requirement. Bash language is expressive enough that for not overly complex
things and if used carefully (not over-abused) it is a better way of documenting
"a series of steps". Secondly, I think the nature of this task makes it easier
to implement it in bash (that's what bash was "optimized" for) than in Haskell.

That said, I think it's perfectly viable to implement basically this program in
Haskell. And the result would actually be more expressive. But it would take
more time and effort, and the simpler shell is probably sufficient for the task.

A word of caution, though. Shell based solutions tend to get increasingly more
complex over their lifetime and can become unmanageable. In this case I would
resist the urge to "patch" it with perl or python (or ruby; depending on age and
world-view of a given developer :)), but would switch at that point to a fully
Haskell-based solution.

### Drive the test with Cloud Haskell?

We considered a very different architecture for distributed testing, where after
provisioning the machines and copying the binaries we launch one binary on every
machine and communicate with them from the tester's machine and drive the tests
completely with Cloud Haskell.

There are a few theoretical draw-backs of this approach: it makes it easier to
let the tests "mix" with the code being tested (and testing the implementation
rather than the interface). And it's much worse at documenting.

But apart from theoretical deficiencies, this has also some practical
deficiencies: cloud haskell requires that the same binary is run on all
machines, and we already discussed that this is not quite possible. (Of course,
this wouldn't be a problem for the current Cloud Haskell implementation, but it
would be an issue if static values were actual pointers.)  Also, consider a
use-case when we want to test Halon with Mero-RPC used as transport, then we
definitely cannot communicate with it from our machines.

This idea is salvageable; we could run the test driver in the cloud too. But,
based on these reasons I decided against this approach.


## More test examples

```Haskell
----------------------------
--
-- Configuration management API test:
--
-- Deploy 2 node cluster with 1 tracking station node and 1 satellite.
-- 
-- Store a configuration file specifying that two dummy services should be
-- started on the satellite, along with a dummy configuration parameter for
-- each service.
-- 
-- With the tracking station already running, turn on satellite.
-- 
-- Test that 2 services are running on satellite.
-----------------------------
-- 
-- Assumption: the binaries for the cloud platform are available.


-- @withMachines@ is the only cloud provider-specific call in this test. 
-- It provides the IP addresses of spawned machines as Strings.
withMachines 2 $ \[m0, m1] -> do

-- Takes pairs of consecutive elements to determine what to copy where.
copyEverywhereFrom BUILD_HOST
    [ ("dist/build/halon-node-agent/halon-node-agent", "halon-node-agent")
    , ("dist/build/halon-station/halon-station", "halon-station")
    , ("scripts", "scripts")
    ]

-- produce genders file and any other required files for the current cluster
runEverywhere ("scripts/mk_config --station_nodes=" ++ m0 ++ " --sattelites=" ++ m1)

-- copy the configuration specifying to add two services in a sattelite
copyTo m0 "tests/configrationAPI/localconfiguration" "localConfiguration"

-- start the node agent
getLine_m0 <- spawnIn m0 "scripts/halon node-agent"
Just "ready" <- getLine_m0

-- start the tracking station
runIn m0 "scripts/halon station"

-- start the node agent in the satellite
getLine_m1 <- spawnIn m1 "scripts/halon node-agent"

-- test for creation of services
-- or provide a halon-specific command-line tool to list the services on a node
Just "spawned dummy service one" <- getLine_m1
Just "spawned dummy service two" <- getLine_m1



----------------------------
--
-- Configuration management API, another test:
--
-- Deploy 2 node cluster with 1 tracking station node and 1 satellite.
--
-- Store a configuration file specifying that two dummy services should be
-- started on the satellite, along with a dummy configuration parameter for
-- each service.
--
-- With cluster in steady state (all services are up), send reconfiguration
-- request to one tracking station node.
--
-- Test that both services are running on satellite after reconfiguration.
--
----------------------------

withMachines $ \[m0, m1] -> do

copyEverywhereFrom BUILD_HOST
    [ ("dist/build/halon-node-agent/halon-node-agent", "halon-node-agent")
    , ("dist/build/halon-station/halon-station", "halon-station")
    , ("scripts", "scripts")
    ]

-- produce genders file and any other required files for the current cluster
runEverywhere ("scripts/mk_config --station_nodes=" ++ m0 ++ " --sattelites=" ++ m1)

-- copy the configuration specifying to add two services in a sattelite
-- with a dummy configuration parameter
copyTo m0 "tests/configrationAPI/localconfiguration" "localConfiguration"

-- start the node agent in all nodes
getLine_ms <- spawnEverywhere "scripts/halon node-agent"
[Just "ready", Just "ready"] <- sequence getLine_ms

-- start the tracking station
runIn m0 "scripts/halon station"

-- test for creation of services in the satellite
-- or provide a halon-specific command-line tool to list the services on a node
Just "spawned dummy service one" <- getLine_ms !! 1
Just "spawned dummy service two" <- getLine_ms !! 1

-- Now we assume the cluster is in steady state.
-- Reconfigure.
runIn m1 "scripts/halon reconfigure ... ?"

-- test that the services were reconfigured
-- or provide a halon-specific command-line tool to list the services and
-- their configuration on a node
Just "spawned dummy service one with configuration: ..." <- getLine_ms !! 1
Just "spawned dummy service two with configuration: ..." <- getLine_ms !! 1
```
