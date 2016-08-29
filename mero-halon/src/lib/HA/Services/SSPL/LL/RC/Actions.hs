-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
module HA.Services.SSPL.LL.RC.Actions
  ( getCommandChannel
  , getIEMChannel
  , getAllIEMChannels
  , getAllCommandChannels
  , storeCommandChannel
  , storeIEMChannel
  ) where

import HA.RecoveryCoordinator.Actions.Core
import HA.Services.SSPL.LL.Resources
import Network.CEP
import qualified HA.Resources as R
import           Data.Map (Map)
import qualified Data.Map as Map
import Data.UUID (UUID)
import Data.Typeable (Typeable)
import SSPL.Bindings


newtype SSPLCmdChannels = SSPLCmdChannels (Map R.Node (Channel (Maybe UUID, ActuatorRequestMessageActuator_request_type)))
  deriving (Typeable)

newtype SSPLIEMChannels = SSPLIEMChannels (Map R.Node (Channel InterestingEventMessage))
  deriving (Typeable)

-- | Load command channel for the given node.
getCommandChannel :: R.Node
                  -> PhaseM LoopState l (Maybe (Channel (Maybe UUID, ActuatorRequestMessageActuator_request_type)))
getCommandChannel node = ((\(SSPLCmdChannels mp) -> Map.lookup node mp) =<<) <$> getStorageRC

-- | Load IEM channel for the given node.
getIEMChannel :: R.Node
              -> PhaseM LoopState l (Maybe (Channel InterestingEventMessage))
getIEMChannel node = ((\(SSPLIEMChannels mp) -> Map.lookup node mp) =<<) <$> getStorageRC

-- | Load all IEM channels for broadcast events.
getAllIEMChannels :: PhaseM LoopState l [Channel InterestingEventMessage]
getAllIEMChannels = do
  mp <- getStorageRC
  case mp of
    Nothing -> return []
    Just (SSPLIEMChannels m) -> return (Map.elems m)

-- | Load all command channels.
getAllCommandChannels :: PhaseM LoopState l [Channel (Maybe UUID, ActuatorRequestMessageActuator_request_type)]
getAllCommandChannels = do
  mp <- getStorageRC
  case mp of
    Nothing -> return []
    Just (SSPLCmdChannels m) -> return (Map.elems m)

-- | Store command channel, invalidating previous one.
storeCommandChannel :: R.Node
                    -> Channel (Maybe UUID, ActuatorRequestMessageActuator_request_type)
                    -> PhaseM LoopState l ()
storeCommandChannel node chan = do
  msp <- getStorageRC
  putStorageRC $ SSPLCmdChannels $ case msp of
    Nothing -> Map.singleton node chan
    Just (SSPLCmdChannels mp) -> Map.insert node chan mp

-- | Store iem channel, invalidating previous one.
storeIEMChannel :: R.Node
                -> Channel InterestingEventMessage
                 -> PhaseM LoopState l ()
storeIEMChannel node chan = do
  msp <- getStorageRC
  putStorageRC $ SSPLIEMChannels $ case msp of
    Nothing -> Map.singleton node chan
    Just (SSPLIEMChannels mp) -> Map.insert node chan mp
