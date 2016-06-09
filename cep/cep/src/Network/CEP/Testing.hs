{-# LANGUAGE GADTs      #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
--
module Network.CEP.Testing
  ( runPhase
  , runPhaseGet
  ) where

import Network.CEP.Buffer
import Network.CEP.Phase (PhaseOut(SM_Complete), runPhaseM)
import Network.CEP.Types

import Control.Distributed.Process

import Data.Maybe (catMaybes)
import qualified Data.MultiMap as MM
import qualified Control.Monad.State.Strict as State

runPhase :: forall g l. g       -- ^ Global state.
         -> l                   -- ^ Local state
         -> Buffer              -- ^ Buffer
         -> PhaseM g l ()       -- ^ Phase to exec
         -> Process (g, [(Buffer, l)])      -- ^ Updated global and local state
runPhase g l b p = do
    (xs, g') <- State.runStateT (runPhaseM "testing" MM.empty Nothing l Nothing b p) g
    return (g', catMaybes $ fmap extract xs)
  where
    extract (b', po) = case po of
      SM_Complete l' _ _ -> Just (b',l')
      _ -> Nothing

-- | Run a phase for its result, discarding any changes made to global state.
runPhaseGet :: forall g a. g
            -> PhaseM g (Maybe a) a
            -> Process a
runPhaseGet g p = do
    (_, xs) <- runPhase g Nothing emptyFifoBuffer augPhase
    return . head . catMaybes . fmap snd $ xs
  where
    augPhase = p >>= put Local . Just
