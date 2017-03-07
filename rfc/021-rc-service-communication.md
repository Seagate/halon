# RFC: Communication between services and RC from different Halon versions

## Introduction

In presence of Halon upgrades and downgrades, the node running RC and
some other node may be running different Halon versions. Any of the
following scenarios may happen:

* RC and service are from same halon version
* RC is newer than the service
* RC is older than the service

Newer here means "newer Halon version with possibly changed message
types" and respectively for older. Currently services and RC can not
easily talk between themselves if their version differs.

This RFC builds on service communication outlined in RFC23.

## Purpose

* To define a method/protocol for services and the RC to talk to each
  other even if they are of different versions.

* To make it as hassle-free to send/receive these messages w.r.t.
  encoding/decoding as we can.

## Design

Most work is built upon constructs outlined in RFC23.

The basic idea in RFC23 is to provide an `Interface toSvc fromSvc`
abstraction which encodes the type `toSvc` that we can send to a
service and `fromSvc` that we can receive from the service (or
equally, that service sends to RC). These interfaces are ephemeral
with a version number associated with them. We consider only 3
scenarios.

### Encoding

The basic idea is that we *have* to maintain backwards and forwards
compatibility. Without RFC23, we would need a serialization protocol
that supports this however with RFC23, we already have all the
necessary tools. The advantage of leveraging `Interface` for
communication is that we can perform version exchange/annotation and
therefore can always know which side side is newer.

The trick is to always rely on a newer side for conversion:
out-of-date side *always* receives a message it can
read<sup>[1](#footnote2)</sup>.

We have to impose some restrictions:

* impose `SafeCopy fromSvc, SafeCopy toSvc` constraints
* `instance SafeCopy WireFormat`
* `instance SafeCopy Version`
* Sender always sends `Version` and any types involved in version
  exchange/negotation in the version that the oldest possible receiver
  can understand<sup>[2](#footnote3)</sup>. This is up to the
  programmer to enforce.

Most of the above points simply ensure that we can find out if we're a
newer sender than the receiver is.

#### We're sending to older receiver

Older receivers (be it RC or service) can not perform conversions on
new messages. It is therefore up to us, the sender, to do this. We
know by now what version the receiver is and what message it can read:
this is programmer knowledge, knowing the possible older versions that
we can update from. For simplicity let's just assume 2 versions, Old
and New. For sake of example assume we're sending from RC to a
service. Then in new version of the code we have

```
data A_Old = …
data A_New = …
toSvc = A_New

instance SafeCopy A_New where
  type MigrateFrom A_New = A_Old

instance SafeCopy (Reverse A_Old) where
  type MigrateFrom (Reverse A_Old) = A_New
  migrate (A_New{..}) = Reverse $ A_Old …

sendToSvc :: NodeId -> String -> A_New -> Process ()
sendToSvc nid svcname msg = do
  … -- find out we need A_Old
  let msg' :: A_Old
      msg' = unReverse $ migrate msg
  … -- pack and send msg'
```

Similarly for the other direction. Older version then receives A_Old
which it can happily read.

Note that using `migrate` is not a strict requirement here! Indeed
it's not implicitly used anywhere, we simply piggy-back on the
implementation. There is nothing forcing `instance SafeCopy (Reverse
A_Old)`! The interface could perform arbitrary queries if it wanted to
to help the migration; the RC-side interface could certainly query RC
trivially (as it's guaranteed same-version and can bypass interface
types).

Last thing to note is that this easily extends to multiple versions of
types if desired: we can have `A_Old_v1`, `A_Old_v2` and simply
`migrate` (or something else) to the necessary version.

#### We're sending to newer receiver

Sending to a newer receiver is simpler: we can't possibly update the
type so we rely on receiver being able to read old messages. It can,
through `SafeCopy`. For non-trivial (i.e. not pure) migrations, we can
still leverage `SafeCopy` for decoding. We could set `A_New = A_Old`
(or just call `safeGet` directly) and perform in-`Process` migration
manually. Notably we are always able to decode an older message.

The appeal of this approach is for simple migrations we can fully
leverage `SafeCopy` where convenient but we are not locking ourselves
into it: we can change migration method in a new version by knowing
how to decode the data from wire to some `A_Old` and writing the logic
to move to `A_New` in the new interface.

#### Receiving from arbitrary version

RFC23 provides `WireFormat` message. We can use a combination of
`matchAny` and `Stableprint` to receive the message. We then use
`SafeCopy` to decode the contained `ByteString`. Observe that
`WireFormat` itself has a `SafeCopy` instance so it's possible to
change as long as it does not change `Stableprint`: i.e. it can not
move modules nor add type variables.

### Changing/removing/adding messages

`Interface` unifies all communication between RC/services to a single
type each way. This means we do not add/remove types, we can only
change. Changes have to be possible to migrate between by the
interfaces. It is completely up to the programmer to ensure the
resulting values make sense to the version of code they are sending
to. Receivers could be given a version of the message/service/RC if
more complex changes in logic have happened and we need to do
different things depending on what version is on the other side. For `N`
versions we want to support, it takes `N` versions to implement a clean
logic-breaking change in. Versions between `0` and `N` (where `0` is
lowest supported version and `N` is the newest version we have) have
to accomodate old logic flows until we know they will not be sent
(because they stop being supported) and can be removed. For Halon,
current requirement is `N = 2` so we only need one version that
implements new logic while having to deal with old messages.



<a name="footnote1"</a>: For some definition of read. There is an
optimisation for a common case where the RC and service version is the
same: in this case we simply always send the message instead of trying
to establish who's the newer version. If the old version receives a
new message, it signals this. This is a bit difficult to implement
(not stateless) and due to persistance, only works in the `RC ->
Service` version so it may be better to always negotiate (with
caching).

<a name="footnote2"</a>: This is a bit of a weird case because it's a
question of versioning the version exchange. We may instead just agree
on a stable version exchange protocol or use something
backwards/forwards compatible with "by-hand" conversion (think: JSON).
