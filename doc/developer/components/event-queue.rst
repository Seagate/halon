Event Queue
===========

The :abbr:`EQ (event queue)` is a persistent, replicated event buffer. Once
delivered to the EQ, messages are guaranteed to be resilient to the death of up
to half of the tracking station nodes, and messages sent there will be delivered
to the recovery coordinator.

Context
-------

The EQ sits atop the :doc:`replicator`, as one of the two components replicated
using an `RGroup`. Any Halon node may send messages to the EQ. Once receipt is
acknowledged, messages are replicated across the tracking station nodes. The EQ
forwards messages to the :doc:`recovery-coordinator`, which is responsible for
'ack'-ing the messages, allowing them to be removed from the EQ. The EQ
*tracker* is responsible for tracking the location of active EQ nodes, and runs
on all nodes connected to the Halon cluster.

The event queue *worker* is structured using CEP.

Detail
------

The EventQueue is implemented by a worker, defined in `HA.EventQueue.Process`.
This process uses CEP to run an event loop. The event queue is interested in the
following types of events:

- RC spawning. When the RC spawns, the EQ must start sending messages to it. It
  does this by spawning another process which polls the replicated state on a
  given interval.

- "Trimming" - a 'trim' message is sent by the RC when it's done with some
  event. This informs the EQ that it can drop that event.

- "Clearing" - the RC (or an administrator) may send a message asking for the EQ
  to be completely cleared. This is mostly useful for working around problems
  when the system has got stuck.

- Notifications about the replicator availability.

- `HAEvent`\s. These are the events sent by various components to be
  included in the persistent queue.
