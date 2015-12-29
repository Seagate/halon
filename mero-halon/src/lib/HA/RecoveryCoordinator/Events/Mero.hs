-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}
module HA.RecoveryCoordinator.Events.Mero
   ( SyncComplete(..)
   , NewMeroClient(..)
   , NewMeroClientProcessed(..)
   -- * Requests 
   , GetSpielAddress(..)
   )
   where

import HA.Resources
import HA.Resources.Castor
import Control.Distributed.Process (ProcessId)

import Data.Binary (Binary)
import Data.Typeable
import Data.UUID
import GHC.Generics

data SyncComplete = SyncComplete UUID
      deriving (Eq, Show, Typeable, Generic) 

instance Binary SyncComplete

-- | New mero client was connected.
data NewMeroClient = NewMeroClient Node
      deriving (Eq, Show, Typeable, Generic)

instance Binary NewMeroClient


-- | Event about processing 'NewMeroClient' event.
data NewMeroClientProcessed = NewMeroClientProcessed Host
       deriving (Eq, Show, Typeable, Generic)

instance Binary NewMeroClientProcessed

data GetSpielAddress = GetSpielAddress ProcessId
       deriving (Eq, Show, Typeable, Generic)
instance Binary GetSpielAddress
