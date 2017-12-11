{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StrictData                 #-}
-- |
-- Module    : HA.RecoveryCoordinator.RC.Events.Cluster
-- Copyright : (C) 2016-2017 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Cluster wide events related to halon cluster only, and
-- that are not specific to Castor or Mero.
module HA.RecoveryCoordinator.RC.Events.Cluster
  ( NewNodeConnected(..)
  , InitialDataLoaded(..)
  , InitialDataLoaded_XXX3(..)
  , OldNodeRevival(..)
  , RecoveryAttempt(..)
  , NodeTransient(..)
  ) where

import Data.Binary
import Data.Typeable
import GHC.Generics
import HA.Resources (Node_XXX2)
import System.Posix.SysInfo

-- | New mero server was connected. This event is emitted
-- as a result of the new node event.
data NewNodeConnected = NewNodeConnected !Node_XXX2 !SysInfo
   deriving (Eq, Show, Typeable, Generic)
instance Binary NewNodeConnected

-- | Result of 'InitialData' loading.
data InitialDataLoaded = InitialDataLoaded
                       | InitialDataLoadFailed String
  deriving (Eq, Show, Typeable, Generic)
instance Binary InitialDataLoaded

-- | Initial data was loaded or has failed to load.
data InitialDataLoaded_XXX3 = InitialDataLoaded_XXX3
                       | InitialDataLoadFailed_XXX3 String
  deriving (Eq, Show, Typeable, Generic)
instance Binary InitialDataLoaded_XXX3

-- * Messages which may be interesting to any subscribers (disconnect
-- tests).

-- | A previously-connected node has announced itself again.
newtype OldNodeRevival = OldNodeRevival Node_XXX2
  deriving (Show, Eq, Typeable, Generic)

-- | Node recovery rule is trying again.
data RecoveryAttempt = RecoveryAttempt Node_XXX2 Int
  deriving (Show, Eq, Typeable, Generic)

-- | Node was marked transient and recovery on it is about to begin.
newtype NodeTransient = NodeTransient Node_XXX2
  deriving (Show, Eq, Typeable, Generic)

instance Binary OldNodeRevival
instance Binary RecoveryAttempt
instance Binary NodeTransient
