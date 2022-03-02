{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Internal structures and template haskell code.
module HA.RecoveryCoordinator.Castor.Drive.Rules.Internal
  ( CheckAndHandleState(..)
  , chsSmartRequest
  , chsNode
  , chsStorageDevice
  , chsSyncRequest
  , chsLocation
  ) where

import Control.Lens
import Data.UUID
import HA.RecoveryCoordinator.Job.Actions
import HA.Resources
import HA.Resources.Castor

-- | State of the mkcheck rule.
data CheckAndHandleState = CheckAndHandleState
      { _chsNode          :: Node
         -- ^ Node where disk is located.
      , _chsStorageDevice :: StorageDevice
         -- ^ Storage device we work with.
      , _chsLocation      :: Slot
         -- ^ Known location of the storage device.
      , _chsSyncRequest   :: Maybe UUID
         -- ^ UUID configuration sync request
      , _chsSmartRequest  :: Maybe ListenerId
         -- ^ Listeners ID of the smart check rule.
      }

makeLenses ''CheckAndHandleState
