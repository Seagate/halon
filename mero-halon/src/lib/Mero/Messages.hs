-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--

module Mero.Messages
       (
         StripingError(..)
       ) where

import HA.Resources (Node)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Data.Binary (Binary)

-- | A Mero-specific striping error has occurred. The error is detected
-- by the service wrapper and reported to the RC, who will update the epoch
data StripingError = StripingError Node
        deriving (Typeable, Generic)

instance Binary StripingError
