# RFC: Decision Log

## Introducion

This document aims to define the most important aspects of a decision log and
proposes ways to implement it.

## Purpose

We need to log what decision Halon is taking for debug and analysis purposes.
This is separate from any internal logging messages, or the interesting event
messages which might be sent back to Seagate.

## Naming

From now Decision Log will be referred as dlog.

## Constraints

* Analysing dlog entries should be easy and fast. Each entry should be strongly
  typed.

* We should support mulitple and generic backends for the dlog. Those backends
  should be configurable. Their instantiation routine should be easy to
  integrate in Halon system.

* An entry should carry the context in which it has been created.

* The mechanism of sending entries to dlog should be fully integrated with CEP
  library. This means:
    - A rule writer shouldn't have to explicitly send entries to the dlog.

    - A rule writer should be able to choose the context of an event.

    - Each CEP rule should make precisely one entry into the dlog.

## Implementation

#### Dlog process itself

we propose to implement main dlog logic using CEP library, in order to be able
to add extra context, possibly time varying, information. Dlog process should be
implemented as a Halon service. That way we will have automatic restart on
failure and resource management for free. It's backend configuration would be
defined in the service schema. We will have a consistent configuration
management whatever backend we are going to use.

#### Auto-generation of inputs

CEP rules have 2 different types of input:

1. Event input: The event received by the `Process` mailbox. In our context, it
   would concern `HAEvent`. We can then display its `EventId`, a payload (we
   expect it to be `Serializable`) and its hops as `[ProcessId]`. We suggest to
   print those pieces of information in this form:
   `${haevent-field-name}=${field-value};`. Each field value would be rendered
   using its `Binary` instance.

2. Netwire rule output: a Netwire rule can transform its initial input for
   something more meaningful for its exploitation. That output is expected to be
   `Serializable`, so its rendering would use its `Binary` instance. Considering
   that quite often, in current RC rule definition, Netwire rule doesn't change its
   initial input. That might produce duplicate data for no benefit. In this case
   we suggest to use the Netwire rule output `Typeable` instance, by producing
   a `TypeRep` and compare it to initial input `TypeRep`. When those `TypRep`
   are equal, we don't render Netwire rule output. In the case we render the
   Netwire rule output, we suggest to adopt that format.
   `rule-output=${rule-output-value}`

Both event input and Netwire rule output would be rendered and passed to the
`onLog` described below.

#### on Rule declaration side

Entry sending to dlog shouldn't be directly implemented in CEP library.
That will prevent us from implementing dlog process with CEP. Yet, in order
to provide in middle of a rule logging, we suggest to implement the
`log` function. `CEP` monad will carry an extra state that would be the log
gathered along the rule execution.

```haskell

data Log =
    Log
    { logCtx :: !ByteString
    , logTxt :: !ByteString
    }

data RuleState s =
    RuleState
    {
    …
    cepLog :: Data.Sequence Log
    …
    }
```

Here's a possible signature for `log` function:

```haskell
log :: ByteString -- ^ Log context
    -> ByteString -- ^ Log text
    -> CEP s ()
```

`cepLog` would only have the scope of the rule. It will be reseted to empty
at the rule execution end. Considering that CEP rule are now identifiable, we
could add the rule executed along the produced log.

We could also have more meaningful log value with a different `log` signature:

```haskell
log :: Serializable a
    => ByteString
    -> a
    -> CEP s ()
```

`Log` definitions changes a bit:

```haskell
data Log =
    forall a. Serializable a =>
    Log
    { logCtx   :: !ByteString
    , logValue :: !a
    }
```

We propose to add a new CEP primitive named `onLog`

```haskell
onLog :: (ByteString -> ByteString -> Data.Sequence Log -> Process ()) -> RuleM s ()
```

`onLog` would accept an action to perform everytime the log isn't empty. The
name of the triggered rule would also be accessible. We would also pass the pre-
rendered event input and Netwire rule output. Sending produced log to
dlog would be easily doable with this function.

We can also enforce the fact that log collection would be non empty by either
switching to:

```haskell
onLog :: (ByteString, ByteString -> NonEmpty Log -> Process ()) -> RuleM s ()
```

or for something more general:

```haskell
onLog :: (forall f. Foldable1 f => ByteString -> ByteString -> f Log -> Process ()) -> RuleM s ()
```

The signature of that function is left at the discretion of the implementor.

#### Entry storage

Entries should be persisted. We aim for supporting different backends that
handle storage. The simplest backend we could implement would be having
everything written in a file (that would be configurable, through Service
schema). That backend will always write at the end of the file buffer. More
involve strategy could be added. File format would be very simple. Every entry
would be seperated by an new line and the format of the data would be defined
the `Binary` instances of the log value.

```
${rule-name}:${log-value}\n
```