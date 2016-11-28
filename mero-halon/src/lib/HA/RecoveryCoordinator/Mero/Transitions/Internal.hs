{-# LANGUAGE FlexibleContexts #-}
-- |
-- Module    : HA.RecoveryCoordinator.Mero.Transitions.Internal
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
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
import GHC.SrcLoc
import GHC.Stack
import HA.Resources.Mero.Note
import Text.Printf

data TransitionResult a = TransitionTo (StateCarrier a)
                        | NoTransition
                        | InvalidTransition (a -> String)
  deriving (Generic, Typeable)

newtype Transition a = Transition
  { _unTransition :: StateCarrier a -> TransitionResult a
  } deriving (Generic, Typeable)

runTransition :: Eq (StateCarrier a) => Transition a -> StateCarrier a
              -> TransitionResult a
runTransition (Transition runTr) st = case runTr st of
  TransitionTo st' -> if st == st' then NoTransition else TransitionTo st'
  r -> r

constTransition :: Eq (StateCarrier a) => StateCarrier a -> Transition a
constTransition st = Transition $ \st' -> if st == st' then NoTransition
                                                       else TransitionTo st

transitionErr :: (Show (StateCarrier a), ShowFidObj a)
              => CallStack -- ^ Location where transition was used
              -> StateCarrier a -- ^ State we received
              -> TransitionResult a
transitionErr cs st = InvalidTransition $ \obj ->
  printf "%s: transition from %s is invalid%s" (showFid obj) (show st) locInfo
  where
    -- Find last call-site: this should have been the direct use of
    -- transition itself.
    locInfo = case reverse $ getCallStack cs of
      (_, loc) : _ -> " (" ++ showSrcLoc loc ++ ")"
      _ -> ""
