{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- |
-- Module    : HA.RecoveryCoordinator.Events.Cluster
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Cluster wide events related to halon cluster only, and
-- that are not specific to Castor or Mero.
module HA.RecoveryCoordinator.Events.Cluster
  ( NewNodeConnected(..)
  , InitialDataLoaded(..)
  , OldNodeRevival(..)
  , RecoveryAttempt(..)
  , NodeTransient(..)
  , NewNodeMsg(..)
  ) where

import HA.Resources

import Data.Binary
import Data.Typeable
import GHC.Generics

-- | New mero server was connected. This event is emitted
-- as a result of the new node event.
newtype NewNodeConnected = NewNodeConnected Node
   deriving (Eq, Show, Typeable, Generic, Binary)

-- | Initial data were loaded.
data InitialDataLoaded = InitialDataLoaded
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

-- | Node is about to be registered on cluster.
--
-- TODO: Remove and use 'nodeUpJob' result instead.
newtype NewNodeMsg = NewNodeMsg Node
  deriving (Show, Eq, Typeable, Generic)

instance Binary OldNodeRevival
instance Binary RecoveryAttempt
instance Binary NodeTransient
instance Binary NewNodeMsg
