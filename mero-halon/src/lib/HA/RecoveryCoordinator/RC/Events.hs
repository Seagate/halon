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
import Data.Typeable (Typeable)
import HA.Resources.HalonVars
import GHC.Generics

-- | Request for process subscription.
data SubscribeToRequest = SubscribeToRequest !ProcessId {- Fingerprint -} !ByteString
  deriving (Eq, Show, Generic, Typeable)

instance Binary SubscribeToRequest

-- | Reply for process subscription.
newtype SubscribeToReply = SubscribeToReply {- Fingerprint -} ByteString
  deriving (Eq, Show, Generic, Typeable, Binary)

-- | Request for process unsubscription.
data UnsubscribeFromRequest = UnsubscribeFromRequest !ProcessId {- Fingerprint -} !ByteString
  deriving (Eq, Show, Generic, Typeable)

instance Binary UnsubscribeFromRequest

-- | Request current halon vars.
newtype GetHalonVars = GetHalonVars (SendPort HalonVars)
  deriving (Eq, Show, Generic, Typeable, Binary)
