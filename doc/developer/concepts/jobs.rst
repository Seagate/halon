Concepts: Jobs
==============

Jobs provide a way to generate a specific type of rule, automating some
boilerplate. In particular, jobs are often useful in writing what would
otherwise be an asynchronous action.

Motivation
----------

Actions (see :doc:`Decision Log <decision-log>`) are re-usable functions
which can be called from within rules. However, they must complete within the
scope of a phase, and so cannot perform operations requiring multiple steps or
which must wait for replies from some other part of the system.

Jobs are a solution to this, where we have an action we wish to carry out
asynchronously, and which span multiple phases. Jobs provide the essential
machinery for such a thing, providing:

- A convenient means to invoke such an action.
- A defined input and output type for the action.

Additionally, when such actions are run asynchronously, one wants to ensure that
the same action is not run multiple times concurrently. Jobs provide this
guarantee.

Definition
----------

Each job has an input and output type. The job is triggered through receipt of
an event of the input type, and will emit the output type when it finishes.
Input types must be instances of `Eq` - if the same input event is sent multiple
times, only one instance of the job will run.

A Job has, in addition to its rule declaration, a `Job` name. This serves to
provide type checking guarantees on the input and output types to the job.

Thus, a typical job declaration might look like:

.. code-block:: haskell

   -- | Job handle for @ruleProcessAdd@
   jobProcessAdd :: Job ProcessAddRequest ProcessAddResult
   jobProcessAdd = Job "castor::process::add"

   -- | Add a process to a running system.
   ruleProcessAdd :: Definitions RC ()
   ruleProcessAdd = mkJobRule jobProcessAdd args $ \(JobHandle getRequest finish) -> do

The `JobHandle` argument which gets passed to the body of the rule can be used
to retrieve the request in the scope of the job.
