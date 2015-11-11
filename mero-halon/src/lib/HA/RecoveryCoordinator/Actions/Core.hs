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
  , modifyGraph
  , modifyLocalGraph
  , syncGraph
  , messageProcessed
  , sayRC
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
import Control.Distributed.Process
  ( ProcessId
  , Process
  , usend
  , say
  )

import qualified Data.Map.Strict as Map
import qualified Data.Set        as S

import Network.CEP

data LoopState = LoopState {
    lsGraph    :: G.Graph -- ^ Graph
  , lsFailMap  :: Map.Map (ServiceName, Node) Int
    -- ^ Failed reconfiguration count
  , lsMMPid    :: ProcessId -- ^ Replicated Multimap pid
  , lsEQPid    :: ProcessId -- ^ EQ pid
  , lsHandled  :: S.Set UUID
    -- ^ Set of HAEvent uuid we've already handled.
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

-- | Explicitly syncs the graph to all replicas
syncGraph :: PhaseM LoopState l ()
syncGraph = modifyLocalGraph $ liftProcess . G.sync

-- | Declare that we have finished handling a message to the EQ, meaning it can
--   delete it.
messageProcessed :: UUID -> PhaseM LoopState l ()
messageProcessed uuid = do
  phaseLog "eq" $ unwords ["Removing message", show uuid, "from EQ."]
  eqPid <- lsEQPid <$> get Global
  liftProcess $ usend eqPid uuid

sayRC :: String -> Process ()
sayRC s = say $ "Recovery Coordinator: " ++ s
