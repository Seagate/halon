# RFC: Configuration API

## Introduction

Configuration refers to those tunable parameters which govern the behaviour of the system. This document describes how such parameters will be set and updated over the lifetime of the system.

## Purpose

It must be assumed that over the lifetime of a long-running system such as halon, it may be necessary to alter the configuration of the system for the purpose of tuning, maintenance or changes in external conditions. This must be done whilst ensuring the continued stability of the system as a whole.

## Constraints

* Initial configuration must be specifiable in such a way as to make it possible to provide through some automated deployment tool (Puppet, CFEngine etc.)

* It must be possible to change the configuration of the entire system whilst it is running without comprimising its accessibility and consistency.

* The configuration API should be amenable to integration with whatever future system is put in place by Xyratex to manage the configuration of the cluster as a whole.

* It may at certain times be desirable to run parts of the system with different configuration parameters for the purposes of testing/benchmarking.

* Running configuration must suitably persist in the case of a cluster shutdown/restart.

## Overview

The conventional approach to configuration management is to have configuration stored in some database somewhere, whether that be a text file, an RDBMS, the Windows registry or elsewhere. Since halon itself is a high availability system, however, we cannot rely on any external database with lesser guarantees on consistency and availability than halon itself. Luckily, halon offers a peristent, highly available database in the form of the resource graph, which we propose to use as the central configuration store.

Unfortunately, this puts us into a slight catch-22 situation. Since the resource graph is only replicated to nodes in the tracking station, and can only be safely accessed once quorum has been reached, we cannot rely on it to access any configuration necessary to bootstrap the system to a quorate state. As such, we need to define some separate mechanism to deal with accessing those elements of configuration data needed during the bootstrap process.

The rest of this document procedes as follows: we first dicsuss the storage of configuration and its integration into the resource graph. We then look at the means by which this configuration is updated by external clients. We discuss the mechanism by which this configuration is propogated from the resource graph to services which require it. We then look at the additional measures necessary for bootstrap configuration, segue into a brief exploration of default configuration, and finish by looking at how to handle problems with misconfiguration.

## Configuration storage

We propose adding an additional `Configuration` type of `Resource` to the resource graph. A `Configuration` resource would possess the full global configuration; in other words, it may possess configuration elements appropriate to each cluster node and service. Each service, when spawned, would be linked by `Has` relationship to the `Configuration` used in spawning it; in this way, separate parts of the cluster may at any given time be running using different configurations.

In order to correctly store the _disposition_ in terms of configuration, as well as its current state, we introduce a new relationship type, `Wants`, which represents the intention to change configuration. A `Wants` relationship is necessary to ensure that service configuration changes behave sensibly in spite of changes in RC, and that new configurations survive garbage collection. `Wants` relationships should be ephemeral, since they are removed as soon as configuration has been updated.

## Updating configuration

We do not here make any particular requirements on how configuration external to the resource graph is to be stored, except that, as noted above, it should be provisionable by an automated deployment tool. Instead, we introduce the `reconf` abstraction. `reconf` is a short-lived process (which may run on any node having suitable access to external configuration) which is responsible for reading in configuration data from an external source and sending `ConfigurationUpdate` messages to the tracking station. A `ConfigurationUpdate` message should contain three elements:

1. The current epoch.
2. The new configuration object.
3. An optional filter determining which services to apply this configuration to. Services are identified by node and service name (see 'Identifying a Service' in [RFC: The Node Agent](001-node-agent.md)).

Responsibility for responding to `ConfigurationUpdate` messages lies with the consensus leader, which should only respond to `ConfigurationUpdate` messages from the current epoch. Once consensus is reached on the `ConfigurationUpdate` message, this should be applied to the resource graph by adding in a relevant `Configuration` node and adding `Wants` edges from the appropriate services.

Note that we make no assumptions or demands about how the `reconf` process is initiated; it might be kicked off through use of the `halonctl` command with particular arguments, or it might be spawned periodically by the recovery co-ordinator, or it may even be long-lived and establish inotify hooks.

## Effecting configuration changes

Once the resource graph has been updated with the new configuration, it is the job of the resource co-ordinator to apply this configuration to the relevant services as identified by `Wants` relationships. There are two means by which it might do this:

1. The easiest method to reconfigure a service is to kill the service and restart it with new configuration. Services should take configuration as the 'environment' part of the closure implementing the cloud haskell process.
2. In certain cases (for example, where a process holds a long-lived resource which cannot easily be released and then re-acquired) it may not be expedient to kill and restart the service with a new configuration. In this case, the service itself must be responsible for integration of the new configuration.

