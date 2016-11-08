{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeOperators #-}
-- |
-- Module    : HA.RecoveryCoordinator.Actions.Dispatch
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Generic phase dispatcher. This can be used to control the flow
-- of execution in a multi-phase rule without introducing
-- multiple similar phases.
module HA.RecoveryCoordinator.Actions.Dispatch where

import Network.CEP

import Control.Lens
import Data.List (delete)
import Data.Proxy
import Data.Vinyl

-- | Holds dispatching information for complex jumps.
type FldDispatch = '("dispatch", Dispatch)

-- | Field used to store the state of 'Dispatch'er being in use.
fldDispatch :: Proxy FldDispatch
fldDispatch = Proxy

-- | Dispatcher state, stores information about which phases remain to
-- be dispatched as well as what to do when we're finished or timeout.
data Dispatch = Dispatch
  { _waitPhases :: [Jump PhaseHandle]
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
onSuccess :: forall a l. (FldDispatch ∈ l)
          => Jump PhaseHandle
          -> PhaseM a (FieldRec l) ()
onSuccess next =
  modify Local $ rlens fldDispatch . rfield . successPhase .~ next

-- | Set the phase to transition to on timeout, as well as how long to
--   wait for.
onTimeout :: forall a l. (FldDispatch ∈ l)
          => Int -- ^ Time to wait (seconds)
          -> Jump PhaseHandle -- ^ Phase to proceed to on timeout
          -> PhaseM a (FieldRec l) ()
onTimeout wait phase =
  modify Local $ rlens fldDispatch . rfield . timeoutPhase
                .~ (Just (wait, phase))

-- | Add a phase to wait for
waitFor :: forall a l. (FldDispatch ∈ l)
         => Jump PhaseHandle
         -> PhaseM a (FieldRec l) ()
waitFor p = modify Local $ rlens fldDispatch . rfield . waitPhases %~
  (p :)

-- | Announce that this phase has finished waiting and remove from dispatch.
waitDone :: forall a l. (FldDispatch ∈ l)
         => Jump PhaseHandle
         -> PhaseM a (FieldRec l) ()
waitDone p = modify Local $ rlens fldDispatch . rfield . waitPhases %~
  (delete p)

-- | Create phase used by 'Dispatch'er.
mkDispatcher :: forall a l. (FldDispatch ∈ l)
             => RuleM a (FieldRec l) (Jump PhaseHandle)
mkDispatcher = do
  dispatcher <- phaseHandle "dispatcher::dispatcher"

  directly dispatcher $ do
    dinfo <- gets Local (^. rlens fldDispatch . rfield)
    phaseLog "dispatcher:awaiting" $ show (dinfo ^. waitPhases)
    phaseLog "dispatcher:onSuccess" $ show (dinfo ^. successPhase)
    phaseLog "dispatcher:onTimeout" $ show (dinfo ^. timeoutPhase)
    case dinfo ^. waitPhases of
      [] -> continue $ dinfo ^. successPhase
      xs -> switch (xs ++ (maybe [] ((:[]) . uncurry timeout)
                                    $ dinfo ^. timeoutPhase))

  return dispatcher
