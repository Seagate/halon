Component: Recovery Supervisor
==============================

The recovery supervisor runs on every tracking station node. At any given time,
one of the recovery supervisors takes on the role of "leader" - this role co-
incides with the EQ leader and the paxos leader. This recovery supervisor
monitors the recovery coordinator process and is responsible for re-spawning it
when it dies.

If the node hosting the recovery co-ordinator dies, then another recovery
supervisor will become leader and spawn the recovery co-ordinator on another
node.

Code pointers
-------------

The recovery supervisor is defined in `/halon/src/lib/HA/RecoverySupervisor.hs`.
