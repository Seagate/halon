-- |
-- Copyright:  (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Actions on 'M0.Process's.
module HA.RecoveryCoordinator.Castor.Process.Actions
  ( getAll
  , getAllHostingService
  , getLabel
  , getLabeled
  , getLabeledP
  , getHA
  ) where

import           Data.Maybe (listToMaybe)
import qualified HA.ResourceGraph as G
import qualified HA.Resources as R
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Castor.Initial as CI
import           Mero.ConfC (ServiceType(CST_HA))

-- | Get the process label, if attached.
getLabel :: M0.Process -> G.Graph -> Maybe CI.M0ProcessType
getLabel p = G.connectedTo p R.Has

-- | Get all 'M0.Processes' associated the given 'CI.M0ProcessType'.
getLabeled :: CI.M0ProcessType -> G.Graph -> [M0.Process]
getLabeled label = getLabeledP (== label)

-- | Get all 'M0.Process' entities whose `CI.M0ProcessType` satisfies a given
--   predicate.
getLabeledP :: (CI.M0ProcessType -> Bool) -> G.Graph -> [M0.Process]
getLabeledP labelP rg =
  [ proc
  | proc <- M0.getM0Processes rg
  , Just (lbl :: CI.M0ProcessType) <- [G.connectedTo proc R.Has rg]
  , labelP lbl
  ]

-- | Find every 'M0.Process' in the 'R.Cluster'.
getAll :: G.Graph -> [M0.Process]
getAll = M0.getM0Processes

-- | Get a halon process on the given node.
--
-- This is a common action used throughout RC.
getHA :: M0.Node -> G.Graph -> Maybe M0.Process
getHA m0n rg = listToMaybe
  [ p | p <- G.connectedTo m0n M0.IsParentOf rg
      , any (\s -> M0.s_type s == CST_HA) $ G.connectedTo p M0.IsParentOf rg
  ]

-- | Get all processes hosting the given service.
getAllHostingService :: ServiceType -> G.Graph -> [M0.Process]
getAllHostingService srvTyp rg =
  [ p | p <- getAll rg
      , any (\s -> M0.s_type s == srvTyp) $ G.connectedTo p M0.IsParentOf rg
  ]
