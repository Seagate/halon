## RFC: Service Communication

## Introduction

As discussed in RFC021, in order to support rolling upgrade in Halon we will
need to alter the interface to communicate with services. This RFC proposes
a slightly larger refactoring of service communication which should abstract
some of the details of how we implement this communicating while giving it
greater safety. This should make it simpler to build functionality required
for updates, as well as subsequent updates to services.

## Scope

* This RFC should be treated as an adjunct to RFC021 - it addresses how to
  abstract over communication with services, rather than the specific
  mechanism by which that communication should be carried out. Thus the
  mechanism described by RFC021 should fit naturally under this proposal
  (although we believe that the abstraction proposed here would allow alternate
  systems as well).

## Requirements

* Services must be able to communicate with the RC running another version
  (either newer or older) of Halon.

* It should be a type error to attempt to communicate with a service in a way
  which is not update-safe.

## Design

Current communication with services may occur in a few ways:

- Communication from RC to service via `send` and the `ProcessId` of
  the service.

- Communication from RC to a spawned process on the service side using `send`
  and an ephemeral `ProcessId`.

- Communication from RC to a service via one or more `Channel`s.

- Communication from a service to the RC using `promulgate`.

- Communication from a service to the RC using direct `send` to the RC's
  `ProcessId`.

Individual services are at liberty to configure their communications in
different ways, and publish rules to the RC which know how to handle them
(e.g. in `DeclareChannels`). This requires individual handling of such channels,
and complicates the picture of when exactly a service can be considered
to be 'running', as we have to wait for this subsequent exchange of messages.

In place of this, we propose something like this module signature:

```Haskell

-- | Message type hiding messages going from a service to the RC. The purpose
--   of this type is to allow `ruleServiceReceipt` to correctly interpret
--   messages from the service and pass them to other rules.
newtype ServiceMessage = forall a. ServiceMessage a

-- | Inteface used to communicate with a service.
--   `toSvc` covers the type of messages sent to a service.
--   `fromSvc` covers the type of messages received from a service.
data Interface toSvc fromSvc

-- | Send a message to a service via its interface.
sendSvc :: Interface toSvc a -> toSvc -> Process ()

-- | Send a persisted message from a service via its interface. The actual
--   message will be wrapped in `ServiceMessage`.
sendRC :: Interface a fromSvc -> fromSvc -> Process ()

-- | Receive a message at a service. The received message will be guaranteed to
--   be of an appropriate type and version to be handled by the service.
receiveSvc :: Interface toSvc a -> Process toSvc

-- | Receive a message at the RC. The received message will be guaranteed to
--   be of an appropriate type and version to be handled by the RC.
receiveRC :: Interface a fromSvc -> ServiceMessage -> Process fromSvc

-- | Allow us to look up the interface for a service. This prevents any need
--   to handle declaration of the interface or additional channels.
class HasInterface (Service a) toSvc fromSvc | a -> toSvc, a -> fromSvc
  getInterface :: Service a -> Interface toSvc fromSvc

-- | Receive `ServiceMessages` from a service and unwrap them with the help of
--   the appropriate interface.
ruleServiceReceipt :: Definitions RC ()
```

When starting a service, the service writer may dispatch messages from
`receiveSvc` in any way they see fit; thus it may utilise existing channels,
direct communication etc.

### Persisting messages

We have to be a little careful on how to handle persistence in presence of
`ServiceMessage` wrapper: persisting and acknowledging `ServiceMessage` is not
the same (from rule-writer standpoint) as persisting and acknowledging the
content.

The following scheme may work without being that awful and not requiring rules
to change what they are waiting for (while preserving semantics):

- HAEvent uid ServiceMessage comes in
- It is decoded to msg :: fromSvc for some service
- We call selfMessage $! HAEvent uid msg
- The rules call todo/done/messageProcessed and by proxy process ServiceMessage

If the RC restarts before all rules handle the content, ServiceMessage handler
rule will restart, decode and re-trigger rules; our previous fake HAEvent is not
persisted and is lost as desired.

### Replying to messages from ephemeral processes

Currently some messages from services specify a process id and expect a reply
directly to that process. There is no way of explicitly blocking this, but
these messages are not update safe. There are multiple ways of handling this:

- Disallow such communication.

- Allow individual services to declare reply types as part of their `toSvc`
  type. In this case, replies would be sent along with the destination
  `ProcessId` and dispatched by whatever functionality is handling
  `receiveSvc`.

- Add additional methods to the `Interface` module to explicitly handle
  sending messages to get replies. These would presumably wrap `ProcessId` in
  some other type and force replies to be sent via the interface.

Unfortunately, none of these methods provide any protection against resorting
to raw communication using `send`. As such, the second option probably presents
the best compromise between flexibility and verbosity.

## Sample implementation

We propose the following possible implementation of what `Interface` might
look like, for illuminatory purposes. The actual implementation may differ
from this.

```Haskell

newtype Version = Version Int

-- | Wire format in which we actually send messages. This must actually be
--   encoded in order to allow version migration.
data WireFormat = WireFormat ServiceName Version ByteString

data Interface toSvc fromSvc = Interface {
    -- | Version of the interface.
    ifVersion :: Version
    -- | Encode a message in a particular version. This must be lower or equal
    --   to the version of the node running the Interface.
  , ifEncodeToSvc :: Version -- ^ Version to encode to
                  -> toSvc -- ^ Message
                  -> Maybe WireFormat
  , ifDecodeToSvc :: WireFormat
                  -> Maybe toSvc
  , ifEncodeFromSvc :: Version -- ^ Version to encode to
                    -> fromSvc -- ^ Message
                    -> Maybe WireFormat
  , ifDecodeFromSvc :: WireFormat
                    -> Maybe fromSvc
    -- | Send a message to a service on a node.
  , sendToSvc :: NodeId -- ^ Node to send to
              -> String -- ^ Service label
              -> toSvc
              -> Process ()
    -- | Send a message to the RC.
  , sendToRc :: fromSvc -> Process ()
    -- | Negotiate which message version should be used in conversation with
    --   the service.
  , negotiateVersionRC :: NodeId
                       -> String -- ^ Service label
                       -> Process Version
    -- | Negotiate the version to be used when talking to the RC.
  , negotiateVersionSvc :: Process Version
}

```
A typical message flow might go like:
1. Negotiate the correct version between two endpoints.
2. Send a message in the negotiated version, performing conversion from
   running version using `ifConvert...`.
3. Receiver receives message in negotiated version, performing conversion to
   running version using `ifConert...`.

The negotiated version should always be the older version; thus, regardless of
which version is newer, translation should be done on the newer side since it
understands how to do so.
