# RFC: Services

## Introduction

A Service within the context of Halon is a managed (Cloud Haskell)
process which can be run on a (Cloud Haskell) node. This document
defines the life cycle, representation and means of interacting with
Services.

**Note:** this RFC requires PlantUML to process the `@startuml`
fragments into diagrams:

```
$ plantuml 0006-services.md
```

Or use the following if PlantUML is not installed:

```
$ curl -O http://softlayer-ams.dl.sourceforge.net/project/plantuml/plantuml.jar
$ java -jar plantuml.jar 006-services.md
```

## Purpose

A Service is the principal abstraction used within Halon to represent
the components whose high availability Halon is managing. This
includes components of Halon itself.

## Constraints

* A Service properly refers to a Service _type_. Each Service type may
  have multiple Service _instances_ throughout the cluster.

* Services must be able to represent both internal (e.g. the Recovery
  Coordinator) and system (e.g. a statistics collection daemon)
  processes to Halon.

* A Service must be identifiable and addressable by name.

* Only one Service instance of a given type may run on a Node at any
  one time.

## Description

### General principles

We think of a service (small s) as a collection (possibly 0) of system
daemons or C-H processes providing a distinct element of
functionality. A service will typically have some notion of lifecycle
(started/stopped/died) which can be monitored externally.

We should use a Service abstraction for any service whose status we
wish to track in a consistent way throughout the cluster, and which we
wish to interact with directly (rather than through another Service or
other Resource).

#### Exemplar internal Services

The following components of Halon should be themselves modeled as
Services:

* Recovery supervisor

* Recovery coordinator

* Subsidiary CEP processors

#### Exemplar external Services

The following system processes should be modelled as Services:

* Mero daemon

* Data collection daemons (e.g. to read from /tmp/dcs)

#### Exemplar non-Services

The following are examples of things which are not Services:

* Temporary processes spawned to perform some action - e.g. actuate an
  external command on a node.

* A storage device. Whilst this has a lifecycle, we do not interact
  with it directly, and it would be confusing to think of it as
  a service which 'does' something rather than a mere component which
  is 'done' to.

### Tracking Services

A Service instance is a specific kind of `Resource`; it has a unique
identity tracked as an entity in the Resource Graph. A Service should
be linked in the Resource graph to:

* The node on which it is running.

* The applicable service name on the current node.

* The configuration which it is running with.

* The `ProcessId` of the C-H process implementing the Service.

* Any other `Resource`s which the Service has (potentially shared)
  ownership of. For example, a Service may require a database
  connection to a managed database, in which case it should be marked
  as using one within the Resource Graph. The set of `Resource`s to
  which a Service may meaningfully be attached differs with and must
  be specified by the Service type.

Responsibility for tracking a Service lies with the Recovery
Coordinator (or subsidiary node delegated this task), and Service
tracking should be implemented in the same way as other cluster
monitoring/management actions, using CEP rules. The exception to this
is in those Services which implement the tracking station itself;
since these are started before the Recovery Coordinator, the usual
event status messages cannot be sent. The Recovery Coordinator itself
tracks the nodes currently in the tracking station, and must implement
logic to track this in the Resource Graph.

During the lifespan of a service, it may send messages to indicate
that:

* It has acquired (or released) a particular `Resource`.

* It has changed configuration.

* It has failed. This is typically the case when the Service is
  wrapping an external process, such as a system daemon. This may be
  a generic failure message (in which case the Service may
  subsequently terminate) or a specific message which expects
  a response from the Recovery Coordinator.

### Service lifecycle and supervision

In general, we envision that Services will be started in two places:

* During bootstrap, tracking station Services will be started by
  `halond`.

* At all other times, Services should be started by the Recovery
  Coordinator or its delegated agents as a result of CEP rules.

However, this is a guideline rather than a rule; there may be
circumstances which call for Services to be started from other places.

A Service must ensure as it starts that there is no other instance for
its Service type running on the current node. This could be done by
means of a lock or similar.

