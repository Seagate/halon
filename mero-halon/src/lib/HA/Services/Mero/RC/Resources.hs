{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
-- |
-- Copyright : (C) 2016 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Contains all resources for RC subsystem of the Recovery coordinator.
module HA.Services.Mero.RC.Resources where

import qualified HA.Resources as R
import qualified HA.Resources.Castor as R
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.RC as RC
import HA.Resources.TH
import HA.SafeCopy

import Data.Hashable (Hashable(..))
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import HA.RecoveryCoordinator.Mero.Events
import Data.Word

-- | Peninding notification to mero services.
data StateDiff = StateDiff
   { stateEpoch   :: Word64
   , stateDiffMsg :: InternalObjectStateChangeMsg
   , stateDiffOnCommit :: [OnCommit]
   } deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable StateDiff

data StateDiffIndex = StateDiffIndex Word64
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable StateDiffIndex

-- | Action that should happen when notifications were delivered.
data OnCommit = DoSyncGraph
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable OnCommit
deriveSafeCopy 0 'base ''OnCommit
deriveSafeCopy 0 'base ''StateDiff
deriveSafeCopy 0 'base ''StateDiffIndex

data WaitingFor = WaitingFor
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable WaitingFor
deriveSafeCopy 0 'base ''WaitingFor

data DeliveredTo = DeliveredTo
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable DeliveredTo
deriveSafeCopy 0 'base ''DeliveredTo

data ShouldDeliverTo = ShouldDeliverTo
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable ShouldDeliverTo
deriveSafeCopy 0 'base ''ShouldDeliverTo

data DeliveryFailedTo = DeliveryFailedTo
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable DeliveryFailedTo
deriveSafeCopy 0 'base ''DeliveryFailedTo

$(mkDicts
  [ ''StateDiff, ''WaitingFor, ''DeliveredTo, ''ShouldDeliverTo, ''DeliveryFailedTo
  , ''StateDiffIndex
  ]
  [ (''RC.RC, ''R.Has, ''StateDiff)
  , (''StateDiff, ''WaitingFor, ''M0.Process)
  , (''StateDiff, ''DeliveredTo, ''M0.Process)
  , (''StateDiff, ''ShouldDeliverTo, ''M0.Process)
  , (''StateDiff, ''DeliveryFailedTo, ''M0.Process)
  , (''StateDiffIndex, ''R.Is, ''StateDiff)
  ])

$(mkResRel
  [ ''StateDiff, ''WaitingFor, ''DeliveredTo, ''ShouldDeliverTo, ''DeliveryFailedTo
  , ''StateDiffIndex
  ]
  [ (''RC.RC, AtMostOne, ''R.Has, Unbounded, ''StateDiff)
  , (''StateDiff, Unbounded, ''WaitingFor, Unbounded, ''M0.Process)
  , (''StateDiff, Unbounded, ''DeliveredTo, Unbounded, ''M0.Process)
  , (''StateDiff, Unbounded, ''ShouldDeliverTo, Unbounded, ''M0.Process)
  , (''StateDiff, Unbounded, ''DeliveryFailedTo, Unbounded, ''M0.Process)
  , (''StateDiffIndex, AtMostOne, ''R.Is, AtMostOne, ''StateDiff)
  ]
  [])
