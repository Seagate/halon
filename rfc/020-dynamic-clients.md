## RFC: Dynamic clients

## Introduction

Currently the complete cluster configuration must be specified ahead of time in
the `halon_facts.yaml` file. Whilst this is fine for the initial deployment,
we ultimately need to support adding and removing clients on an already
operating system. This RFC covers the means by which we might perform such an
operation.

There is a separate proposal being addressed internally to Mero which covers
support for clients which are not added to the configuration database. This
RFC is explicitly about how to support adding these to the configuration
database in runtime. We find that support for both of these forms of dynamic
clients will be useful.

## Definitions

* Client - a `m0t1fs` or `clovis` process which reads/writes data to the
  Mero filesystem.

* Unmanaged client/ unmanaged process - a client for which Halon will not be in
  charge of starting/stopping the processes. It may start/stop of its own accord
  at any point (though this may fail if the cluster is not ready). If it fails,
  Halon is not responsible for restarting it or recovery in any way.

* Host - a physical machine with a halond process running which forms part of
  the resource graph and may run Halon services.

* Mero host - a host which has a corresponding `M0.Node` instance in the
  resource graph and may run Mero processes.

## Constraints

* Multiple clients may sometimes run on a single host.

* Some clients may need to be subsequently controlled by Halon (e.g. s3server),
  while others are likely to be ephemeral and will be controlled externally
  to Halon.

## Scope

There are three possible scenarios in which we might add a new client:

1. Adding a new client to an existing host which is already running Mero
   processes.

2. Adding a new client to a host already known to the system but which is not
   currently host to any Mero processes.

3. Adding a new client on a completely new host to the system.

These can alternately be seen as three separate steps:

1. Adding a new host to a system.

1. Registering a host as a Mero host.

1. Adding a new client to a Mero host.

This document covers all of the above scenarios.

## Requirements

We recap the necessary information for each of the given steps:

### Adding a new host to the system

```
  h_fqdn :: String
-- ^ Fully-qualified domain name.
, h_interfaces :: [Interface]
-- ^ Network interfaces
, h_memsize :: Word32
-- ^ Memory in MB
, h_cpucount :: Word32
-- ^ Number of CPUs
, _hs_address :: String
  -- ^ Address on which Halon should listen on, including port. e.g.
  -- @10.0.2.15:9000@.
, _hs_roles :: [RoleSpec]
```

Some of this information is provided by `NodeUp`, if Halon is started and
bootstrapped as a satellite on a node. In particular, the FQDN and Halon
address are provided.

### Registering a host as a Mero host.

Current Mero host configuration requires the set of roles and devices. We may
see an 'empty' host as one with no roles. For clients, there is no possible
use for devices. As such, this section is effectively unneeded for clients.

```
  _uhost_m0h_roles :: [RoleSpec]
, _uhost_m0h_devices :: [M0Device]
```

### Adding a new client to a Mero host.

Currently adding a new client is a case of specifying a role name.

## Design

Since the requirements for each of the above operations are so different, we
propose quite different solutions for each of them.

### Adding a new host to the system

Currently, interface data includes tags to specify which network, data or
management, the interface was on. This was used to derive addresses for Halon
and Mero endpoints. However, this information is no longer used, since these
are specified explicitly in the roles file. With the exception of this
information, all other data can be theoretically gathered by halond on the node.

As such, we propose removing the requirement to specify `Data` or `Management`
in the interface section, and removing all but the `roles` section from the
host configuration in the Halon facts file. All further information would be
moved into being gathered satellite start, and would be sent in `NodeUp`.

As such, any node connected to the system would automatically have all the
necessary information to constitute a host, whether added at initial cluster
definition or subsequently. We would also remove some information which needs
to be specified in the facts file.

Since the term 'satellite' is now somewhat confusing (being a superset of the
station nodes), we would additionally suggest dropping the term satellite and
renaming this command something like `bootstrap node`. We would additionally
propose an option (or similar command) to remove the node from the cluster
(see section on removal below).

### Registering a host as a Mero host.

Since becoming a Mero host is, as discussed above, tied to whether any Mero
processes are running on that host, we propose performing this automatically
and lazily when anyone attempts to start a Mero process on a node. Since all
nodes now have all required information, owing to it being gathered
automatically by Halon, there is nothing to ensure before we attempt to add a
process to a host.

### Adding a Mero process to a host.

Adding a process to a host is the most tricky operation here. We need to
consider in particular the following:

