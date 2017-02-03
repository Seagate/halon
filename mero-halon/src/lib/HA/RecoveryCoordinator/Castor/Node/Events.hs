{-# LANGUAGE TemplateHaskell #-}
-- |
-- Module    : HA.RecoveryCoordinator.Castor.Node.Events
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Events associated with nodes.
module HA.RecoveryCoordinator.Castor.Node.Events
  ( M0KernelResult(..)
  , StartClientsOnNodeRequest(..)
  , StartClientsOnNodeResult(..)
  , StartHalonM0dRequest(..)
  , StartMeroClientRequest(..)
  , StartProcessNodeNew(..)
  , StartProcessesOnNodeRequest(..)
  , StartProcessesOnNodeResult(..)
  , StopHalonM0dRequest(..)
  , StopMeroClientRequest(..)
  , StopProcessesOnNodeRequest(..)
  , StopProcessesOnNodeResult(..)
  , StopNodeUserRequest(..)
  , StopNodeUserReply(..)
  , MaintenanceStopNode(..)
  , MaintenanceStopNodeResult(..)
  ) where

import           Control.Distributed.Process (SendPort)
import           Data.Binary (Binary)
import           Data.Typeable (Typeable)
import           GHC.Generics
import qualified HA.Resources as R
import qualified HA.Resources.Mero as M0
import           HA.SafeCopy
import           Mero.ConfC (Fid)

-- | Request start of the 'ruleNewNode'.
newtype StartProcessNodeNew = StartProcessNodeNew R.Node
  deriving (Eq, Show, Generic, Ord)

-- | Request that @halon:m0d@ service is started on the given
-- 'M0.Node'.
newtype StartHalonM0dRequest = StartHalonM0dRequest M0.Node
  deriving (Eq, Show, Typeable, Generic)

-- | Trigger 'requestStopHalonM0d'.
newtype StopHalonM0dRequest = StopHalonM0dRequest R.Node
  deriving (Eq, Show, Typeable, Generic)

-- | Request start of the 'ruleNewNode'.
newtype StartProcessesOnNodeRequest = StartProcessesOnNodeRequest M0.Node
  deriving (Eq, Show, Generic, Ord)

-- | Request start of 'ruleStopProcessesOnNode'.
newtype StopProcessesOnNodeRequest = StopProcessesOnNodeRequest R.Node
  deriving (Eq, Show, Generic, Ord)

-- | Results to 'StopProcessesOnNodeRequest'.
--
-- TODO: We should have @StopProcessesOnNodeFailed@ with failure
-- reason because currently we throw away useful info on process
-- failure.
data StopProcessesOnNodeResult
       = StopProcessesOnNodeOk R.Node
       | StopProcessesOnNodeTimeout R.Node
       | StopProcessesOnNodeStateChanged R.Node M0.MeroClusterState
       deriving (Eq, Show, Generic)
instance Binary StopProcessesOnNodeResult

-- | Start client processes on the given 'M0.Node'. Replied to with
-- 'StartClientsOnNodeResult'.
newtype StartClientsOnNodeRequest = StartClientsOnNodeRequest M0.Node
         deriving (Eq, Show, Generic, Ord)

-- | A reply to 'StartClientsOnNodeRequest'.
data StartClientsOnNodeResult
       = ClientsStartOk M0.Node
       -- ^ Client processes started fine on the given 'M0.Node'.
       | ClientsStartFailure M0.Node String
       -- ^ Client processes have failed on the 'M0.Node' with the
       -- provided reason.
       deriving (Eq, Show, Generic)
instance Binary StartClientsOnNodeResult

-- | Result of trying to start the M0 Kernel on a node.
data M0KernelResult =
  KernelStarted M0.Node
  -- ^ @mero-kernel@ has managed to start on the 'M0.Node'.
  | KernelStartFailure M0.Node
  -- ^ @mero-kernel@ has failed to start on the 'M0.Node'.
  deriving (Eq, Show, Generic)

-- | Result of @StartProcessesOnNodeRequest@.
data StartProcessesOnNodeResult =
  NodeProcessesStarted M0.Node
  -- ^ The processes on the 'M0.Node' have started.
  | NodeProcessesStartTimeout M0.Node [(M0.Process, M0.ProcessState)]
  -- ^ Processes on the 'M0.Node' didn't manage to start on time.
  | NodeProcessesStartFailure M0.Node [(M0.Process, M0.ProcessState)]
  -- ^ Processes on the 'M0.Node' have failed to start.
  deriving (Eq, Show, Generic)
instance Binary StartProcessesOnNodeResult

-- | Stop mero client process request.
newtype StopMeroClientRequest =
  StopMeroClientRequest Fid
  -- ^ @StopMeroClientRequest clientProcessFid@
  deriving (Eq, Show, Generic)

-- | Start mero client process request.
newtype StartMeroClientRequest =
  StartMeroClientRequest Fid
  -- ^ @StartMeroClientRequest clientProcessFid@
  deriving (Eq, Show, Generic)

-- | Request RC to stop node. Replied to by 'StopNodeUserReply' on the
-- given channel.
data StopNodeUserRequest =
  StopNodeUserRequest Fid Bool (SendPort StopNodeUserReply)
  -- ^ @StopNodeUserRequest m0nodeFid forceStop replyChannel@
  deriving (Eq, Show, Generic)

-- | Reply to 'StopNodeUserRequest'.
data StopNodeUserReply =
  CantStop Fid R.Node [String]
  -- ^ @CantStop m0nodeFid node reasons@
  --
  -- Can't stop the node as requested because it would result in the
  -- given failures of the cluster.
  | StopInitiated Fid R.Node
  -- ^ Node stop has been started.
  | NotANode Fid
  -- ^ The given 'Fid' does not identify a known node.
  deriving (Eq, Show, Generic)

-- | Request that a 'R.Node' is stopped for maintenance. Replied to by
-- 'MaintenanceStopNodeResult'.
data MaintenanceStopNode = MaintenanceStopNode R.Node
  deriving (Eq, Show, Generic, Ord)

-- | A reply to 'MaintenanceStopNode'.
data MaintenanceStopNodeResult
  = MaintenanceStopNodeOk R.Node
  -- ^ The 'R.Node' has stopped.
  | MaintenanceStopNodeTimeout R.Node
  -- ^ Node stop has timed out.
  deriving (Eq, Show, Generic)

deriveSafeCopy 0 'base ''M0KernelResult
deriveSafeCopy 0 'base ''StartClientsOnNodeRequest
deriveSafeCopy 0 'base ''StartHalonM0dRequest
deriveSafeCopy 0 'base ''StartMeroClientRequest
deriveSafeCopy 0 'base ''StartProcessNodeNew
deriveSafeCopy 0 'base ''StartProcessesOnNodeRequest
deriveSafeCopy 0 'base ''StopHalonM0dRequest
deriveSafeCopy 0 'base ''StopMeroClientRequest
deriveSafeCopy 0 'base ''StopProcessesOnNodeRequest
deriveSafeCopy 0 'base ''StopNodeUserRequest
deriveSafeCopy 0 'base ''StopNodeUserReply
deriveSafeCopy 0 'base ''MaintenanceStopNode
deriveSafeCopy 0 'base ''MaintenanceStopNodeResult
