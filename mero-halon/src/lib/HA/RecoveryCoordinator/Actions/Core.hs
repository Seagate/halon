-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE CPP                        #-}
{-# LANGUAGE OverloadedStrings          #-}

module HA.RecoveryCoordinator.Actions.Core
  ( LoopState(..)
  , knownResource
  , registerNode
  , getLocalGraph
  , putLocalGraph
  , modifyGraph
  , modifyLocalGraph
  ) where

import qualified HA.ResourceGraph as G
import HA.Resources
  ( Cluster(..)
  , Has(..)
  , Node
  )

import HA.EventQueue.Types
import HA.Service (ServiceName)


import Control.Category ((>>>))
import Control.Distributed.Process (ProcessId)

import qualified Data.Map.Strict as Map
import qualified Data.Set        as S

import Network.CEP

#ifdef USE_MERO
import Network.RPC.RPCLite
#endif

data LoopState = LoopState {
    lsGraph    :: G.Graph -- ^ Graph
  , lsFailMap  :: Map.Map (ServiceName, Node) Int
    -- ^ Failed reconfiguration count
  , lsMMPid    :: ProcessId -- ^ Replicated Multimap pid
  , lsHandled  :: S.Set UUID
    -- ^ Set of HAEvent uuid we've already handled.
#ifdef USE_MERO
  , lsRPCAddress :: Maybe RPCAddress
    -- ^ 'RPCAddress' that listener should start on if one does not exist yet
#endif
}

-- | Is a given resource existent in the RG?
knownResource :: G.Resource a => a -> PhaseM LoopState l Bool
knownResource res = fmap (G.memberResource res) getLocalGraph

-- | Register a new satellite node in the cluster.
registerNode :: Node -> PhaseM LoopState l ()
registerNode node = modifyLocalGraph $ \rg -> do
    phaseLog "rg" $ "Registering satellite node: " ++ show node

    let rg' = G.newResource node >>>
              G.connect Cluster Has node $ rg

    return rg'

getLocalGraph :: PhaseM LoopState l G.Graph
getLocalGraph = fmap lsGraph $ get Global

putLocalGraph :: G.Graph -> PhaseM LoopState l ()
putLocalGraph rg = modify Global $ \ls -> ls { lsGraph = rg }

modifyGraph :: (G.Graph -> G.Graph) -> PhaseM LoopState l ()
modifyGraph k = modifyLocalGraph $ return . k

modifyLocalGraph :: (G.Graph -> PhaseM LoopState l G.Graph) -> PhaseM LoopState l ()
modifyLocalGraph k = do
    rg  <- getLocalGraph
    rg' <- k rg
    putLocalGraph rg'
