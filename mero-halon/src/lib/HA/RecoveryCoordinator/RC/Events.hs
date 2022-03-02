{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
module HA.RecoveryCoordinator.RC.Events
  ( SubscribeToRequest(..)
  , SubscribeToReply(..)
  , UnsubscribeFromRequest(..)
  , GetHalonVars(..)
  ) where

import Control.Distributed.Process (ProcessId, SendPort)
import Data.ByteString (ByteString)
import Data.Typeable (Typeable)
import HA.SafeCopy
import HA.Resources.HalonVars
import GHC.Generics

-- | Request for process subscription.
data SubscribeToRequest = SubscribeToRequest !ProcessId !ByteString
  deriving (Eq, Show, Generic, Typeable)
deriveSafeCopy 0 'base ''SubscribeToRequest

-- | Reply for process subscription.
newtype SubscribeToReply = SubscribeToReply ByteString
  deriving (Eq, Show, Generic, Typeable)
deriveSafeCopy 0 'base ''SubscribeToReply

-- | Request for process unsubscription.
data UnsubscribeFromRequest = UnsubscribeFromRequest !ProcessId !ByteString
  deriving (Eq, Show, Generic, Typeable)
deriveSafeCopy 0 'base ''UnsubscribeFromRequest

-- | Request current halon vars.
newtype GetHalonVars = GetHalonVars (SendPort HalonVars)
  deriving (Eq, Show, Generic, Typeable)
deriveSafeCopy 0 'base ''GetHalonVars
