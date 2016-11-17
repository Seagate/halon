-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

module HA.RecoveryCoordinator.Actions.Test
  ( getNoisyPingCount ) where

import Prelude hiding ((.), id, mapM_)
import HA.Services.Noisy

import HA.RecoveryCoordinator.Actions.Core
import qualified HA.ResourceGraph as G

import Network.CEP

getNoisyPingCount :: PhaseM RC l Int
getNoisyPingCount = do
    phaseLog "rg-query" "Querying noisy ping count."
    rg <- getLocalGraph
    let (rg', i) =
          case G.connectedTo noisy HasPingCount rg of
            Nothing ->
              let nrg = G.connect noisy HasPingCount (NoisyPingCount 0) $
                        G.newResource (NoisyPingCount 0) rg in
              (nrg, 0)
            Just pc@(NoisyPingCount iPc) ->
              let newPingCount = NoisyPingCount (iPc + 1)
                  nrg = G.connect noisy HasPingCount newPingCount $
                        G.newResource newPingCount $
                        G.disconnect noisy HasPingCount pc rg in
              (nrg, iPc)
    putLocalGraph rg'
    return i
