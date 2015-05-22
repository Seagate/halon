-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE OverloadedStrings          #-}

module HA.RecoveryCoordinator.Actions.Core
  ( LoopState(..)
  , knownResource
  , registerNode
  , getLocalGraph
  , putLocalGraph
  , modifyLocalGraph
  ) where

import qualified HA.ResourceGraph as G
import HA.Resources
  ( Cluster(..)
  , Has(..)
  , Node
  )
import HA.Service (ServiceName)


import Control.Category ((>>>))
import Control.Distributed.Process (ProcessId)

import qualified Data.Map.Strict as Map

import Network.CEP

data LoopState = LoopState {
    lsGraph    :: G.Graph -- ^ Graph
  , lsFailMap  :: Map.Map (ServiceName, Node) Int
    -- ^ Failed reconfiguration count
  , lsMMPid    :: ProcessId -- ^ Replicated Multimap pid
}

-- | Is a given resource existent in the RG?
knownResource :: G.Resource a => a -> PhaseM LoopState Bool
knownResource res = fmap (G.memberResource res) getLocalGraph

-- | Register a new satellite node in the cluster.
registerNode :: Node -> PhaseM LoopState ()
registerNode node = modifyLocalGraph $ \rg -> do
    phaseLog "rg" $ "Registering satellite node: " ++ show node

    let rg' = G.newResource node >>>
              G.connect Cluster Has node $ rg

    return rg'

getLocalGraph :: PhaseM LoopState G.Graph
getLocalGraph = fmap lsGraph get

putLocalGraph :: G.Graph -> PhaseM LoopState ()
putLocalGraph rg = modify $ \ls -> ls { lsGraph = rg }

modifyLocalGraph :: (G.Graph -> PhaseM LoopState G.Graph) -> PhaseM LoopState ()
modifyLocalGraph k = do
    rg  <- getLocalGraph
    rg' <- k rg
    putLocalGraph rg'
