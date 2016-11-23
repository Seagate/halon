{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2016 Xyratex Technology Limited.
-- License   : All rights reserved.
--
module HA.RecoveryCoordinator.RC.Events
  ( SubscribeToRequest(..)
  , SubscribeToReply(..)
  , UnsubscribeFromRequest(..)
  , GetHalonVars(..)
  ) where

import Control.Distributed.Process
  ( ProcessId, SendPort )
import Data.Binary (Binary)
import Data.ByteString (ByteString)
import Data.SafeCopy
import Data.Typeable (Typeable)
import HA.SafeCopy.OrphanInstances ()
import HA.Resources.HalonVars
import GHC.Generics

-- | Request for process subscription.
data SubscribeToRequest = SubscribeToRequest !ProcessId !ByteString
  deriving (Eq, Show, Generic, Typeable)
instance Binary SubscribeToRequest
deriveSafeCopy 0 'base ''SubscribeToRequest

-- | Reply for process subscription.
newtype SubscribeToReply = SubscribeToReply ByteString
  deriving (Eq, Show, Generic, Typeable, Binary)
deriveSafeCopy 0 'base ''SubscribeToReply

-- | Request for process unsubscription.
data UnsubscribeFromRequest = UnsubscribeFromRequest !ProcessId !ByteString
  deriving (Eq, Show, Generic, Typeable)
instance Binary UnsubscribeFromRequest
deriveSafeCopy 0 'base ''UnsubscribeFromRequest

-- | Request current halon vars.
newtype GetHalonVars = GetHalonVars (SendPort HalonVars)
  deriving (Eq, Show, Generic, Typeable, Binary)
deriveSafeCopy 0 'base ''GetHalonVars
