# RFC: Updating the persistent state.

## Introduction

One crucial goal for Halon is the ability to update the software on a running
system without (significant) downtime. The most tricky part of this to manage
is changes to the format of the persisted state, requiring data on disk to be
updated before the new version of Halon can start. This RFC describes the
means by which these updates should be managed.

## Purpose

The update process is intended to satisfy the following:

* Downtime should be minimal. The RC should be inactive for less than a minute;
  if possible, the EQ should be inactive for only a few seconds, in order not
  to drop messages.

* Mero should remain running during the update process of Halon.

* If an update fails, it should be possible to roll back the cluster to a
  previous version. This may involve rolling back state that has been written
  in the new format only.

## Constraints

* In general, it will be very difficult to roll back arbitrary updated state,
  since new rules may not have an equivalent in the old system. It will be easier
  to roll back to the previous state as well as version, but this might involve
  losing some updates subsequently processed.

* There may be a long delay between making changes in code which require
  updates to persisted state, and updating the actual persisted state. So
  ideally we need to be able to record the update process at the time the code
  change is being made.

* We cannot decode (easily) old resources and relations into Haskell types, since
  we encode relations (and resources) as type class constraints.  

## Scope

The replicated state encodes three separate components:

1. Membership of the tracking station.

1. Messages in the EQ.

1. The resource graph (encoded as a Multimap).

Both the tracking station and EQ are relatively simple; whilst the individual
types might be updated, the structure is likely to remain fairly simple. As
such, we can handle updates there using existing `SafeCopy` mechanisms.

Updates to the resource graph come in two types:

* Updates to individual resources in the graph which can be handled
  via `SafeCopy` mechanisms.

* Updates to the graph schema. Since the schema is encoded as class constraints,
  rather than as a specific datatype, we cannot use `SafeCopy` mechanisms and
  need to update data some other way. Alternatively, we may have updates which
  cross the boundaries of single resources - e.g. swapping a field between two
  resources. In this case, there is no way to use `SafeCopy` to update these
  as we need to update the objects as a pair.

This RFC is principally focussed on handling the second form of update.

## Design

We propose taking an approach similar to Ruby on Rails's concept of
"migrations". These specify two things:

- The Halon version which the update is applied from.
- A script (in some form) to be applied to the replicated state.

When Halon starts up, it reads the version of the replicated state. At present,
if this differs by a major version from the current version, then Halon will
refuse to start. Instead, it should check to see whether any update scripts
have a version greater than the stored version and lower than or equal to
the current version. It should then take the following actions:

1. Backup the existing replicated state to a second location on disk. This
   can be done by a straightforward disk copy, marked with the date.

1. Apply in order each update to the replicated state. If at any point an error
   occurs, we should revert the state to the backup copy and terminate Halon
   with an appropriate error.

1. Attempt to load the full RG in the new Graph. This should reveal any
   resources whose `staticDict` points to a deleted reference. If this fails,
   then we should revert to the previous version.

1. Start the RS and RC.

If the update process takes longer than expected, then we could in theory
start the EQ before updating the RG. This would allow the system to continue
to ingest messages while the RG is being updated.

When making a change that will result in a schema update, the change should
be accompanied by an associated migration script. We propose that this script
is a standard Haskell function which becomes compiled into the executable. In
this way, we can easily use all existing functionality to manage the graph
update, and don't have to ship an increasing number of executables.

### Script format

We cannot decode the graph to `Res` or `Rel` instances since these rely on
existential `Relation` or `Resource` constraints. As such, our update scripts
must work in terms of the underlying `ByteString`s. However, since we know the
encoding, we should be able to decode to variants on these lacking the
constraints - effectively giving us an untyped graph.

We propose that updates operate on a version of a graph which drops the
requirement for `Resource` or `Relation` constraints on existing entities in the
graph. We would then retain the original graph types (see later section on
where we have "updated" a type but no migration exists for it) and evidence
of sufficient constraints to do things like serialisation and cast. We could
then abstract over the existing graph API as follows:

```Haskell
module HA.ResourceGraph.GraphLike where

class GraphLike a where
  type InsertableRes a :: * -> Constraint
  type InsertableRel a :: * -> * -> * -> Constraint

  type Resource a :: * -> Constraint
  type Relation a :: * -> * -> * -> Constraint

  type UniversalResource a :: *
  type UniversalRelation a :: *

  encodeUniversalResource :: UniversalResource
                          -> ByteString
  encodeUniversalRelation :: UniversalRelation
                          -> ByteString
  decodeUniversalResource :: RemoteTable
                          -> ByteString
                          -> UniversalResource
  decodeUniversalRelation :: RemoteTable
                          -> ByteString
                          -> UniversalRelation

  encodeIRes :: InsertableRes a => a -> UniversalResource
  encodeIRelIn :: InsertableRel r a b => a -> r -> b -> UniversalRelation
  encodeIRelOut :: InsertableRel r a b => a -> r -> b -> UniversalRelation

  queryRes :: Resource a => a -> [UniversalResource]
  queryRel :: Relation a r x y -> x -> r -> y -> [UniversalRelation]

  graph :: Lens' a (HashMap UniversalResource (HashSet UniversalRelation))

  storeChan :: Lens' a StoreChan

  changeLog :: Lens' a ChangeLog
```

