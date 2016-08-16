{-# LANGUAGE LambdaCase #-}
-- |
-- Copyright : (C) 2016 Xyratex Technology Limited.
-- License   : All rights reserved.
--
module HA.RecoveryCoordinator.RC.Actions
  ( getCurrentRC
  , makeCurrentRC
  ) where

import           HA.RecoveryCoordinator.Actions.Core
import           HA.Resources.RC

import qualified HA.ResourceGraph    as G
import qualified HA.Resources        as R
import qualified HA.Resources.Castor as R
import           Network.CEP

import Control.Category
import Data.Maybe (listToMaybe)
import Prelude hiding (id, (.))

-- | Current RC.
currentRC :: RC
currentRC = RC 0 -- XXX: use version from the package/git version info?

-- | 'getCurrentRC', fails if no active RC exists.
getCurrentRC :: PhaseM LoopState l RC
getCurrentRC = tryGetCurrentRC >>= \case
  Nothing -> error "Can't find active rc in the graph"
  Just x  -> return x

-- | Create new recovery coordinator in the graph if needed. If previously
-- graph contained old RC - update handler is called @update oldRC newRC@.
-- Old RC is no longer connected to the root of the graph, so it may be garbage
-- collected after calling upate handler.
makeCurrentRC :: (RC -> RC -> PhaseM LoopState l ()) -> PhaseM LoopState l RC
makeCurrentRC update = do
  mOldRC <- tryGetCurrentRC
  case mOldRC of
    Nothing -> mkRC
    Just old
      | old == currentRC ->
         return ()
      | otherwise -> do
         mkRC
         update old currentRC
  return currentRC
  where
    mkRC = modifyGraph $ \g ->
      let g' = G.newResource currentRC
           >>> G.newResource Active
           >>> G.connectUnique R.Cluster R.Has currentRC
           >>> G.connectUnique currentRC R.Is  Active
             $ g
      in g'


tryGetCurrentRC :: PhaseM LoopState l (Maybe RC)
tryGetCurrentRC = do
  rg <- getLocalGraph
  return $ listToMaybe [ rc
                       | rc <- G.connectedTo R.Cluster R.Has rg :: [RC]
                       , G.isConnected rc R.Is Active rg
                       ]


