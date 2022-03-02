{-# LANGUAGE StrictData      #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies    #-}
-- |
-- Module    : HA.RecoveryCoordinator.Castor.Node.Events
-- Copyright : (C) 2016-2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Events associated with nodes.
module HA.RecoveryCoordinator.Castor.Node.Events
  ( KernelStartFailure(..)
  , StartHalonM0dRequest(..)
  , StartMeroClientRequest(..)
  , StartProcessNodeNew(..)
  , StartProcessesOnNodeRequest(..)
  , StartProcessesOnNodeResult(..)
  , StopHalonM0dRequest(..)
  , StopHalonM0dResult(..)
  , StopMeroClientRequest(..)
  , StopProcessesOnNodeRequest(..)
  , StopProcessesOnNodeResult(..)
  , StopNodeUserRequest(..)
  , StopNodeUserReply(..)
  , MaintenanceStopNode(..)
  , MaintenanceStopNodeResult(..)
  , NodeDiRebReq(..)
  , NodeDiRebRes(..)
  ) where

import           Control.Distributed.Process (SendPort)
import           Data.Binary (Binary)
import           Data.Typeable (Typeable)
import           GHC.Generics
import           HA.RecoveryCoordinator.Service.Events (ServiceStopRequestResult)
import qualified HA.Resources as R
import qualified HA.Resources.Mero as M0
import           HA.SafeCopy
import           Mero.ConfC (Fid)
import           System.Posix.SysInfo

-- | Request start of the 'ruleNewNode'.
data StartProcessNodeNew = StartProcessNodeNew !R.Node !SysInfo
  deriving (Eq, Show, Generic, Ord)

-- | Request that @halon:m0d@ service is started on the given
-- 'M0.Node'.
newtype StartHalonM0dRequest = StartHalonM0dRequest M0.Node
  deriving (Eq, Show, Typeable, Generic)

-- | Trigger 'requestStopHalonM0d'.
newtype StopHalonM0dRequest = StopHalonM0dRequest R.Node
  deriving (Eq, Show, Typeable, Generic, Ord)

-- | Reply in 'requestStopHalonM0d'.
data StopHalonM0dResult =
  HalonM0dStopResult ServiceStopRequestResult
  -- ^ Service stop rule gave us a result.
  | HalonM0dNotFound
  -- ^ Service not found on the node.
  deriving (Eq, Show, Generic, Ord)
instance Binary StopHalonM0dResult

-- | Request start of the 'ruleNewNode'.
newtype StartProcessesOnNodeRequest = StartProcessesOnNodeRequest M0.Node
  deriving (Eq, Show, Generic, Ord)

-- | Request start of 'ruleStopProcessesOnNode'.
newtype StopProcessesOnNodeRequest = StopProcessesOnNodeRequest R.Node
  deriving (Eq, Show, Generic, Ord)

-- | Results to 'StopProcessesOnNodeRequest'.
data StopProcessesOnNodeResult
       = StopProcessesOnNodeOk R.Node
       | StopProcessesOnNodeTimeout R.Node
       | StopProcessesOnNodeStateChanged R.Node M0.MeroClusterState
       | StopProcessesOnNodeFailed R.Node String
       deriving (Eq, Show, Generic)
instance Binary StopProcessesOnNodeResult

-- | @mero-kernel@ has failed to start on the 'M0.Node'.
newtype KernelStartFailure = KernelStartFailure M0.Node
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
data StopMeroClientRequest =
  StopMeroClientRequest Fid String
  -- ^ @StopMeroClientRequest clientProcessFid reason@
  deriving (Eq, Show, Generic)

-- | Start mero client process request.
newtype StartMeroClientRequest =
  StartMeroClientRequest Fid
  -- ^ @StartMeroClientRequest clientProcessFid@
  deriving (Eq, Show, Generic)

-- | Request RC to stop node. Replied to by 'StopNodeUserReply' on the
-- given channel.
data StopNodeUserRequest =
  StopNodeUserRequest Fid Bool (SendPort StopNodeUserReply) String
  -- ^ @StopNodeUserRequest m0nodeFid forceStop replyChannel reason@
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
  | MaintenanceStopNodeFailed R.Node String
  -- ^ Node failed to stop for some reason.
  deriving (Eq, Show, Generic)

-- Request to trigger direct rebalance on a node.
data NodeDiRebReq = NodeDiRebReq M0.Node
  deriving (Eq, Show, Ord, Generic)

-- Response for direct rebalance request.
data NodeDiRebRes
  = NodeDiRebReqSucccess M0.Node
  | NodeDiRebReqFailed M0.Node String
  deriving (Eq, Show, Ord, Typeable, Generic)

deriveSafeCopy 0 'base ''KernelStartFailure
deriveSafeCopy 0 'base ''MaintenanceStopNode
deriveSafeCopy 0 'base ''MaintenanceStopNodeResult
deriveSafeCopy 0 'base ''StartHalonM0dRequest
deriveSafeCopy 0 'base ''StartMeroClientRequest
deriveSafeCopy 0 'base ''StartProcessNodeNew
deriveSafeCopy 0 'base ''StartProcessesOnNodeRequest
deriveSafeCopy 0 'base ''StopHalonM0dRequest
deriveSafeCopy 0 'base ''StopMeroClientRequest
deriveSafeCopy 0 'base ''StopNodeUserReply
deriveSafeCopy 0 'base ''StopNodeUserRequest
deriveSafeCopy 0 'base ''StopProcessesOnNodeRequest
deriveSafeCopy 0 'base ''NodeDiRebReq
deriveSafeCopy 0 'base ''NodeDiRebRes
