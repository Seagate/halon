{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StrictData            #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
-- |
--  Module   : HA.Services.Mero.RC.Resources
-- Copyright : (C) 2016-2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Contains all resources for RC subsystem of the Recovery coordinator.
module HA.Services.Mero.RC.Resources where

import           Data.Hashable (Hashable(..))
import           Data.Typeable (Typeable)
import           Data.Word
import           GHC.Generics (Generic)
import           HA.Aeson
import           HA.RecoveryCoordinator.Mero.Events
import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.RC as RC
import           HA.Resources.TH
import           HA.SafeCopy

-- | Pending notification to mero services.
data StateDiff = StateDiff
   { stateEpoch   :: Word64
   , stateDiffMsg :: InternalObjectStateChangeMsg
   , stateDiffOnCommit :: [OnCommit]
   } deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable StateDiff
instance ToJSON StateDiff

-- | Graph index for 'StateDiff's.
newtype StateDiffIndex = StateDiffIndex Word64
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable StateDiffIndex
instance ToJSON StateDiffIndex

-- | Action that should happen when notifications were delivered.
data OnCommit = DoSyncGraph
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable OnCommit
instance ToJSON OnCommit

storageIndex ''StateDiff "9e9b93cb-babc-4a57-803f-ede59406f817"
storageIndex ''StateDiffIndex "f8e1b7e0-aedd-4783-a10f-af4cdf85652a"
storageIndex ''OnCommit "1ca007a0-181a-4d35-a6e9-bde3295b9941"
deriveSafeCopy 0 'base ''OnCommit
deriveSafeCopy 0 'base ''StateDiff
deriveSafeCopy 0 'base ''StateDiffIndex

-- | The 'StateDiff' was delivered to the process.
data DeliveredTo = DeliveredTo
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable DeliveredTo
storageIndex ''DeliveredTo "4a3b04c2-0b21-49a4-a6a0-d078298f97fa"
deriveSafeCopy 0 'base ''DeliveredTo
instance ToJSON DeliveredTo

-- | The 'StateDiff' is due to be delivered to the process.
data ShouldDeliverTo = ShouldDeliverTo
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable ShouldDeliverTo
storageIndex ''ShouldDeliverTo "b82e8c35-df8c-4a97-b1cb-dba3fe4a27a3"
deriveSafeCopy 0 'base ''ShouldDeliverTo
instance ToJSON ShouldDeliverTo

-- | Delivery of the 'StateDiff' to the process has failed.
data DeliveryFailedTo = DeliveryFailedTo
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable DeliveryFailedTo
storageIndex ''DeliveryFailedTo "759a77f6-0994-4fc7-86e7-e4e73b41478a"
deriveSafeCopy 0 'base ''DeliveryFailedTo
instance ToJSON DeliveryFailedTo

$(mkDicts
  [ ''StateDiff, ''DeliveredTo, ''ShouldDeliverTo, ''DeliveryFailedTo
  , ''StateDiffIndex
  ]
  [ (''RC.RC, ''R.Has, ''StateDiff)
  , (''StateDiff, ''DeliveredTo, ''M0.Process)
  , (''StateDiff, ''ShouldDeliverTo, ''M0.Process)
  , (''StateDiff, ''DeliveryFailedTo, ''M0.Process)
  , (''StateDiffIndex, ''R.Is, ''StateDiff)
  ])

$(mkResRel
  [ ''StateDiff, ''DeliveredTo, ''ShouldDeliverTo, ''DeliveryFailedTo
  , ''StateDiffIndex
  ]
  [ (''RC.RC, AtMostOne, ''R.Has, Unbounded, ''StateDiff)
  , (''StateDiff, Unbounded, ''DeliveredTo, Unbounded, ''M0.Process)
  , (''StateDiff, Unbounded, ''ShouldDeliverTo, Unbounded, ''M0.Process)
  , (''StateDiff, Unbounded, ''DeliveryFailedTo, Unbounded, ''M0.Process)
  , (''StateDiffIndex, AtMostOne, ''R.Is, AtMostOne, ''StateDiff)
  ]
  [])
