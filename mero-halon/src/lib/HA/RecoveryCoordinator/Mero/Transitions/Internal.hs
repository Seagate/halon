{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE StrictData #-}
-- |
-- Module    : HA.RecoveryCoordinator.Mero.Transitions.Internal
-- Copyright : (C) 2016-2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Internal-use types for 'Transition's. Users should not import this
-- module.
module HA.RecoveryCoordinator.Mero.Transitions.Internal
  ( Transition(..)
  , TransitionResult(..)
  , constTransition
  , runTransition
  , transitionErr
  ) where

import Data.Typeable
import GHC.Generics
import GHC.Stack
import HA.Resources.Mero.Note
import Text.Printf

-- | Result of a 'Transition' applied to some 'StateCarrier'.
data TransitionResult a =
  TransitionTo (StateCarrier a)
  -- ^ The transition resulted in the given 'StateCarrier', this
  -- should be the new object state.
  | NoTransition
  -- ^ No transition is necessary. Commonly it means the object is
  -- already in the expected state but it shouldn't be assumed that
  -- was the case.
  | InvalidTransition (a -> String)
  -- ^ The requested 'Transition' is not valid from the given state.
  -- Provide an object to generate a useful warning message.
  deriving (Generic, Typeable)

-- | A 'Transition' describes a function from a 'StateCarrier' to
-- potentially new 'StateCarrier' (but see 'TransitionResult').
newtype Transition a = Transition
  { _unTransition :: StateCarrier a -> TransitionResult a
  -- ^ Apply the transition to a state.
  } deriving (Generic, Typeable)

-- | Run the given transition on the given state. If the result of the
-- transition is the same as the input state, return 'NoTransition'.
runTransition :: Eq (StateCarrier a) => Transition a -> StateCarrier a
              -> TransitionResult a
runTransition (Transition runTr) st = case runTr st of
  TransitionTo st' | st == st' -> NoTransition
                   | otherwise -> TransitionTo st'
  r -> r

-- | Unconditionally (i.e. regardless of current state) perform a
-- transition on the object to the given state. Note that
-- @runTransition (constTransition x) x@ is still 'NoTransition'.
constTransition :: Eq (StateCarrier a) => StateCarrier a -> Transition a
constTransition st = Transition $ \_ -> TransitionTo st

-- | Create an 'InvalidTransition' result with source location and
-- current object state.
transitionErr :: (Show (StateCarrier a), ShowFidObj a)
              => CallStack -- ^ Location where transition was used
              -> StateCarrier a -- ^ State we received
              -> TransitionResult a
transitionErr cs st = InvalidTransition $ \obj ->
  printf "%s: transition from %s is invalid (%s)" (showFid obj) (show st) locInfo
  where
    -- Find last call-site: this should have been the direct use of
    -- transition itself.
    locInfo = case reverse $ getCallStack cs of
      (_, loc) : _ -> prettySrcLoc loc
      _ -> "no loc"
