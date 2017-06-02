Concept: Logging
================

Trace logging is used to get detailed logging information from individual components of Halon. Trace logging messages go to journald on whichever node the messages are logged on (or to stdout if halon is started outside of systemd control).

Enabling
--------

Multiple componets in Halon have trace logging defined.

A logger for a subsystem takes the form of a function `String -> Process ()`. Loggers are created through calling `mkHalonTracer foo`, where `foo` is a name identifying the subsystem.

To enable tracing on a node, the environment variable `HALON_TRACING` should be set and specify the names of subsystems which the logger should be enabled for. For example:

```bash
HALON_TRACING="RS halon:m0d" ./halon
```

Code pointers
-------------

- `/halon/src/lib/HA/Logger.hs` defines the core logging infrastructure.

These components have loggers defined. This list is not exhaustive; just look for calls to `mkHalonTracer`.

- `/halon/src/lib/HA/CallTimeout.hs` defines the "call" logger.
- `/halon/src/lib/HA/RecoverySupervisor.hs` defines the "RS" logger.
- `/halon/src/lib/HA/ResourceGraph.hs` defines the "RG" logger.
- `/halon/src/lib/HA/Startup.hs` defines the "startup" logger.
