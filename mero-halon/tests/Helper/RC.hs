-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
--
module Helper.RC
  ( emptyLoopState
  ) where

import HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Internal.Storage as Storage
import Control.Distributed.Process
import HA.Resources
import HA.Multimap
import HA.ResourceGraph

import qualified Data.Map as Map

-- | Create initial 'LoopState' structure.
emptyLoopState :: StoreChan -> ProcessId -> Process LoopState
emptyLoopState mmchan pid = do
  g' <- getGraph mmchan >>= return . addRootNode Cluster
  return $ LoopState g' mmchan pid Map.empty Storage.empty
