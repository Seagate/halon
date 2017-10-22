{-# LANGUAGE ViewPatterns #-}
-- |
-- Copyright:  (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Actions on 'M0.Node's.
module HA.RecoveryCoordinator.Castor.Node.Actions
  ( getLabeledProcesses
  , getLabeledProcessesP
  , getProcesses
  , getUnstartedProcesses
  , startProcesses
  ) where

import Control.Monad (unless)

import Data.Foldable (for_)

import HA.RecoveryCoordinator.Castor.Process.Events (ProcessStartRequest(..))
import HA.RecoveryCoordinator.RC.Actions.Core
  ( RC
  , getLocalGraph
  , promulgateRC
  )
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.ResourceGraph as G
import qualified HA.Resources as R
import           HA.Resources.Castor (Host_XXX1)
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0

import Mero.ConfC (ServiceType(..))

import Network.CEP

-- | Get all 'M0.Processes' associated to the given 'R.Node' with
-- the given 'M0.ProcessLabel'.
--
-- For processes on any node, see 'Node.getLabeled'.
getLabeledProcesses :: R.Node
                    -> M0.ProcessLabel
                    -> G.Graph
                    -> [M0.Process]
getLabeledProcesses node label rg =
   [ p | Just host <- [G.connectedFrom R.Runs node rg] :: [Maybe Host_XXX1]
       , m0node <- G.connectedTo host R.Runs rg :: [M0.Node]
       , p <- G.connectedTo m0node M0.IsParentOf rg
       , G.isConnected p R.Has label rg
   ]

-- | Get all 'M0.Processes' associated to the given 'R.Node' with
-- a 'M0.ProcessLabel' satisfying the predicate.
--
-- For processes on any node, see 'Node.getLabeledP'.
getLabeledProcessesP :: R.Node
                      -> (M0.ProcessLabel -> Bool)
                      -> G.Graph
                      -> [M0.Process]
getLabeledProcessesP node labelP rg =
  [ p | Just host <- [G.connectedFrom R.Runs node rg] :: [Maybe Host_XXX1]
      , m0node <- G.connectedTo host R.Runs rg :: [M0.Node]
      , p <- G.connectedTo m0node M0.IsParentOf rg
      , Just (lbl :: M0.ProcessLabel) <- [G.connectedTo p R.Has rg]
      , labelP lbl
  ]

-- | Get all 'M0.Process'es on the given 'R.Node'.
getProcesses :: R.Node -> G.Graph -> [M0.Process]
getProcesses node rg =
  [ p | Just host <- [G.connectedFrom R.Runs node rg] :: [Maybe Host_XXX1]
      , m0node <- G.connectedTo host R.Runs rg :: [M0.Node]
      , p <- G.connectedTo m0node M0.IsParentOf rg
  ]

-- | Find all processes on the given 'M0.Node' such that:
--
-- * The process is not properly started, i.e. not in 'M0.PSOnline' state.
-- * The process is not a @m0t1fs@ process.
getUnstartedProcesses :: M0.Node -> G.Graph -> [(M0.Process, M0.ProcessState)]
getUnstartedProcesses n rg =
  let isPOnline :: M0.Process -> Bool
      isPOnline p = M0.getState p rg == M0.PSOnline
      isM0t1fs (M0.s_type -> t) = t `notElem` [CST_IOS, CST_MDS, CST_CONFD, CST_HA]
  in [ (p, M0.getState p rg)
     | p <- G.connectedTo n M0.IsParentOf rg
     , not $ isPOnline p
     , not $ any isM0t1fs (G.connectedTo p M0.IsParentOf rg)
     ]

-- | Start all Mero processes labelled with the specified process label on
-- a given node. Returns all the processes which are being started.
startProcesses ::  Host_XXX1
                -> (M0.ProcessLabel -> Bool)
                -> PhaseM RC a [M0.Process]
startProcesses host labelP = do
  Log.actLog "startProcesses" [("host", show host)]
  rg <- getLocalGraph
  let procs = [ p
              | m0node <- G.connectedTo host R.Runs rg :: [M0.Node]
              , p <- G.connectedTo m0node M0.IsParentOf rg
              , Just (lbl :: M0.ProcessLabel) <- [G.connectedTo p R.Has rg]
              , labelP lbl
              ]
  unless (null procs) $ do
    Log.rcLog' Log.DEBUG ("processes", show (M0.showFid <$> procs))
    for_ procs $ promulgateRC . ProcessStartRequest
  return procs