* There may be multiple processes with the same role on a given node.

* Some roles correspond to more than one process.

* Some processes may be unmanaged.

As such, we propose the following:

1. Introduce a new field into the process section of the Mero role mappings:
   `m0p_multiplicity`. This will specify how many instances of a process to run.
   If not present, this should be inferred as 1. If present, this may either be
   set to a given value in the role mapping file, or may be set to a special
   value `{{multiplicity}}`, which can be controlled via the
   `rolespec_overrides`. This allows certain components (such as s3server) to
   allow the number of instances required to be controlled by the client.

1. Since we may now have multiple instances of the same process in a role
   running on a given node, either via multiplicities or via adding new
   roles subsequently, we cannot assume that the endpoint will be untaken. As
   such, when trying to add a process, Halon should check whether the given
   endpoint is occupied by an existing process. If it is, then it should
   increment the last segment of the endpoint until a free endpoint address is
   found. If none can be found (which is pretty unlikely) it should refuse to
   add the process.

1. Halon should return to the caller the configuration of any processes added.
   By configuration, we mean the parameters that would be stored in the
   `/etc/sysconfig` file for current processes, and which are necessary for the
   process to run. These data can be subsequently (re-)retrieved using the
   `cluster process configuration` command. This is needed because it is now
   possible to add ephemeral processes after system start. These processes will
   never be started by Halon (unless explicitly started with `process start`,
   which seems strange) and so must acquire their configuration another way.
   We cannot move writing configuration files into `process add` since this may
   run before `halon:m0d` starts on the relevant nodes.

1. Where multiple processes are added, Halon should return the configuration
   for all starting processes. It is up to the caller to split these apart
   appropriately.

## Node or process removal

Removing nodes should first remove all processes on the node, as per the
following process. After all processes are removed, the `Host` resource will
be removed along with all corresponding resources.

Removing a process should first attempt to ensure that the process is stopped.
For Halon managed processes, this should run rules to stop the process before
trying to remove them. If a process fails to stop, then it will be marked as
failed and at this point we may remove it.

For an unmanaged process, we have no means by which to stop the process
currently. In this case, we should refuse to remove the process until it
shows itself as OFFLINE or FAILED.

## Command restructuring

Since we are introducing a number of new commands to halonctl, and changing
the names of some existing ones, this seems an appropriate point to
restructure the command hierarchy to fit our new design and to simplify
things for users. We propose the following:

```
halonctl
  mero # Renamed 'cluster'
    bootstrap # Renamed 'bootstrap cluster'
    dump # Remains unchanged
    load # Remains unchanged
    node
      start # New command. Opposite of 'node-stop'
      stop # Renamed 'cluster node-stop'
      remove # New command
    process
      add # New command
      configuration # New command
      start # New command
      stop # New command
      remove # New command
    reset # Remains unchanged
    status # Remains unchanged
    start # Remains unchanged
    stop # Remains unchanged
    sync # Remains unchanged
    update # Remains unchanged. We remove the now defunct 'notify'
    vars # Remains unchanged
  halon # New category, absorbing commands currently under 'root'
    debug
      eq # Remains unchanged
      rc # Remains unchanged
      cep # Remains unchanged
      node # Incorporate results from current `hctl status`
    node
      add # Renamed 'bootstrap satellite'
      disable-traces # Remains unchanged
      enable-traces # Remains unchanged
      remove # New command
    service # Remains unchanged
    station # Renamed 'bootstrap station'
```

Of note for discussion are the new commands:

* `node remove` would attempt to remove all Mero processes from a node and then
  remove that node itself from the cluster.

* `cluster node remove` would attempt to remove all Mero processes from a node.
  It would then remove the Mero `Node` entity.

* `cluster node add` would take multiple roles and attempt to add corresponding
  processes to a node. It would be equivalent to multiple `cluster process add`
  calls.

* `cluster process add` would take a role and add one or more corresponding
  processes to the cluster.

* `cluster process stop/start` would be the equivalent of `node stop/start` for
  individual processes. They would subsume the existing `client start/stop`.

* `cluster process remove` would take a process fid and attempt to remove that
  process from the cluster.

* `cluster process configuration` should take a process fid and return the
  correct configuration to run that process - e.g. the set of data present in
  the `/etc/sysconfig` file which would be written for that process.

## Extension

Whilst not in the scope of this PR, this same approach should extend to adding
new SSUs or similar objects to the cluster.
