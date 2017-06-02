Concept: Logging
================

Trace logging is used to get detailed logging information from individual components of Halon. Trace logging messages go to journald on whichever node the messages are logged on (or to stdout if halon is started outside of systemd control).

Enabling
--------

Multiple componets in Halon have trace logging defined.


Code pointers
-------------

- `/halon/src/lib/HA/Logger.hs` defines the core logging infrastructure.

These components have loggers defined:

- `/halon/src/lib/HA/CallTimeout.hs` defines the "call" logger.
- `/halon/src/lib/HA/RecoverySupervisor.hs` defines the "RS" logger.
- `/halon/src/lib/HA/ResourceGraph.hs` defines the "RG" logger.
- `/halon/src/lib/HA/Startup.hs` defines the "startup" logger.
