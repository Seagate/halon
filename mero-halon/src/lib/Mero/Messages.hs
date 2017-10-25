-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--

module Mero.Messages
       (
         StripingError(..)
       ) where

import HA.Resources (Node_XXX2)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Data.Binary (Binary)

-- | A Mero-specific striping error has occurred. The error is detected
-- by the service wrapper and reported to the RC, who will update the epoch
data StripingError = StripingError Node_XXX2
  deriving (Typeable, Generic)

instance Binary StripingError
