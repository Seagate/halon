{-# LANGUAGE GADTs      #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
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
import qualified Data.IntPSQ as PSQ
import qualified Data.Map as MM
import qualified Control.Monad.State.Strict as State

runPhase :: forall app g l. (Application app, g ~ GlobalState app)
         => g       -- ^ Global state.
         -> l                   -- ^ Local state
         -> Buffer              -- ^ Buffer
         -> PhaseM app l ()       -- ^ Phase to exec
         -> Process (g, [(Buffer, l)])      -- ^ Updated global and local state
runPhase g l b p = do
    (xs, (EngineState _ _ _ g')) <- State.runStateT (runPhaseM "testing" "testing" MM.empty Nothing 0 l Nothing b p)
                                    (EngineState 1 0 PSQ.empty g)
    return (g', catMaybes $ fmap extract (snd <$> xs))
  where
    extract (b', po) = case po of
      SM_Complete l' _ -> Just (b',l')
      _ -> Nothing

-- | Run a phase for its result, discarding any changes made to global state.
runPhaseGet :: forall app g a. (Application app, g ~ GlobalState app)
            => g
            -> PhaseM app (Maybe a) a
            -> Process a
runPhaseGet g p = do
    (_, xs) <- runPhase g Nothing emptyFifoBuffer augPhase
    return . head . catMaybes . fmap snd $ xs
  where
    augPhase = p >>= put Local . Just
