{-# LANGUAGE ViewPatterns #-}
-- |
-- Copyright:  (C) 2016 Seagate Technology Limited.
--
-- Actions on 'M0.Node's.
module HA.RecoveryCoordinator.Castor.Node.Actions
  ( getUnstartedProcesses
  ) where

import qualified HA.ResourceGraph as G
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           Mero.ConfC (ServiceType(..))

-- | Find all processes on the given 'M0.Node' such that:
--
-- * The process is not properly started, i.e. not in 'M0.PSOnline' state.
-- * The process is not a @m0t1fs@ process.
getUnstartedProcesses :: M0.Node -> G.Graph -> [(M0.Process, M0.ProcessState)]
getUnstartedProcesses n rg =
  let isPOnline :: M0.Process -> Bool
      isPOnline p = M0.getState p rg == M0.PSOnline
      isM0t1fs (M0.s_type -> t) = t `notElem` [CST_IOS, CST_MDS, CST_MGS, CST_HA]
  in [ (p, M0.getState p rg)
     | p <- G.connectedTo n M0.IsParentOf rg
     , not $ isPOnline p
     , not $ any isM0t1fs (G.connectedTo p M0.IsParentOf rg)
     ]
