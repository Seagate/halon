{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
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

import Data.Binary (Binary(..))
import Data.Hashable (Hashable(..))
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import HA.RecoveryCoordinator.Events.Mero
import Data.Word

-- | Peninding notification to mero services.
data StateDiff = StateDiff
   { stateEpoch   :: Word64
   , stateDiffMsg :: InternalObjectStateChangeMsg
   , stateDiffOnCommit :: [OnCommit]
   } deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable StateDiff
instance Binary   StateDiff

data StateDiffIndex = StateDiffIndex Word64
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable StateDiffIndex
instance Binary   StateDiffIndex

-- | Action that should happen when notifications were delivered.
data OnCommit = DoSyncGraph
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable OnCommit
instance Binary OnCommit

data WaitingFor = WaitingFor
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable WaitingFor
instance Binary   WaitingFor

data DeliveredTo = DeliveredTo
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable DeliveredTo
instance Binary   DeliveredTo

data ShouldDeliverTo = ShouldDeliverTo
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable ShouldDeliverTo
instance Binary   ShouldDeliverTo

data DeliveryFailedTo = DeliveryFailedTo
  deriving (Eq, Ord, Generic, Typeable, Show)
instance Hashable DeliveryFailedTo
instance Binary   DeliveryFailedTo


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
  [ (''RC.RC, ''R.Has, ''StateDiff)
  , (''StateDiff, ''WaitingFor, ''M0.Process)
  , (''StateDiff, ''DeliveredTo, ''M0.Process)
  , (''StateDiff, ''ShouldDeliverTo, ''M0.Process)
  , (''StateDiff, ''DeliveryFailedTo, ''M0.Process)
  , (''StateDiffIndex, ''R.Is, ''StateDiff)
  ]
  [])