{-# LANGUAGE ViewPatterns #-}
-- |
-- Copyright:  (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Actions on 'M0.Node's.
module HA.RecoveryCoordinator.Castor.Node.Actions
  ( getAttachedSDevs
  , getProcesses
  , getTypedProcesses
  , getTypedProcessesP
  , getUnstartedProcesses
  , startProcesses
  ) where

import qualified Data.Set as S
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
import           HA.Resources.Castor.Initial (ProcessType)
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import qualified HA.Resources.Castor.Initial as CI
import           Mero.ConfC (ServiceType(CST_IOS))
import           Network.CEP

-- | Get all 'M0.Processes' associated to the given 'R.Node' with
-- the given 'ProcessType'.
--
-- For processes on any node, see
-- 'HA.RecoveryCoordinator.Castor.Process.Actions.getTyped'.
getTypedProcesses :: R.Node -> ProcessType -> G.Graph -> [M0.Process]
getTypedProcesses node procType rg =
   [ proc
   | proc <- getProcesses node rg
   , G.isConnected proc Has procType rg
   ]

-- | Get all 'M0.Processes' associated to the given 'R.Node' with
-- a 'ProcessType' satisfying the predicate.
--
-- For processes on any node, see 'Node.getTypedP'.
getTypedProcessesP :: R.Node -> (ProcessType -> Bool) -> G.Graph -> [M0.Process]
getTypedProcessesP node procTypeP rg =
  [ proc
  | proc <- getProcesses node rg
  , Just (t :: ProcessType) <- [G.connectedTo proc Has rg]
  , procTypeP t
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
-- * The process is not a client process (like m0t1fs or clovis).
getUnstartedProcesses :: M0.Node -> G.Graph -> [(M0.Process, M0.ProcessState)]
getUnstartedProcesses node rg =
  [ (proc, M0.getState proc rg)
  | proc <- G.connectedTo node M0.IsParentOf rg
  , M0.getState proc rg /= M0.PSOnline
  , Just (t :: CI.ProcessType) <- [G.connectedTo proc Has rg]
  , isNotClient t
  ]
  where
    isNotClient (CI.PLM0d _) = True
    isNotClient  CI.PLHalon  = True
    isNotClient  _           = False

-- | Start all Mero processes of the specified type on a given node.
-- Return all the processes which are being started.
startProcesses :: Host -> (ProcessType -> Bool) -> PhaseM RC a [M0.Process]
startProcesses host procTypeP = do
  Log.actLog "startProcesses" [("host", show host)]
  rg <- getGraph
  let procs = [ proc
              | m0node :: M0.Node <- G.connectedTo host Runs rg
              , proc <- G.connectedTo m0node M0.IsParentOf rg
              , Just (t :: ProcessType) <- [G.connectedTo proc Has rg]
              , procTypeP t
              ]
  unless (null procs) $ do
    Log.rcLog' Log.DEBUG ("processes", show (M0.showFid <$> procs))
    for_ procs $ promulgateRC . ProcessStartRequest
  return procs

getAttachedSDevs :: M0.Node -> G.Graph -> [M0.SDev]
getAttachedSDevs node rg = S.toList $ S.fromList
  [ sdev
  | proc :: M0.Process <- G.connectedTo node M0.IsParentOf rg
  , svc <- G.connectedTo proc M0.IsParentOf rg
  , M0.s_type svc == CST_IOS
  , sdev <- G.connectedTo svc M0.IsParentOf rg
  ]
