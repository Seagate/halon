{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
-- |
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Resources to assist with updating the resource graph.
module HA.Resources.Update where

import Control.Distributed.Process (ProcessId)
import Control.Distributed.Static (Static)
import Data.Binary (Binary, decode, encode)
import Data.Hashable (Hashable(..))
import Data.Serialize.Get
  ( remaining, getLazyByteString )
import Data.Serialize.Put (putLazyByteString)
import Data.Typeable (Typeable)
import HA.RecoveryCoordinator.RC.Application (RC)
import HA.Resources (Cluster, Has)
import HA.Resources.TH
import HA.SafeCopy
import Network.CEP hiding (get, put)

-- | A 'Todo' node may be used to store a computation needed
--   to complete an update.
--
--   Todo actions are limited to a single phase and may take the
--   RC process ID in local state.
newtype Todo = Todo (Static (PhaseM RC (Maybe ProcessId) ()))
  deriving (Binary, Eq, Ord, Show, Typeable)

instance Hashable Todo where
  hashWithSalt s (Todo ph) = s `hashWithSalt` (encode ph)

-- | The Todo type cannot be updated - it is expected to last only for a
--   single RC run.
instance SafeCopy Todo where
     putCopy td = contain . putLazyByteString $ encode td
     getCopy = contain $ do
       len <- fromIntegral <$> remaining
       decode <$> getLazyByteString len

storageIndex ''Todo "8a82ed41-563d-490c-a457-7e43924cd52b"

$(mkDicts
  [''Todo]
  [ (''Cluster, ''Has, ''Todo) ])
$(mkResRel
  [''Todo]
  [ (''Cluster, AtMostOne, ''Has, AtMostOne, ''Todo) ]
  []
  )
