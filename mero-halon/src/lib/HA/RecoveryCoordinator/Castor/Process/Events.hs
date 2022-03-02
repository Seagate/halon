{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StrictData                 #-}
{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
module HA.RecoveryCoordinator.Castor.Process.Events
  ( ProcessStartRequest(..)
  , ProcessStartResult(..)
  , StopProcessRequest(..)
  , StopProcessResult(..)
  , StopProcessUserRequest(..)
  , StopProcessUserReply(..)
  ) where

import           Control.Distributed.Process (SendPort)
import           Data.Binary (Binary)
import           Data.Text (Text)
import           Data.Typeable (Typeable)
import           GHC.Generics
import           HA.RecoveryCoordinator.Job.Actions (ListenerId)
import qualified HA.Resources.Mero as M0
import           HA.SafeCopy
import           Mero.ConfC (Fid)

-- | Request that given 'M0.Process' be started.
newtype ProcessStartRequest = ProcessStartRequest M0.Process
  deriving (Show, Eq, Ord, Typeable, Generic)

-- | Reply in job handling 'ProcessStartRequest'
data ProcessStartResult = ProcessStarted M0.Process
                        | ProcessStartFailed M0.Process String
                        | ProcessStartInvalid M0.Process String
                        | ProcessConfiguredOnly M0.Process
  deriving (Show, Eq, Ord, Typeable, Generic)


-- | Request to stop a specific process on a node. This event differs
-- from @StopProcessesOnNodeRequest@ as that stops all processes on
-- the node in a staged manner. This event should stop the precise
-- process without caring about the overall cluster state.
newtype StopProcessRequest = StopProcessRequest M0.Process
  deriving (Eq, Ord, Show, Generic)

-- | A request to stop the process coming from the user. Unlike
-- 'StopProcessRequest', this can be denied on basis of transitioning
-- the cluster into a "broken" state which the user is prevented from
-- doing.
data StopProcessUserRequest =
  -- | @'StopProcessUserRequest' processFid skipLivenessCheck replyChan@
  StopProcessUserRequest !Fid !Bool !(SendPort StopProcessUserReply)
  deriving (Eq, Show, Typeable, Generic)

-- | Result of 'StopProcessUserRequest' sent back to the user.
data StopProcessUserReply =
  -- | No process found with the originally-supplied 'Fid'.
  NoSuchProcess
  -- | Cluster would enter bad state if we stopped the process with
  -- the given reason.
  | StopWouldBreakCluster !Text
  -- | Stop process job has been started with the given 'ListenerId'.
  | StopProcessInitiated !ListenerId
  deriving (Eq, Show, Typeable, Generic)
instance Binary StopProcessUserReply

-- | Result of stopping a process. Note that in general most
-- downstream rules will not care about this, as they will directly
-- use the process state change notification.
data StopProcessResult =
    StopProcessResult (M0.Process, M0.ProcessState)
  | StopProcessTimeout M0.Process
  deriving (Eq, Show, Generic)
instance Binary StopProcessResult

deriveSafeCopy 0 'base ''ProcessStartRequest
deriveSafeCopy 0 'base ''ProcessStartResult
deriveSafeCopy 0 'base ''StopProcessRequest
deriveSafeCopy 0 'base ''StopProcessUserRequest
