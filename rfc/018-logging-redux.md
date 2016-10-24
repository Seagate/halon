# RFC: Logging, redux

## Introduction

RFC 012-decision-log introduced the decision log, a means to capture information
about the decisions being made by the Halon recovery co-ordinator. Whilst it has
been useful for analysis and debugging, said use has revealed various
deficiencies in its design and implementation. This RFC aims to re-design the
logging service to make it more suitable for future use.

## Purpose

The existing decision log has started to struggle with multiple issues:

* Logs are not written until the end of the phase. This means that if the phase
  terminates abruptly or hangs, logs are not recorded.

* Rules now have multiple phases which are often run a long time apart. Trying
  to follow a coherent thread throughout this is tricky and not always possible.

* Each rule runs as multiple state machines. Currently state machine identity
  is not tracked, making it harder to tie multiple phases together.

* Currently logs are very textual. This is insufficient to allow detailed
  analysis of the logs.

* As opposed to the initial conception, most logging has become explicit. This
  has the addition of making it inconsistent, since it depends upon the rule
  writer.

* There is no way to explicitly control logging levels. As such, log statements
  are removed for generating too much noise and must then be added in order
  to debug specific issues.

* Only events in the RC can currently be logged in the decision log. We may
  wish to extend this to other parts of the system.

## Design Principles

1. As much as possible we should aim to be backwards compatible with the existing
  decision log, both at the logging and viewing levels. Which is to say, log
  statements in the existing format should continue to work, and we should be able
  to produce a text log in the existing format.

1. Logs should be output in real time (even if they are not presented in this
  way.)

1. Logs should be resolved to strings at the last possible instance. This was
  also the intention with the previous design, but was not carried out.

1. One should be able to control the level of detail of logs at multiple
  granularities. For example, one might wish to view very detailed logging for
  a single rule, or for the CEP engine, or for a given drive.

## Design

In order to satisfy the "real-time" guarantee, we emit logging as single events
as soon as they are logged. This means that various information will be
duplicated; it is up to the decision log service to compress or reformat
these logging events for easier viewing.

The existing decision log format is specified exclusively in CEP, and its
language is specific to CEP (e.g. `phaseLog`). Whilst CEP provides the
"structure" within which the RC operates, it is too generic to capture details
which exist only in the mero-halon framwork.

To give an example: many of our rules are specific to a particular "scope", such
as a particular node or a particular process. One natural requirement is to want
to see all log entries related to a particular scope. It would thus be useful
to explicitly log this scope. This has nothing to do with CEP, and should not
be forced into the cep module.

The natural approach therefore is to allow the CEP logging structure to be
parametrised over the specific log structure needed by the application.

We therefore proceed by looking independently at what we would like to log
both in CEP and in the recovery co-ordinator.

## Producing logs

### CEP logging

The guiding principle for CEP logging should be able to capture the full thread
of rule processing. As such, we would like to log as much as possible the
internals events within CEP.

We suggest the following events as being emitted from CEP internals, along
with their context.

```haskell

-- | Used to document jumps. This is a restricted version of
--   'Network.CEP.Types.Jump PhaseHandle'
--   which can be easily displayed.
data Jump =
    NormalJump String
  | TimeoutJump Int String

-- | Identifies the location of a logging statement.
data Location = Location {
    loc_rule_name :: String
  , loc_sm_id :: Int64
  , loc_phase_name :: String
}

-- | Emitted when a call to 'fork' is made.
data Fork = Fork {
    f_location :: Location
  , f_buffer_type :: ForkType -- ^ How much of the buffer
                              --   should be copied to the child rule?
  , f_sm_child_id :: Int64 -- ^ ID of the child SM
}

data Continue = Continue {
    c_location :: Location
  , c_continue_phase :: Jump
}

data Switch = Switch {
    s_location :: Location
  , s_switch_phases :: [Jump]
}

-- | Emitted whenever a direct call to 'stop' is made, terminating the SM.
data Stop = Stop {
    sp_location :: Location
}

-- | Currently, whenever a rule "normally" terminates, it restarts at its
--   beginning phase. This event documents that.
data Restart = Restart {
    r_location :: Location
  , r_restarting_from_phase :: String
}

-- | Emitted whenever the body of a phase begins processing.
data PhaseEntry = PhaseEntry {
    pe_location :: Location
}

-- | Emitted whenever a legacy call to 'phaseLog' is made.
data PhaseLog = PhaseLog {
    pl_location :: Location
  , pl_key :: String
  , pl_value :: String
}

-- | Emitted whenever an application log is made from the underlying
--   application.
data ApplicationLog a = ApplicationLog {
    al_location :: Location
  , al_value :: a
}

```

#### Interpreting local state

