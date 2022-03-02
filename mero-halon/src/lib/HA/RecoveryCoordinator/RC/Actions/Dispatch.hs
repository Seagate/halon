{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell  #-}
{-# LANGUAGE TypeOperators    #-}
-- |
-- Module    : HA.RecoveryCoordinator.RC.Actions.Dispatch
-- Copyright : (C) 2016-2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Generic phase dispatcher. This can be used to control the flow
-- of execution in a multi-phase rule without introducing
-- multiple similar phases.
module HA.RecoveryCoordinator.RC.Actions.Dispatch where

import           Control.Lens
import           Data.List (delete)
import           Data.Proxy
import           Data.Vinyl
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import           HA.RecoveryCoordinator.RC.Application (RC)
import           Network.CEP

-- | Holds dispatching information for complex jumps.
type FldDispatch = '("dispatch", Dispatch)

-- | An instance of 'FldDispatch'.
fldDispatch :: Proxy FldDispatch
fldDispatch = Proxy

-- | Dispatcher state, stores information about which phases remain to
-- be dispatched as well as what to do when we're finished or timeout.
data Dispatch = Dispatch {
    _waitPhases :: [Jump PhaseHandle]
    -- ^ Phases we're going to wait for on next dispatcher run.
  , _successPhase :: Jump PhaseHandle
    -- ^ If we're finished (no more '_waitPhases'), phase to run instead.
  , _timeoutPhase :: Maybe (Int, Jump PhaseHandle)
    -- ^ If we're waiting for '_waitPhases' too long, jump to this phase
    -- after after specified timeout instead.
}
makeLenses ''Dispatch

-- | Set the phase to transition to when all waiting phases have been
--   completed.
onSuccess :: forall a l. (Application a, FldDispatch ∈ l)
          => Jump PhaseHandle
          -> PhaseM a (FieldRec l) ()
onSuccess next =
  modify Local $ rlens fldDispatch . rfield . successPhase .~ next

-- | Set the phase to transition to on timeout, as well as how long to
--   wait for.
onTimeout :: forall a l. (Application a, FldDispatch ∈ l)
          => Int -- ^ Time to wait (seconds)
          -> Jump PhaseHandle -- ^ Phase to proceed to on timeout
          -> PhaseM a (FieldRec l) ()
onTimeout wait phase =
  modify Local $ rlens fldDispatch . rfield . timeoutPhase
                .~ (Just (wait, phase))

-- | Add a phase to wait for
waitFor :: forall a l. (Application a, FldDispatch ∈ l)
         => Jump PhaseHandle
         -> PhaseM a (FieldRec l) ()
waitFor p = modify Local $ rlens fldDispatch . rfield . waitPhases %~
  (p :)

-- | Announce that this phase has finished waiting and remove from dispatch.
waitDone :: forall a l. (Application a, FldDispatch ∈ l)
         => Jump PhaseHandle
         -> PhaseM a (FieldRec l) ()
waitDone p = modify Local $ rlens fldDispatch . rfield . waitPhases %~
  (delete p)

-- | Announce that we're not going to wait for any more phases with
-- this dispatcher. It's useful because it allows following scenario:
--
-- @
--  dispatcher <- 'mkDispatcher'
--  normal_run <- 'phaseHandle' "normal_run"
--  abort <- 'phaseHandle' "abort"
--  more_work <- 'phaseHandle' more_work
--
-- 'setPhase' normal_run $ \Foo -> do
--   …
--   -- We have completed all the expected work for this dispatcher
--   -- and want to proceed to success phase.
--   'waitClear'
--
-- 'setPhase' abort $ \Abort -> do
--   -- Do something exceptional
--   …
--   continue more_work
--
-- …
--
-- 'directly' run_dispatcher $ do
--   'waitFor' normal_run
--   'waitFor' abort_message
--   'onTimeout' t more_work
--   'onSuccess' more_work
--   'continue' dispatcher
--
-- 'directly' more_work $ …
--
-- 'start' run_dispatcher
-- @
--
-- With this approach, we can have extra phases to wait for and have
-- any of the phases decide that the work is over. In the example
-- above, @normal_run@ completes its work and determines we no longer
-- want to wait for @abort@ but has no explicit knowledge of it or any
-- other phases we may be waiting for.
--
-- Another use for 'waitClear' is if we want to re-use the dispatcher
-- but we're unsure or don't care how its last use ended. From the
-- example above, we have ran the dispatcher and we are now in
-- @more_work@: we could have gotten here either from @normal_run@ or
-- from @abort_message@. If we came from @abort_message@, we way well
-- still have @normal_run@ in the dispatcher state. If @more_work@
-- wants to use the dispatcher, perhaps for something completely
-- different, 'waitClear' can assure that such a potentially-unwanted
-- phase does not stick around.
waitClear :: forall a l. (Application a, FldDispatch ∈ l)
          => PhaseM a (FieldRec l) ()
waitClear = modify Local $ rlens fldDispatch . rfield . waitPhases .~ []

-- | Create the phase driving the dispatcher. Once you have populated
-- dispatcher fields (with 'waitFor' and similar helpers in this
-- module), you can start the dispatcher by running the phase provided
-- by 'mkDispatcher'. Typical use-case:
--
-- @
-- someRule :: 'Definitions' 'RC' ()
-- someRule = 'define' "someRule" $ do
--   rule_init <- 'phaseHandle' "rule_init"
--   worker <- 'phaseHandle' "worker"
--   worker_timed_out <- 'phaseHandle' "worker_timed_out"
--   worker_finished <- 'phaseHandle' "worker_finished"
--   dispatch <- 'mkDispatcher'
--
--  directly rule_init $ do
--    -- Do some stuff
--    'waitFor' worker
--    'onTimeout' 10 worker_timed_out
--    'onSuccess' worker_finished
--    'continue' dispatch
--
--  'setPhase' worker $ \_ -> …
--  'directly' worker_timed_out $ …
--  'directly' worker_finished $ …
--
--  'start' rule_init (args rule_init)
--  where
--    args start_ph = 'fldDispatch' '=:' 'Dispatch' [] start_ph 'Nothing'
-- @
--
-- [Dev note: @time_out_wrapper@] This wrapper is necessary to support
-- 'timeout' in phases passed to 'onTimeout'. Consider:
--
--     > 'onTimeout' 10 boring_phase
--     > 'onTimeout' 10 ('timeout' 20 foo)
--
--     In first case, the user would expect boring_phase to possibly fire
--     after 10 seconds. In second case however two things could happen:
--
--     * We try to fire @foo@ after 30 seconds.
--     * After 10 seconds we commit to possibly firing @foo@ after 20 seconds.
--
--     The second option is picked because it allows the user to use
--     'timeout' without worrying if underlying implementation uses
--     'timeout' and what will CEP do in this case.
mkDispatcher :: forall l. FldDispatch ∈ l
             => RuleM RC (FieldRec l) (Jump PhaseHandle)
mkDispatcher = do
  dispatcher <- phaseHandle "dispatcher::dispatcher"
  time_out_wrapper <- phaseHandle "dispatcher::time_out_wrapper"

  directly dispatcher $ do
    dinfo <- gets Local (^. rlens fldDispatch . rfield)
    Log.tagContext Log.Phase
      [ ("dispatcher:awaiting", show (dinfo ^. waitPhases))
      , ("dispatcher:onSuccess", show (dinfo ^. successPhase))
      , ("dispatcher:onTimeout", show (dinfo ^. timeoutPhase))
      ] Nothing
    case dinfo ^. waitPhases of
      [] -> continue $ dinfo ^. successPhase
      xs -> switch (xs ++ (maybe [] (\(t, _) -> [timeout t time_out_wrapper])
                           $ dinfo ^. timeoutPhase))

  directly time_out_wrapper $ do
    dinfo <- gets Local (^. rlens fldDispatch . rfield)
    case dinfo ^. timeoutPhase of
      Just (_, ph) -> continue ph
      -- This is a really unexpected case: the user somehow removed
      -- the phase from the dispatcher after we have sampled the time
      -- from accompanying information but before we entered the
      -- phase. Just yell loudly.
      _ -> Log.rcLog' Log.ERROR
        "Dispatcher in time_out_wrapper but no timeout phase set"

  return dispatcher
