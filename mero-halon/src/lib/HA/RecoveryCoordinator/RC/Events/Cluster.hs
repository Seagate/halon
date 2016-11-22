-- |
-- Copyright:  (C) 2016 Seagate Technology Limited.
--
-- Cluster wide events related to halon cluster only, and
-- that are not specific to Castor or Mero.
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module HA.RecoveryCoordinator.RC.Events.Cluster
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

newtype OldNodeRevival = OldNodeRevival Node
  deriving (Show, Eq, Typeable, Generic)
data RecoveryAttempt = RecoveryAttempt Node Int
  deriving (Show, Eq, Typeable, Generic)
newtype NodeTransient = NodeTransient Node
  deriving (Show, Eq, Typeable, Generic)
newtype NewNodeMsg = NewNodeMsg Node
  deriving (Show, Eq, Typeable, Generic)

instance Binary OldNodeRevival
instance Binary RecoveryAttempt
instance Binary NodeTransient
instance Binary NewNodeMsg
