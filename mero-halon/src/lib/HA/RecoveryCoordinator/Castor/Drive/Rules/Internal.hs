-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Internal structures and template haskell code.
{-# LANGUAGE TemplateHaskell #-}
module HA.RecoveryCoordinator.Castor.Drive.Rules.Internal
  ( CheckAndHandleState(..)
  , chsSmartRequest
  , chsNode
  , chsStorageDevice
  , chsSyncRequest
  ) where

import Control.Lens
import HA.RecoveryCoordinator.Job.Actions

import HA.Resources
import HA.Resources.Castor
import Data.UUID

-- | State of the mkcheck rule.
data CheckAndHandleState = CheckAndHandleState 
      { _chsNode          :: Node
         -- ^ Node where disk is located.
      , _chsStorageDevice :: StorageDevice
         -- ^ Storage device we work with.
      , _chsSyncRequest   :: Maybe UUID
         -- ^ UUID configuration sync request
      , _chsSmartRequest  :: Maybe ListenerId
         -- ^ Listeners ID of the smart check rule.
      }

makeLenses ''CheckAndHandleState
