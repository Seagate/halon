-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module HA.Services.SSPL.HL.Resources where

import Data.Binary (Binary)
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Hashable (Hashable)
import Data.Typeable (Typeable)

newtype SSPLHLCmd = SSPLHLCmd BL.ByteString
  deriving (Binary, Hashable, Typeable)
