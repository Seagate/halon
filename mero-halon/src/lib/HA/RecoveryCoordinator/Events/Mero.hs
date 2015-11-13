{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}
module HA.RecoveryCoordinator.Events.Mero
   ( SyncComplete(..)
   )
   where

import Data.Binary (Binary)
import Data.Typeable
import Data.UUID
import GHC.Generics

data SyncComplete = SyncComplete UUID
      deriving (Eq, Show, Typeable, Generic) 

instance Binary SyncComplete
