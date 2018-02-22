Component: Recovery Coordinator
===============================

The :abbr:`RC (recovery coordinator)` is the "brain" of halon. It handles all
the incoming events from various sensors around the cluster and sent to the
:ref:`event-queue`, integrates that information with known cluster state in the
:ref :`resource-graph`, and takes actions through the various interfaces
available.

Overview
--------

The majority of recovery coordinator code lives in the `mero-halon` package, in
`src/Lib/HA/RecoveryCoordinator`. In general, we split RC code into three
sections: rules, actions and events.

Rules
-----

Rules are conceptual units of logic which we hope correspond to specific failure
cases or management requirements. Where possible, rules are broken down
according to system component (or cluster topology); as such, we have rules for
disks, rules for expanders, rules for nodes, or even rules for the entire
cluster.

A rule can be thought of as a state machine (formally, a Mealy machine) whose
inputs are the set of events in the event queue and the rule state, and
whose outputs are the set of possible actions available to the system (including
updating the resource graph).

Each rule is defined by a name, which should be unique and will show up in the
decision log.

A rule may have multiple instances. By default, a single instance of a rule is
started by the CEP engine on startup, but may fork to create another copy. This
is used to handle processing of the same rule for multiple components in
parallel. For example, we may want to support multiple drives failing at any
given point.

Phases
~~~~~~

A rule consists of multiple phases. At any given time, a rule will be either:

- In a specified phase
- Waiting on some specified input to enter a phase.
- Waiting on multiple inputs. Depending on the input received, one of multiple
  phases may be entered.

Input may consist of events (either persisted events from the EQ or events
sent directly to the RC), events predicated upon some condition, or timer
expiry.[1]_

Due to a limitation of the engine, phases must be declared (which creates a
`PhaseHandle`) and this handle must then be bound to a phase action (something
of type `PhaseM ...`). In code, this looks like the following:

```Haskell
example_handle <- phaseHandle "example_handle"

directly example_handle $ do
  Log.rcLog' Log.DEBUG "Now in phase example_handle"
```

CEP (and Halon atop it) provides multiple ways to bind a `PhaseM` block to a
handle, corresponding to the "guard" to enter that phase:

- `directly` sets a phase to run without any conditions.
- `setPhase` sets a phase to run when a specific _type_ of message arrives. The
  message will be provided as input to the phase.
- `setPhaseIf` sets a phase to run when a specific type of message satisfying a
  predicate arrives. This is often used when, for example, we have multiple
  instances of a rule, each handling processing for a single node or drive. We
  use `setPhaseIf` to only collect the incoming messages appropriate to that
  node or disk.
- `setPhaseNotified`, `setPhaseInternalNotification` etc are used to guard
  a phase on the successful transition of an entity in the resource graph to a
  new state.

There are others; look to their documentation for details of use.

Additionally, there are some helpers to define single-phase rules:

- `defineSimple` defines a single-phase rule which waits for any message of a
  given type.
- `defineSimpleIf` defines a single-phase rule which waits for a message of a
  given type satisfying a predicate.

State
~~~~~

Rules have associated state, which can be divided into two:

- Global state is shared between all rules and all instances of rules. The
  global state for the recovery coordinator is defined by the `LoopState` type
  in `/mero-halon/src/lib/HA/RecoveryCoordinator/RC/Application.hs` and consists
  of the resource graph and a few other details.
- Local state is specific to each instance of a rule. It is used to store data
  required by multiple phases of a rule.

Actions
-------

Actions are fragments of logic designed to be embedded in phases. They should
be thought of as helper functions for rules. Actions should also be categorised
by the component they (chiefly) refer to, and current style holds to design
modules containing actions to be imported qualified; see, for example,
`/mero-halon/src/lib/HA/RecoveryCoordinator/Hardware/StorageDevice/Actions.hs`.

Local State
~~~~~~~~~~~

Actions may require access to local state, but in order to be shared between
multiple rules, we want to put as few constraints on that local state as
possible. Haskell records do not natively support row- or sub-typing, so we
have a couple of options:

- Leave a universally quantified local state `l`, but require an additional
  argument providing a `Lens` from `l` to the required state:
  ```Haskell
  mkSyncAction :: Lens' l ConfSyncState
               -> Jump PhaseHandle
               -> RuleM RC l (SyncToConfd -> PhaseM RC l ())
  ```
- Use `vinyl` records, which provide subtyping, and add a constraint on
  field membership:
  ```Haskell
  onSuccess :: forall a l. (Application a, FldDispatch ∈ l)
            => Jump PhaseHandle
            -> PhaseM a (FieldRec l) ()
  ```

Both of these forms are used in Halon code, but the `vinyl` approach is used
more widely and should probably be preferred. Multiple examples are available in
existing code (just search for "Lens'" or "∈" respectively).

Events
------

Events are the messages sent to the RC which drive the state machine. Events may
either be persisted via the event queue, or may be sent directly to the RC, as
often happens when those events are themselves sent *by* the RC. Common
behaviour may have a single event sent from e.g. SSPL trigger a rule which
itself sends multiple internal messages to start other rules. The original rule
may wait for the completion of these other rules, indicated by sending further
events.

Care should be given when deciding whether to send events via the persistent EQ
(using `promulgateRC`) or directly (using `usend` and the `ProcessID`) of the
RC. Direct messages may be lost, and will not be resent if the RC dies during
handling. It's also important to note that the RC differentiates between
receiving messages from the EQ and receiving messages directly - a phase
must choose to wait for either `HAEvent a` or `a`, and it is a common mistake
to pick the wrong one and then fail to see a phase being triggered.


Further Reading
---------------

For the design philosophy behind CEP, see
:ref:`../../../rfc/013-recovery-coordinator.md`

For details on logging to the decision log within the RC, see
:ref:`../../../rfc/018-logging-redux.md`

.. [1] More complex inputs are theoretically possible (and were one of the
   original design intentions), but almost never used inside Halon.
