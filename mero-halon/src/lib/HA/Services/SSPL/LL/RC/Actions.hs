-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeOperators #-}
module HA.Services.SSPL.LL.RC.Actions
  ( getCommandChannel
  , getIEMChannel
  , getAllIEMChannels
  , getAllCommandChannels
  , storeCommandChannel
  , storeIEMChannel
    -- * SSPL Command Acknowledgement
  , fldCommandAck
  , mkDispatchAwaitCommandAck
  ) where

import HA.EventQueue.Types (HAEvent(..))
import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Dispatch
import HA.Services.SSPL.LL.Resources
import qualified HA.Resources as R

import SSPL.Bindings

import Control.Lens
import Control.Monad (when)

import Data.Map (Map)
import Data.List (delete)
import qualified Data.Map as Map
import Data.Proxy (Proxy(..))
import Data.UUID (UUID)
import qualified Data.Text as T
import Data.Typeable (Typeable)
import Data.Vinyl

import Network.CEP

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

-- Rule Fragments

-- | Set of UUIDs to await.
type FldCommandAck = '("spplCommandAck", [UUID])

-- | Command acknowledgements to wait for
fldCommandAck :: Proxy FldCommandAck
fldCommandAck = Proxy

-- | Create a dispatcher phase to await a command acknowledgement.
mkDispatchAwaitCommandAck :: forall l. (FldDispatch ∈ l, FldCommandAck ∈ l)
                          => Jump PhaseHandle -- ^ dispatcher
                          -> Jump PhaseHandle -- ^ failed phase
                          -> PhaseM LoopState (FieldRec l) () -- ^ Logging action
                          -> RuleM LoopState (FieldRec l) (Jump PhaseHandle)
mkDispatchAwaitCommandAck dispatcher failed logAction = do
    sspl_notify_done <- phaseHandle "dispatcher:await:sspl"

    setPhaseIf sspl_notify_done onCommandAck $ \(eid, uid, ack) -> do
      phaseLog "debug" "SSPL notification complete"
      logAction
      modify Local $ rlens fldCommandAck . rfield %~ (delete uid)
      messageProcessed eid
      remaining <- gets Local (^. rlens fldCommandAck . rfield)
      when (null remaining) $ waitDone sspl_notify_done

      phaseLog "info" $ "SSPL ack for command "  ++ show (commandAckType ack)
      case commandAck ack of
        AckReplyPassed -> do
          phaseLog "info" $ "SSPL command successful."
          continue dispatcher
        AckReplyFailed -> do
          phaseLog "warning" $ "SSPL command failed."
          continue failed
        AckReplyError msg -> do
          phaseLog "error" $ "Error received from SSPL: " ++ (T.unpack msg)
          continue failed

    return sspl_notify_done
  where
    -- Phase guard for command acknowledgements
    onCommandAck (HAEvent eid cmd _) _ l =
      case (l ^. rlens fldCommandAck . rfield, commandAckUUID cmd) of
        (xs, Just y) | y `elem` xs -> return $ Just (eid, y, cmd)
        _ -> return Nothing
