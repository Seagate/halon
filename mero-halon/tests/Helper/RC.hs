-- |
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
--
module Helper.RC
  ( emptyLoopState
  ) where

import           Control.Distributed.Process
import           HA.Multimap
import           HA.RecoveryCoordinator.RC.Actions (LoopState(LoopState))
import qualified HA.RecoveryCoordinator.RC.Internal.Storage as Storage
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..))

import qualified Data.Map as Map

-- | Create initial 'LoopState' structure.
emptyLoopState :: StoreChan -> ProcessId -> Process LoopState
emptyLoopState mmchan pid = do
  rg' <- return . G.addRootNode Cluster =<< G.getGraph mmchan
  return $ LoopState rg' mmchan pid Map.empty Storage.empty
