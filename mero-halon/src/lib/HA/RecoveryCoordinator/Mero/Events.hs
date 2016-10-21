-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Events for the mero RC.
module HA.RecoveryCoordinator.Mero.Events
  ( ForceObjectStateUpdateRequest(..)
  , ForceObjectStateUpdateReply(..)
  , UpdateResult(..)
  ) where

import qualified Mero.ConfC as M0 (Fid)


import Data.Binary (Binary)
import Data.Typeable (Typeable)
import Control.Distributed.Process
import GHC.Generics (Generic)

-- | Request force update of the configuration object state.
data ForceObjectStateUpdateRequest = ForceObjectStateUpdateRequest
  [(M0.Fid, String)]
  (SendPort ForceObjectStateUpdateReply)
  deriving (Generic, Typeable, Show)

instance Binary ForceObjectStateUpdateRequest

-- | Result of the update operation
data UpdateResult
      = Success         -- ^ Operation completed succesfully
      | ObjectNotFound  -- ^ Object to update was not found
      | DictNotFound    -- ^ Object can't be updated
      | ParseFailed     -- ^ Failed to parse object state.
      deriving (Generic, Typeable, Show)
instance Binary UpdateResult

-- | Reply to the 'ForceObjectStateUpdateRequest'
newtype ForceObjectStateUpdateReply = ForceObjectStateUpdateReply [(M0.Fid, UpdateResult)]
  deriving (Generic, Typeable, Show, Binary)
