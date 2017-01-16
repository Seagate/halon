{-# LANGUAGE TemplateHaskell #-}
-- |
-- Module    : HA.RecoveryCoordinator.Castor.Node.Events
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Events associated with nodes.
module HA.RecoveryCoordinator.Castor.Node.Events
  ( M0KernelResult(..)
  , StartCastorNodeRequest(..)
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

newtype StartCastorNodeRequest = StartCastorNodeRequest R.Node
  deriving (Eq, Show, Generic, Binary)

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

newtype StartClientsOnNodeRequest = StartClientsOnNodeRequest M0.Node
         deriving (Eq, Show, Generic, Ord)

data StartClientsOnNodeResult
       = ClientsStartOk M0.Node
       | ClientsStartFailure M0.Node String
       deriving (Eq, Show, Generic)
instance Binary StartClientsOnNodeResult

newtype StopClientsOnNodeRequest = StopClientsOnNodeRequest M0.Node
         deriving (Eq, Show, Generic, Binary, Ord)

-- | Result of trying to start the M0 Kernel on a node
data M0KernelResult
    = KernelStarted M0.Node
    | KernelStartFailure M0.Node
  deriving (Eq, Show, Generic)

-- | Result of @StartProcessesOnNodeRequest@
data StartProcessesOnNodeResult
      = NodeProcessesStarted M0.Node
      | NodeProcessesStartTimeout M0.Node [(M0.Process, M0.ProcessState)]
      | NodeProcessesStartFailure M0.Node [(M0.Process, M0.ProcessState)]
  deriving (Eq, Show, Generic)
instance Binary StartProcessesOnNodeResult

newtype StopMeroClientRequest = StopMeroClientRequest Fid
  deriving (Eq, Show, Generic)

newtype StartMeroClientRequest = StartMeroClientRequest Fid
  deriving (Eq, Show, Generic)

-- | Request RC to stop node.
data StopNodeUserRequest = StopNodeUserRequest Fid Bool (SendPort StopNodeUserReply)
  deriving (Eq, Show, Generic)

-- | Reply to 'StopNodeUserRequest'.
data StopNodeUserReply = CantStop Fid R.Node [String]
                       | StopInitiated Fid R.Node
                       | NotANode Fid
  deriving (Eq, Show, Generic)

data MaintenanceStopNode = MaintenanceStopNode R.Node deriving (Eq, Show, Generic, Ord)

data MaintenanceStopNodeResult
  = MaintenanceStopNodeOk R.Node
  | MaintenanceStopNodeTimeout R.Node
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
