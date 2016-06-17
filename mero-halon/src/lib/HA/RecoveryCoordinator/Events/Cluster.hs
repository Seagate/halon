-- |
-- Copyright:  (C) 2016 Seagate Technology Limited.
--
-- Cluster wide events related to halon cluster only, and
-- that are not specific to Castor or Mero.
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module HA.RecoveryCoordinator.Events.Cluster
  ( NewNodeConnected(..)
  , InitialDataLoaded(..)
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
