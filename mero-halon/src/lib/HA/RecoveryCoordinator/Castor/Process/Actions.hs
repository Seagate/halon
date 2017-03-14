-- |
-- Copyright:  (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Actions on 'M0.Process's.
module HA.RecoveryCoordinator.Castor.Process.Actions
  ( getAll
  , getLabel
  , getLabeled
  , getLabeledP
  , getHA
  ) where

import           Data.Maybe (listToMaybe)
import qualified HA.ResourceGraph as G
import qualified HA.Resources as R
import qualified HA.Resources.Mero as M0
import           Mero.ConfC (ServiceType(CST_HA))

-- | Get the process label, if attached.
getLabel :: M0.Process -> G.Graph -> Maybe M0.ProcessLabel
getLabel p rg = G.connectedTo p R.Has rg

-- | Get all 'M0.Processes' associated the given 'M0.ProcessLabel'.
getLabeled :: M0.ProcessLabel
           -> G.Graph
           -> [M0.Process]
getLabeled label rg = getLabeledP (== label) rg

-- | Get all 'M0.Process' entities whose `M0.ProcessLabel` satisfies a given
--   predicate.
getLabeledP :: (M0.ProcessLabel -> Bool)
            -> G.Graph
            -> [M0.Process]
getLabeledP labelP rg =
  [ proc
  | Just (prof :: M0.Profile) <- [G.connectedTo R.Cluster R.Has rg]
  , (fs :: M0.Filesystem) <- G.connectedTo prof M0.IsParentOf rg
  , (node :: M0.Node) <- G.connectedTo fs M0.IsParentOf rg
  , (proc :: M0.Process) <- G.connectedTo node M0.IsParentOf rg
  , Just (lbl :: M0.ProcessLabel) <- [G.connectedTo proc R.Has rg]
  , labelP lbl
  ]

-- | Find every 'M0.Process' in the 'Res.Cluster'.
getAll :: G.Graph -> [M0.Process]
getAll rg =
  [ p
  | Just (prof :: M0.Profile) <- [G.connectedTo R.Cluster R.Has rg]
  , (fs :: M0.Filesystem) <- G.connectedTo prof M0.IsParentOf rg
  , (node :: M0.Node) <- G.connectedTo fs M0.IsParentOf rg
  , (p :: M0.Process) <- G.connectedTo node M0.IsParentOf rg
  ]

-- | Get a halon process on the given node.
--
-- This is a common action used throughout RC.
getHA :: M0.Node -> G.Graph -> Maybe M0.Process
getHA m0n rg = listToMaybe
  [ p | p <- G.connectedTo m0n M0.IsParentOf rg
      , any (\s -> M0.s_type s == CST_HA) $ G.connectedTo p M0.IsParentOf rg
      ]