It would be useful to implicitly log the local state of a rule. However, this
would require a `Show` (or similar) instance on local state, which would be too
constraining. Instead, we propose an additional instruction
`setLocalStateLogger` in the `RuleM` monad. This would serialise local state to
an `Environment`:

```haskell
type Environment = Map String String
```

If present, then we would additionally log local state at the following points:

* When entering a phase.
* When local state is updated via a `modify` call.

### Application logging

In addition to logging the CEP internals, we also wish to allow fine-grained,
strongly typed logging in the application. Since we expect the application to
expand, the idea is that we should expand our logging datatype correspondingly;
the types mentioned below are thus meant to be an initial set of possible
logging types.

We propose a restricted set of log levels, mostly because nobody can remember
what all of the normal levels are or in which way we should use them. Also, log
levels are a relatively crude way to group log statements; we propose to be
able to filter them using other data such as scope, and for these filters to be
more useful.

```haskell

data LogLevel =
    TRACE
  | DEBUG
  | WARN
  | ERROR

-- | Declare that a message has been promulgated.
data LogPromulgate = LogPromulgate TypeRep UUID

-- | Declare that an interest has been raised in a message.
data LogTodo = LogTodo UUID

-- | Declare that an interest has been satisfied in a message.
data LogDone = LogDone UUID

-- | Log that we are changing the state of an entity.
data LogStateChange a = LogStateChange {
    lsc_entity :: a
  , lsc_oldState :: StateCarrier a
  , lsc_newState :: StateCarrier a
}

-- | Log an "emvironment" - e.g. a mapping from keys to values. This should
--   be preferred to 'LogMessage', though it itself should be considered only
--   if more specific logging cannot be used. It may often be more appropriate
--   to associate much of an environment with a context - see 'TagContext'
--   below.
data LogEnv = LogEnv LogLevel Environment

-- | Log a location in source code. If used, it's expected that this will be
--   generated by some TH function.
data LogSourceLoc = LogSourceLoc {
    lsl_module :: String
  , lsl_line :: Int
}

-- | Basic "log a message" type. We would like to avoid resorting to this
--   where possible.
data LogMessage = LogMessage LogLevel String
```

#### Contexts

Here we wish to declare the context within which certain other logs apply.

```haskell

-- | Idea of a context for a log statement.
data Context =
    Rule -- ^ Relates to every instance of the rule.
  | SM -- ^ Relates to the whole SM.
  | Phase -- ^ Relates to the current phase.
  | Local UUID -- ^ Relates to some local scope.

-- | Begins a "local" context.
data BeginLocalContext = BeginLocalContext UUID

-- | Ends a "local" context.
data EndLocalContext = EndLocalContext UUID

-- | Used to associate data with a context.   
data TagContext a = TagContext {
    tc_context :: Context
  , tc_data :: a
  , tc_msg :: Maybe String -- ^ Optional message describing the environment.
}

```

In particular, we would like to tag a context with a "scope", such that we can
see for example which node a log message is associated with. So we additionally
propose the following:

```haskell

-- | Possible scopes with which one can tag a context. These should be used to
--   help in debugging particular subsets of the system.
data Scope =
    Thread UUID -- ^ Tag a "thread" of processing. This could be used to
                     --   group multiple rules all driven from a single message.
  | Node (Res.Node) -- ^ Associated node
  | StorageDevice UUID -- ^ Associated storage device.
  | MeroConfObj Fid -- ^ Associated Mero configuration object.
  | RCLocation (Res.Node) -- ^ Location of the recovery co-ordinator.

data TagContent =
    TagScope [Scope] -- ^ Tag context with a set of scopes.
  | TagEnv Env -- ^ Tag context with a general environment.
  | TagString String -- ^ Associate an arbitrary message with a context.

```

We may then restrict to considering `TagContext TagContent`.

## Consuming logs

So far we have covered producing logs. The other side is how we should consume
them. Again, the principle is to be as general as possible for as long as
possible. Thus the preceding log types should be sent to the decision log
service as is, and if preferable recorded into a compressed binary format which
retains typing information. Logs should be recorded in the fist instance as
events, as they are emitted.

Log rotation could either be a matter for the decision log service or an
external service such as logrotate. The latter should probably be our initial
approach, though there are benefits to handling it internally, such as being
able to differentially age off old logs; retaining important details,
for example, whilst overwriting old CEP internal logs and "debug" messages.

We should introduce an external program to handle converting these binary logs
into more readable formats. This program should at a minimum be capable of:

- Replicating the current log format by extracting a subset of messages and
  formatting them as at present. It may be worth including handling for some of
  the newer event types such as `LogEnv` as we begin to use them in rules.

- Outputting the live event stream in a textual format.

In addition, we would want to develop this to be able to properly sessionise
events and selectively group them according to SM, scope etc.