In order to support both of these possibilities, we describe the following process for reconfiguration:

1. The recovery co-ordinator attempts to kill the process using `exit` and a new reason, `Reconf`, which we reserve to this purpose. It then attempts to restart the service using the new configuration. Since service starting is idempotent, we do not worry about the previous service not having exited.
2. In the case of a regular service, this exit should be uncaught and result in the termination of the service, followed by the spawning of a replacement service with the new configuration.
3. A new service message `ServiceConfigured` should be sent to the recovery co-ordinator upon successful startup. Upon receipt of this message, the RC should update the resource graph to reflect the new configuration.
4. In the case of a service managing its own reconfiguration, this exception should be caught by the process implementing the service, which should then send a `ConfigurationUpdateRequest` to the recovery co-ordinator. The recovery co-ordinator should then respond with a `ConfigurationUpdate` containing the current epoch and the relevant `Wants` configuration for that service.
5. As in the case of a killable process, the service should send a `ServiceConfigured` message to the recovery co-ordinator on successful configuration, at which point the recovery co-ordinator should update the resource graph.
6. This process should be driven by a timer, and continue until there are no remaining `Wants` edges in the graph.

Sometimes, the relevant configuration to apply might be to the recovery supervisor acting as the co-ordinator itself. In this case, the co-ordinator should first apply all other `Wants` configuration changes, before killing itself (with `exit Reconf`). Since responsibility for restarting services lies with the recovery co-ordinator, this would force a new co-ordinator to be elected on a different node, which would then restart the original supervisor with a new configuration.

## Bootstrap configuration

As alluded to earlier, certain parameters are necessary in order to ensure successful bootstrapping of halon to the stage where it can elect a recovery co-ordinator and begin updating and applying configuration from the resource graph. A non-exhaustive list of such things is given:

- halond listening address and port
- tracking station node addresses.

However, we would prefer to centralise configuration as much as possible and avoid 'special-casing' things. As such, the configuration reading library used by `reconf` should be exposed and made accessible to other libraries; in particular, `halond` and `halonctl`, which would use this library to read configuration and obtain the relevant configuration items for the bootstrap process.

## Default configuration

Whilst the above section deals with parameters which are necessary during bootstrap to allow the cluster to boot at all, there are many others which are less vital and must simply have *some* sensible value in order to allow the cluster to start. For these, we provide a default configuration, which for simplicity's sake is hardcoded in halon. This applies equally to bootstrap parameters; where only a few configuration items are specified in whatever external source is accessed by `halond` or `halonctl`, they should be merged into the default configuration. Indeed, the same applies to configuration supplied by `reconf`, except that in that case the new configuration should be merged into the existing `Has` configuration for a service.

During cluster restart (of which initial startup is merely a special case), there may be multiple sources of configuration potentially conflicting. Firstly, the bootstrap configuration would be used to start halond on all nodes and to get the tracking station running. The recovery co-ordinator would then read previous configuration data from the resource graph and reconfigure the cluster into its previous state. Independently, `reconf` may be called to update the configuration, which could again result in reconfiguring the cluster.

This could result in some amount of churn taking place before the cluster settles into a stable configuration. We do not propose to do anything about this. The alternative would be to allow the bootstrap process to pass a full configuration to the recovery supervisors on startup, which would then be applied directly. We feel this is an inferior solution for two reasons:

- It adds an additional element of complexity to the system.
- It gives an explicit preference for externally managed configuration over the configuration managed in the resource graph. Our default position should be to trust the configuration in the resource graph, since it is subject to far more stringent regulations on consistency. Note that we can still recover the preference for external configuration in our scheme, by repeatedly invoking `reconf`.

## Handling misconfiguration

Occasionally, we may find that a change in configuration itself results in breaking a service or, even worse, the cluster. In this section, we describe how we deal with this situation when it arises.

When the recovery co-ordinator attempts to restart a service with a new configuration, it should keep track of the number of `ServiceCouldNotStart` notifications it receives. After trying a fixed number of times (itself a parameter to the recovery supervisor) it should restart the process with the old configuration, remove the `Wants` relationship and notify the operator. This count does not need to be added to the replicated log and shared amongst the tracking station; it does not matter if a new RC is elected during this process, since this will simply result in trying a few more times.

What may be more damaging is a 'slow death', where services start up correctly and report `ServiceConfigured` but are unable to operate correctly. In this case, restarting the cluster may result in the same situation being replicated as halon reconfigures itself. In this case, we propose the addition of an additional bootstrap configuration parameter to the recovery supervisor which causes it to discard any configuration found in the resource graph and revert to a default configuration.