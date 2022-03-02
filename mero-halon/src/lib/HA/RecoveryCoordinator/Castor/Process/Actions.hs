-- |
-- Copyright:  (C) 2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Actions on 'M0.Process's.
module HA.RecoveryCoordinator.Castor.Process.Actions
  ( getAll
  , getAllHostingService
  , getHA
  , getType
  , getTyped
  , getTypedP
  ) where

import           Data.Maybe (listToMaybe)
import qualified HA.ResourceGraph as G
import           HA.Resources (Has(..))
import           HA.Resources.Castor.Initial (ProcessType)
import qualified HA.Resources.Mero as M0
import           Mero.ConfC (ServiceType(CST_HA))

-- | Get the process type, if attached.
getType :: M0.Process -> G.Graph -> Maybe ProcessType
getType p = G.connectedTo p Has

-- | Get all 'M0.Processes' associated the given 'ProcessType'.
getTyped :: ProcessType -> G.Graph -> [M0.Process]
getTyped t = getTypedP (== t)

-- | Get all 'M0.Process' entities whose 'ProcessType' satisfies a given
--   predicate.
getTypedP :: (ProcessType -> Bool) -> G.Graph -> [M0.Process]
getTypedP typeP rg =
  [ proc
  | proc <- M0.getM0Processes rg
  , Just (t :: ProcessType) <- [G.connectedTo proc Has rg]
  , typeP t
  ]

-- | Find every 'M0.Process' in the 'Cluster'.
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
