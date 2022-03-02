{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StrictData                 #-}
-- |
-- Module    : HA.RecoveryCoordinator.RC.Events.Cluster
-- Copyright : (C) 2016-2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Cluster wide events related to halon cluster only, and
-- that are not specific to Castor or Mero.
module HA.RecoveryCoordinator.RC.Events.Cluster
  ( NewNodeConnected(..)
  , InitialDataLoaded(..)
  , OldNodeRevival(..)
  , RecoveryAttempt(..)
  , NodeTransient(..)
  ) where

import Data.Binary
import Data.Typeable
import GHC.Generics
import HA.Resources
import System.Posix.SysInfo

-- | New mero server was connected. This event is emitted
-- as a result of the new node event.
data NewNodeConnected = NewNodeConnected !Node !SysInfo
   deriving (Eq, Show, Typeable, Generic)
instance Binary NewNodeConnected

-- | Initial data was loaded or has failed to load.
data InitialDataLoaded = InitialDataLoaded
                       | InitialDataLoadFailed String
   deriving (Eq, Show, Typeable, Generic)
instance Binary InitialDataLoaded

-- * Messages which may be interesting to any subscribers (disconnect
-- tests).

-- | A previously-connected node has announced itself again.
newtype OldNodeRevival = OldNodeRevival Node
  deriving (Show, Eq, Typeable, Generic)

-- | Node recovery rule is trying again.
data RecoveryAttempt = RecoveryAttempt Node Int
  deriving (Show, Eq, Typeable, Generic)

-- | Node was marked transient and recovery on it is about to begin.
newtype NodeTransient = NodeTransient Node
  deriving (Show, Eq, Typeable, Generic)

instance Binary OldNodeRevival
instance Binary RecoveryAttempt
instance Binary NodeTransient
