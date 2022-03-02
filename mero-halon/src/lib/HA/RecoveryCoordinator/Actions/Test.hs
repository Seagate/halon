-- |
-- Module    : HA.RecoveryCoordinator.Actions.Test
-- Copyright : (C) 2015-2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Helper used for testing.
module HA.RecoveryCoordinator.Actions.Test
  ( getNoisyPingCount ) where

import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.ResourceGraph as G
import           HA.Services.Noisy
import           Network.CEP
import           Prelude hiding ((.), id, mapM_)

-- | Query 'NoisyPingCount' and increment its value in RG. Returns old
-- value.
getNoisyPingCount :: PhaseM RC l Int
getNoisyPingCount = do
    Log.rcLog' Log.TRACE "Querying noisy ping count."
    rg <- getGraph
    let (rg', i) =
          case G.connectedTo noisy HasPingCount rg of
            Nothing -> (G.connect noisy HasPingCount (NoisyPingCount 0) rg, 0)
            Just pc@(NoisyPingCount iPc) ->
              let newPingCount = NoisyPingCount (iPc + 1)
                  nrg = G.connect noisy HasPingCount newPingCount $
                        G.disconnect noisy HasPingCount pc rg in
              (nrg, iPc)
    putGraph rg'
    return i
