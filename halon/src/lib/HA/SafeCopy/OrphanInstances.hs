-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Orphan SafeCopy instances. We might move this upstream at some point.
--
{-# LANGUAGE TemplateHaskell #-}
module HA.SafeCopy.OrphanInstances where

import Control.Distributed.Process (ProcessId, NodeId)
import Data.Binary (Binary, encode, decode)
import Data.Defaultable (Defaultable)
import Data.SafeCopy (SafeCopy(..), primitive, contain, deriveSafeCopy, base)
import Data.Serialize (Serialize(..))
import Data.Typeable (Typeable)
import Data.UUID (UUID)
import Network.Transport (EndPointAddress)
import System.Clock (TimeSpec)


instance Serialize TimeSpec
instance SafeCopy TimeSpec where
  kind = primitive

instance Binary a => SafeCopy (Defaultable a) where
  putCopy = contain . put . encode
  getCopy = contain $ fmap decode get

instance SafeCopy ProcessId where
  putCopy = contain . put . encode
  getCopy = contain $ fmap decode get
  kind = primitive

instance SafeCopy UUID where
  putCopy = contain . put . encode
  getCopy = contain $ fmap decode get
  kind = primitive

deriveSafeCopy 0 'base ''NodeId
deriveSafeCopy 0 'base ''EndPointAddress