When a Service starts, it must send notification to the Resource
Coordinator indicating that it has successfully started, and the
configuration it is using. It may additionally send messages to
indicate acquisition of a particular `Resource`. If it cannot start,
for example due to malformed configuration or due to the presence of
another Service instance on the same node, it must also report this to
the Recovery Coordinator.

A Service terminating normally may send a message to the Recovery
Coordinator announcing its intention to do so. In order to catch
Services which terminate abnormally, we must have a supervision
hierarchy in which we keep track on Services. A Supervision hierarchy
will normally attempt to restart failed Services; however, we wish all
such actions to be subject to rule processing by the Recovery
Coordinator or another such node. As such, we propose an explicit
'Supervisor' process whose role it is to monitor other Services. The
Supervisor, itself a Service, has the sole purpose of watching other
Services and reporting their status to the Recovery Coordinator. It
takes no role in recovery.

A Supervisor may monitor any number of Services on the same or other
nodes; however, for the purposes of efficiency we suppose that we are
likely to have a supervision hierarchy where Services on one node are
monitored by a local Supervisor, which it itself monitored by one or
more other nodes. The set of Services monitored by a given Supervisor
should be encoded in the Resource Graph; that way, if a Supervisor
itself dies, a new Supervisor instance can be started monitoring the
same set of Services. The Recovery Coordinator may also implement
logic to ensure that the Supervision hierarchy is evenly spread across
Resources.

### Interacting with Services

Any process may interact with a Service through looking up its
`ProcessId` in the Resource Graph and talking directly to its message
queue. This is perfectly legitimate; many Services will operate
through talking to other Services directly.

All Services should respond to a certain set of messages corresponding
to the OCF spec. Aside from starting and stopping, these consist of:

* `Check`: respond with a message indicating the health of the
  service.

* `Status`: a message asking for the service to log status info
  immediately.

Other Service types must define the set of messages to which their
instances will respond.

### Logical data model

@startuml
object Node {
address
}

object ServiceName {
name
}

object Service {
serviceName,
serviceProcess
}

object ServiceInstance {
processId,
version
}

object Schema {
schema
}

ServiceInstance "*" o-- "1" ServiceName
ServiceInstance "*" o-- "1" Service
Service "+" --|> "1" ServiceName
Node "1" *-- "*" ServiceInstance
Service "+" o-- "1" Schema

@enduml

### Physical data model

@startuml
object Node {
  address
}

object ServiceName {
  name
}

object ServiceProcess {
  processId
}

object Service {
  serviceName,
  serviceProcess,
  configurationDict
}

Service "1" -- "*" ServiceProcess
ServiceProcess "*" -- "1" Node
ServiceProcess "1" -- "1" ServiceName
Node "1" -- "*" ServiceName

@enduml

#### Schema

A schema defines the resources, relations and configuration for
a given service. Multiple services may share the same schema, but in
general it is expected that each service will have a unique schema.
Services sharing a schema must:

* Accept the same configuration parameters.

* Allow connection to the same resources.

* Store their configuration in the graph in the same manner.

A schema is currently implemented through Haskell's typeclass
mechanism; a schema is uniquely determined by the type of
configuration which a service takes.

#### Service

A service features a name and a command to instantiate a new instance
given some configuration corresponding to the service's Schema. There
may be in the order of a few dozen different services in a cluster.

#### Service instance

A service can be started any number of times, each time yielding a new
service instance. A service instance is to a service what a process is
to a binary, in UNIX parlance. A service instance should expose its
process id, allowing communication with it as a C-H process.

#### Service name

A service name is a resource embodiment of a resource constraint;
namely, that only one instance of a service may run on a node at any
one time. A service cannot start whilst another service has possession
(via linking in the resource graph) of the relevant service name.

It is possible for multiple different services to require the same
service name; in this case, only one may run at a time on a given
node. It is not required for services sharing a name requirement to
share a schema.

### See also

https://github.com/tweag/halon/blob/master/rfc/001-node-agent.md
https://github.com/tweag/halon/blob/master/rfc/002-cluster-bootstrapping.md
https://github.com/tweag/halon/blob/rfc-configuration-api/rfc/004-configuration-api.md
