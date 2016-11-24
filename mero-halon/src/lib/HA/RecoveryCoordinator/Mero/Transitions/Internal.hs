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
  ) where

import Data.Typeable
import GHC.Generics
import HA.Resources.Mero.Note

data TransitionResult a = TransitionTo a
                        | NoTransition
                        | InvalidTransition String
  deriving (Show, Eq, Ord, Generic, Typeable)

newtype Transition a = Transition
  { runTransition :: StateCarrier a -> TransitionResult (StateCarrier a)
  } deriving (Generic, Typeable)

constTransition :: Eq (StateCarrier a) => StateCarrier a -> Transition a
constTransition st = Transition $ \st' -> if st == st' then NoTransition
                                                       else TransitionTo st
