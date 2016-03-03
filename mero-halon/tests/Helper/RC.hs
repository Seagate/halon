-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
--
{-# LANGUAGE CPP #-}
module Helper.RC
  ( emptyLoopState
  ) where

import HA.RecoveryCoordinator.Actions.Core
import Control.Distributed.Process
import HA.Resources
import HA.Multimap
import HA.ResourceGraph
#if USE_MERO
import Mero.M0Worker
#endif

import qualified Data.Map as Map

-- | Create initial 'LoopState' structure.
#if USE_MERO
emptyLoopState :: StoreChan -> ProcessId -> Process LoopState
emptyLoopState mmchan pid = do
  wrk <- liftIO $ dummyM0Worker
  g' <- getGraph mmchan >>= return . addRootNode Cluster
  return $ LoopState g' Map.empty mmchan pid Map.empty [] wrk
#else
emptyLoopState :: StoreChan -> ProcessId -> Process LoopState
emptyLoopState mmchan pid = do
  g' <- getGraph mmchan >>= return . addRootNode Cluster
  return $ LoopState g' Map.empty mmchan pid Map.empty
#endif
