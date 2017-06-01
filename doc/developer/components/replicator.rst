Replicator
==========

The replicator provides high-level access to the paxos-mediated replicated state machine underlying Halon. 

Context
-------

The replicator sits between the replicated log, which provides the consensus mechanism by which state is synchronised between multiple nodes, and the clients (the recovery co-ordinator, event queue etc) which use this state. 

Replicated State
----------------

Halon has two instances of the replicator, each controlling one aspect of the replicated state:

- The EQ replicator is responsible for the :ref:`event-queue`.
- The MM replicator is responsible for replicating the multimap (and hence the :ref:`resource-graph`).

See the module `HA.Startup` for the configuration of these replicators.

Log and Mock instances
----------------------

To allow for testing, there are two instances of the `RGroup` typeclass which defines the replicator. The log replicator (`HA.Replicator.Log`) is based upon `replicated-log` and uses Paxos-based consensus. The mock replicator runs on a single node and is expected to be used entirely for testing.
