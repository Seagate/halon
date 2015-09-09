{-# LANGUAGE GADTs      #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
--
module Network.CEP.Testing
  ( runPhase ) where

import Network.CEP.Buffer
import Network.CEP.Phase (PhaseOut(SM_Complete), runPhaseM)
import Network.CEP.Types

import Control.Distributed.Process

import Data.Maybe (catMaybes)
import qualified Data.MultiMap as MM

runPhase :: forall g l. g       -- ^ Global state.
         -> l                   -- ^ Local state
         -> Buffer              -- ^ Buffer
         -> PhaseM g l ()       -- ^ Phase to exec
         -> Process (g, [(Buffer, l)])      -- ^ Updated global and local state
runPhase g l b p = do
    (g', xs) <- runPhaseM "testing" MM.empty Nothing g l b p
    return (g', catMaybes $ fmap extract xs)
  where
    extract (b', po) = case po of
      SM_Complete l' _ _ -> Just (b',l')
      _ -> Nothing