The key observation here is differentiating between things which can be
inserted into the graph (those which satisfy the `Insertable` constraints) and
things which merely exist in the graph (the `Resource` and `Relation`
constraints). The idea is to be able to load a graph in an old schema, but only
be allowed to modify it according to the constraints of the new schema.

Using this abstraction, we can then write an instance for an unconstrained
graph (we give only some implementations to provide an example):

```Haskell
module HA.ResourceGraph.Unconstrained where

import HA.ResourceGraph (Resource, Relation)
import qualified HA.ResourceGraph.GraphLike as GL

data Res = forall a. (  Static (Dict (Resource a))
                      , Static (Dict (TypeablePlus a)), ByteString
                      )
data Rel = forall a r b. (  Static (Dict (Relation r a b))
                          , Static (Dict (TypeablePlus r))
                          , Word8
                          , ByteString, ByteString, ByteString
                          )

data UGraph = Graph
  { -- | Channel used to communicate with the multimap which replicates the
    -- graph.
    _grMMChan :: StoreChan
    -- | Changes in the graph with respect to the version stored in the multimap.
  , _grChangeLog :: !ChangeLog
    -- | The graph.
  , _grGraph :: HashMap Res (HashSet Rel)
  } deriving (Typeable)
makeLenses ''UGraph

instance GL.GraphLike UGraph where
  type GL.InsertableRes UGraph = Resource
  type GL.InsertableRel UGraph = Relation

  type GL.Resource UGraph = TypeablePlus
  type GL.Relation UGraph r a b = TypeablePlus r

  type GL.UniversalResource UGraph = Res
  type GL.UniversalRelation UGraph = Rel

  encodeUniversalResource (x, y, z) = toStrict $ encode x `append`
                                                  encode y `append` z

  encodeIRes r = ( $(mkStatic 'someResourceDict) `staticApply`
                      (resourceDict :: Static (Dict (Resource r)))
                  , $(mkStatic 'someTypeablePlusDict) `staticApply`
                      (resourceDict :: Static (Dict (TypeablePlus r)))
                  , safePut r)

  queryRes r = find (\x -> snd x == safePut r) $ M.keys $ g ^. graph

  graph = grGraph

  changelog = grChangeLog

  storeChan = grMMChan
```

Important things to note here are:
- We set `InsertableRel` and `InsertableRes` constraints to match existing
  `Resource` and `Relation` constraints; thus what we insert accords to the
  schema of the new graph.
- We have a new `TypeablePlus` constraint. The idea will be for old types to
  drop `Resource` and `Relation` but retain `TypeablePlus`, which will
  provide evidence enough to serialise, cast etc.
- The query operation allows us to extract an old resource without knowing its
  static `Resource` label. For resources which are still valid under the new
  schema, the same static label can be reinserted without inspection.
- We can easily verify whether the graph accords with the new schema by
  trying to resolve all static `Resource`/`Relation` pointers; if any fail to
  resolve, then we know we have an invalid graph.
- In order to resolve `TypeablePlus` for old resources whose `Resource` dict may
  no longer exist, we store an additional `TypeablePlus` dictionary. This may be
  retained even when `Resource` is dropped.

As a consequence of introducing `TypeablePlus`, we need to update the serialised
form of (existing) `Res`/`Rel`. This may be done through a special update which
introduces no RG changes but which reads the old serialised format and writes in
the new format. This should not alter anything else (though it will slightly
increase the size of the resource graph).

### Additional actions

Occasionally additional actions may need to be taken by the RC to ensure that
the system is consistent after an update. For example, it might need to send
shutdown commands to no longer needed services, or request new state from other
components. In this case, we can have a special node in the graph which
stores a static pointer to a special rule which should run immediately after
update. This can be cleared after running.

## Downgrade

Downgrade is in general hard to do, but we may support downgrade of the RG
by introducing intermediate versions as per Mero. In the intermediate versions,
we may introduce `TypeablePlus` for new resources/relations but no `Resource`/
`Relation` instances. In this case, a downgrade script may be run in a similar
way from that version. We may then use the `todo` node in the graph to run
downgrade actions.
