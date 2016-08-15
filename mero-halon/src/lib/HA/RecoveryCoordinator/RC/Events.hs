-- |
-- Copyright : (C) 2016 Xyratex Technology Limited.
-- License   : All rights reserved.
--
module HA.RecoveryCoordinator.RC.Events
  ( SubscribeToRequest(..)
  , SubscribeToReply(..)
  , UnsubscribeFromRequest(..)
  ) where

import Control.Distributed.Process
  ( ProcessId )
import Data.Binary (Binary)
import Data.ByteString (ByteString)
import Data.Typeable (Typeable)
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
