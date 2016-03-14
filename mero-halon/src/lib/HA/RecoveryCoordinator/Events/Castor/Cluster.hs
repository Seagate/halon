-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
{-# LANGUAGE DeriveGeneric #-}
module HA.RecoveryCoordinator.Events.Castor.Cluster
  ( ClusterStatusRequest(..)
  , ClusterStartRequest(..)
  , ClusterStopRequest(..)
  , StateChangeResult(..)
  ) where

import Control.Distributed.Process
import qualified HA.Resources.Mero as M0
import Data.Binary

import GHC.Generics

data ClusterStatusRequest = ClusterStatusRequest (SendPort (Maybe M0.MeroClusterState)) deriving (Eq,Show,Generic)
instance Binary ClusterStatusRequest

data ClusterStartRequest = ClusterStartRequest (SendPort StateChangeResult) deriving (Eq, Show, Generic)
instance Binary ClusterStartRequest

data ClusterStopRequest = ClusterStopRequest (SendPort StateChangeResult) deriving (Eq, Show, Generic)
instance Binary ClusterStopRequest

data StateChangeResult
      = StateChangeError String
      | StateChangeOngoing M0.MeroClusterState
      | StateChangeStarted ProcessId
      | StateChangeFinished
      deriving (Show, Generic, Eq)

instance Binary StateChangeResult
