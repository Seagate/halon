Resource Graph
==============

Overview
--------

The resource graph is a typed graph database. It's Halon's principal data store
and one of the major components used when writing rules.

Context
-------

The :abbr:`RG (resource graph)` is the core database used by the
:doc:`recovery-coordinator` when deciding upon actions to be taken. The
:doc:`recovery-coordinator` both reads and writes to the resource graph, reading
current system information and updating it to reflect changes of state or
condition. It is one of the two components replicated by the :doc:`replicator`.

Detail
------

The resource graph is a typed, directed graph store; each node and edge
possesses a type, and graph access is driven by these types. It is a compile
time error to attempt to insert into the graph an object which is not specified
as being part of the graph schema, or to try to connect two nodes with a missing
relation.

Schema
~~~~~~

The graph schema (the set of nodes and relations which are permitted in the
graph) is controlled by the use of two type classes: `Resource` and `Relation`.
To be inserted into the graph, an object must be of a type that has a `Resource`
instance; correspondingly, to connect two resources with an edge of a given
type, that edge must have a `Relation` instance. Relations are parametrised over
their start and end types, as well as the type of the edge; thus, we may have a
relation specifying that `Host` may be connected to `NetworkInterface` with the
edge type `Has`.

Since the schema is defined using a typeclass, it exists in multiple files
throughout the codebase. Particular attention should be given to:

- `HA.Resources` (basic schema defined for any cloud haskell application)
- `HA.Resources.Mero`  (reflections of confd types in the resource graph)
- `HA.Resources.Castor` (schema for the castor specific cluster)

Additional resources may be defined by Halon services, or elsewhere in the
codebase used by the recovery coordinator.

Relation Cardinality
++++++++++++++++++++

Since commit a12b218d3937511ea8499eab68d01cbc06fa87c7 (post Teacake) Halon has
had the ability to specify the cardinality of relations. This is to say, for a
given relation `A Foo B`, we might specify that there are many `B`s for a given
`A`, but only one `A` for a given `B`.

There are two possible cardinalities, which are specified at either end of a
relation:

- `AtMostOne`
- `Unbounded`

It might also be nice to implement `ExactlyOne`, but it is rather tricky to
enforce compile-time checking of this invariant (consider adding a new node and
connecting it elsewhere - we must make sure that all possible relations for that
new node are checked).

Standard implementations of methods `connectedTo` and `connectedFrom` return a
type depending upon the cardinality of the relation they are exporing: where
cardinality is `AtMostOne`, a `Maybe a` will be returned, as opposed to a `[a]`
where the cardinality is unbounded.

Dictionaries
++++++++++++

Resource has a slightly curious signature:

.. code-block:: haskell

   class StorageResource a => Resource a where
     resourceDict :: Static (Dict (Resource a))

The `Static (Dict (Resource a))` provides a way to reify (and serialise)
evidence of the typeclass instance. Conversely, by pattern matching on the
`Dict`, one can obtain evidence for the `Resource` constraint. This is used to
serialise and deserialise elements in the graph while maintaining the class
constraint, and to allow the graph to be sent over the wire.

Construction of Instances
+++++++++++++++++++++++++

It is possible to construct instances manually, but the easiest thing to do is
use the Template Haskell functions in `HA.Resources.TH` to generate the relevant
instances (and static functions) for you.

Due to template haskell staging restrictions, two calls are required (both must
be present):

.. code-block:: haskell

   $(mkDicts
     [''Cluster, ''Node, ''EpochId, ''Has, ''Runs]
     [ (''Cluster, ''Has, ''Node)
     , (''Cluster, ''Has, ''EpochId)
     ])
   $(mkResRel
     [''Cluster, ''Node, ''EpochId, ''Has, ''Runs]
     [ (''Cluster, AtMostOne, ''Has, Unbounded, ''Node)
     , (''Cluster, AtMostOne, ''Has, AtMostOne, ''EpochId)
     ]
     []
     )

The first argument to either of these functions is a list of types we wish to
make instances of `Resource`. The second argument is a list of tuples
representing relations. In `mkResRel` we additionally provide information on the
cardinality of those relations.

The third argument to `mkResRel` should contain any additional functions in the
module which we wish to make remotable.

Accessing and Modifying
~~~~~~~~~~~~~~~~~~~~~~~

For access and modification, see principally the functions defined in
`HA.ResourceGraph.GraphLike`, along with the functions defined in
`HA.ResourceGraph`:

.. code-block:: haskell

    -- * Querying the graph
  , null
  , memberResource
  , memberEdge
  , memberEdgeBack
  , edgesFromSrc
  , edgesToDst
  , anyConnectedFrom
  , anyConnectedTo
  , isConnected
    -- * Modifying the graph
  , deleteEdge
  , disconnect
  , disconnectAllTo
  , disconnectAllFrom
  , removeResource
  , connectUnique
  , connectUniqueFrom
  , connectUniqueTo
  , connectUnbounded

Garbage Collection
~~~~~~~~~~~~~~~~~~

When working with the resource graph, one does not delete resources directly.
This would potentially be expensive and annoying, since one would have to verify
that a given resource wasn't connected to anything else whenever removing a
connection from it. Instead, the resource graph has its own garbage collector
which will automatically remove resources not connected to the roots of the RG
(in Halon, the `Cluster` resource.)

The resource graph keeps a record of the number of times disconnections have
happened in the graph; this is checked each time `sync` (which synchronises the
RG with the replicator) is called, and if greater than a certain threshold, GC
is performed before syncing the graph.

Code pointers
-------------

- The general interface to graph communication is in
  `halon/src/lib/HA/ResourceGraph/GraphLike.hs`.
- The implementation of the `GraphLike` interface for standard RG
  operations is in `halon/src/lib/HA/ResourceGraph.hs`.
- The unconstrained graph used for migrating between multiple versions
  of the resource graph is in `halon/src/lib/HA/ResourceGraph/UGraph.hs`.

Initial resources are defined in:

- `halon/src/lib/HA/Resources.hs`
- `mero-halon/src/lib/HA/Resources/Castor.hs`
- `mero-halon/src/lib/HA/Resources/Mero.hs`

Template haskell used to generate `Resource` and `Relation` interfaces is
defined in:

- `halon/src/lib/HA/Resources/TH.hs`
