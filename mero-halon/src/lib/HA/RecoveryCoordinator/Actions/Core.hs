-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE OverloadedStrings          #-}

module HA.RecoveryCoordinator.Actions.Core
  ( LoopState(..)
  , knownResource
  , registerNode
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
import qualified Control.Monad.State.Strict as State

import qualified Data.Map.Strict as Map

import Network.CEP

data LoopState = LoopState {
    lsGraph    :: G.Graph -- ^ Graph
  , lsFailMap  :: Map.Map (ServiceName, Node) Int
    -- ^ Failed reconfiguration count
  , lsMMPid    :: ProcessId -- ^ Replicated Multimap pid
}

-- | Is a given resource existent in the RG?
knownResource :: G.Resource a => a -> CEP LoopState Bool
knownResource res = State.gets (G.memberResource res . lsGraph)

-- | Register a new satellite node in the cluster.
registerNode :: Node -> CEP LoopState ()
registerNode node = do
    cepLog "rg" $ "Registering satellite node: " ++ show node
    rg <- State.gets lsGraph

    let rg' = G.newResource node                       >>>
              G.connect Cluster Has node $ rg

    State.modify $ \ls -> ls { lsGraph = rg' }
