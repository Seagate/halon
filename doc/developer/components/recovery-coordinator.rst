Component: Recovery Coordinator
===============================

The recovery coordinator is the "brain" of halon. It handles all the incoming
events from various sensors around the cluster and sent to the :ref:`event-
queue`, integrates that information with known cluster state in the :ref
:`resource-graph`, and takes actions through the various interfaces available.

Overview
--------

The majority of recovery coordinator code lives in the `mero-halon` package, in
`src/Lib/HA/RecoveryCoordinator`.

Rules 
-----

Phases
~~~~~~

Actions
-------

Events
------
