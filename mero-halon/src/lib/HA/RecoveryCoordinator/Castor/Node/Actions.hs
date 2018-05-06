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

import           Control.Monad (unless)
import           Data.Foldable (for_)
import           HA.RecoveryCoordinator.Castor.Process.Events
  (ProcessStartRequest(..))
import           HA.RecoveryCoordinator.RC.Actions.Core
  ( RC
  , getGraph
  , promulgateRC
  )
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.ResourceGraph as G
import           HA.Resources (Has(..), Runs(..))
import qualified HA.Resources as R (Node)
import           HA.Resources.Castor (Host(..))
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import qualified HA.Resources.Castor.Initial as CI
import           Mero.ConfC (ServiceType(..))
import           Network.CEP

-- | Get all 'M0.Processes' associated to the given 'R.Node' with
-- the given 'CI.ProcessType'.
--
-- For processes on any node, see
-- 'HA.RecoveryCoordinator.Castor.Process.Actions.getLabeled'.
getLabeledProcesses :: R.Node
                    -> CI.ProcessType
                    -> G.Graph
                    -> [M0.Process]
getLabeledProcesses node label rg =
   [ proc
   | proc <- getProcesses node rg
   , G.isConnected proc Has label rg
   ]

-- | Get all 'M0.Processes' associated to the given 'R.Node' with
-- a 'CI.ProcessType' satisfying the predicate.
--
-- For processes on any node, see 'Node.getLabeledP'.
getLabeledProcessesP :: R.Node
                     -> (CI.ProcessType -> Bool)
                     -> G.Graph
                     -> [M0.Process]
getLabeledProcessesP node labelP rg =
  [ proc
  | proc <- getProcesses node rg
  , Just (lbl :: CI.ProcessType) <- [G.connectedTo proc Has rg]
  , labelP lbl
  ]

-- | Get all 'M0.Process'es on the given 'R.Node'.
getProcesses :: R.Node -> G.Graph -> [M0.Process]
getProcesses node rg =
  [ proc
  | Just (host :: Host) <- [G.connectedFrom Runs node rg]
  , m0node :: M0.Node <- G.connectedTo host Runs rg
  , proc <- G.connectedTo m0node M0.IsParentOf rg
  ]

-- | Find all processes on the given 'M0.Node' such that:
--
-- * The process is not properly started, i.e. not in 'M0.PSOnline' state.
-- * The process is not a @m0t1fs@ process.
getUnstartedProcesses :: M0.Node -> G.Graph -> [(M0.Process, M0.ProcessState)]
getUnstartedProcesses node rg =
  [ (proc, M0.getState proc rg)
  | proc <- G.connectedTo node M0.IsParentOf rg
  , M0.getState proc rg /= M0.PSOnline
  , not . any isM0t1fs $ G.connectedTo proc M0.IsParentOf rg
  ]
  where
    isM0t1fs svc = M0.s_type svc `notElem` [CST_IOS, CST_MDS, CST_CONFD, CST_HA]

-- | Start all Mero processes labelled with the specified process label on
-- a given node. Returns all the processes which are being started.
startProcesses :: Host -> (CI.ProcessType -> Bool) -> PhaseM RC a [M0.Process]
startProcesses host labelP = do
  Log.actLog "startProcesses" [("host", show host)]
  rg <- getGraph
  let procs = [ proc
              | m0node :: M0.Node <- G.connectedTo host Runs rg
              , proc <- G.connectedTo m0node M0.IsParentOf rg
              , Just (lbl :: CI.ProcessType) <- [G.connectedTo proc Has rg]
              , labelP lbl
              ]
  unless (null procs) $ do
    Log.rcLog' Log.DEBUG ("processes", show (M0.showFid <$> procs))
    for_ procs $ promulgateRC . ProcessStartRequest
  return procs
