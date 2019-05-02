Interface: SSPL
===============

The term SSPL covers a pair of components in the Castor system with somewhat
separate purposes:

- SSPL-LL is a suite of sensors and actuators which abstract over the hardware
  and operating system upon which Halon runs. Halon uses it both to learn
  information about system events, and to take action in response to failures.
- SSPL-HL runs on the CMU and acts as the public interface to castor management.
  It pulls some of its information from Halon.

There are two Halon :doc:`services <../concepts/services>` which are
responsible for communication with these components. We refer to these as
`halon:sspl` and `halon:sspl-hl` respectively.

The interface to both of these components is over RabbitMQ message exchange.

RabbitMQ connections
--------------------

The logic for connecting to RabbitMQ is largely abstracted in order to be shared
between the `halon:sspl` and `halon:sspl-hl` services. One important thing to
note is that, in order for messages to be delivered, appropriate queues,
exchanges and bindings must be set up on the RabbitMQ server. Since components
at either end may start first, we allow either end to establish these entities.
This means that we must make sure that the declarations for these things are
synhronised between components, because communication may fail where each end
has a different view on channel/queue properties (e.g. persistence).

Schemata
--------

All messages between Halon and the two separate SSPL components are JSON
encoded. The type of all possible messages is controlled by json-schema
documents, from which Haskell bindings are automatically generated.

The `sspl` package contains both the schemata (in the `app` directory) and the
generated bindings (in the `src` directory). If the schemata are updated and the
bindings need to be regenerated, then this can be done using the `mkBindings`
executable. Options can be specified if e.g. additional instances need to be
generated.

Code Pointers
-------------

- The shared code for handling RabbitMQ connections is defined in
  `/mero-halon/src/lib/HA/Services/SSPL/Rabbit.hs`.
- Schemata are defined in `/sspl/app/SSPL/Schemata/`.
- The bindings generator is defined in `/sspl/app/mkBindings.hs`.
- Bindings are present in `/sspl/src/SSPL/Bindings.hs`.
