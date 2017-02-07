-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeOperators #-}
module HA.Services.SSPL.LL.RC.Actions
  ( CommandChan
  , findActiveSSPLChannel
  , getCommandChannel
  , getIEMChannel
  , getAllIEMChannels
  , getAllCommandChannels
  , sendInterestingEvent
  , storeCommandChannel
  , storeIEMChannel
    -- * SSPL Command Acknowledgement
  , fldCommandAck
  , mkDispatchAwaitCommandAck
  ) where

import HA.EventQueue (HAEvent(..))
import HA.RecoveryCoordinator.RC.Actions
import HA.RecoveryCoordinator.RC.Actions.Dispatch
import HA.Services.SSPL.LL.Resources
import qualified HA.ResourceGraph as G
import qualified HA.Resources as R
import qualified HA.Resources.Castor as R

import SSPL.Bindings

import Control.Lens
import Control.Monad (when)
import Control.Distributed.Process (sendChan)

import Data.Map (Map)
import Data.Maybe (catMaybes, listToMaybe)
import Data.List (delete)
import qualified Data.Map as Map
import Data.Proxy (Proxy(..))
import Data.UUID (UUID)
import qualified Data.Text as T
import Data.Typeable (Typeable)
import Data.Vinyl

import Network.CEP

-- | Channel for actuator commands.
type CommandChan = Channel (Maybe UUID, ActuatorRequestMessageActuator_request_type)

newtype SSPLCmdChannels = SSPLCmdChannels (Map R.Node CommandChan)
  deriving (Typeable)

newtype SSPLIEMChannels = SSPLIEMChannels (Map R.Node (Channel InterestingEventMessage))
  deriving (Typeable)

-- | Load command channel for the given node.
getCommandChannel :: R.Node
                  -> PhaseM RC l (Maybe CommandChan)
getCommandChannel node = ((\(SSPLCmdChannels mp) -> Map.lookup node mp) =<<) <$> getStorageRC

-- | Load IEM channel for the given node.
getIEMChannel :: R.Node
              -> PhaseM RC l (Maybe (Channel InterestingEventMessage))
getIEMChannel node = ((\(SSPLIEMChannels mp) -> Map.lookup node mp) =<<) <$> getStorageRC

-- | Find an active SSPL channel in the cluster.
findActiveSSPLChannel :: PhaseM RC l (Maybe CommandChan)
findActiveSSPLChannel = do
  rg <- getLocalGraph
  let nodes = [ node
              | host <- G.connectedTo R.Cluster R.Has rg :: [R.Host]
              , node <- G.connectedTo host R.Runs rg :: [R.Node]
              , not (G.isConnected host R.Has R.HA_TRANSIENT rg)
              ]
  chans <- catMaybes <$> mapM getCommandChannel nodes
  return $ listToMaybe chans

-- | Load all IEM channels for broadcast events.
getAllIEMChannels :: PhaseM RC l [Channel InterestingEventMessage]
getAllIEMChannels = do
  mp <- getStorageRC
  case mp of
    Nothing -> return []
    Just (SSPLIEMChannels m) -> return (Map.elems m)

-- | Load all command channels.
getAllCommandChannels :: PhaseM RC l [Channel (Maybe UUID, ActuatorRequestMessageActuator_request_type)]
getAllCommandChannels = do
  mp <- getStorageRC
  case mp of
    Nothing -> return []
    Just (SSPLCmdChannels m) -> return (Map.elems m)

-- | Store command channel, invalidating previous one.
storeCommandChannel :: R.Node
                    -> Channel (Maybe UUID, ActuatorRequestMessageActuator_request_type)
                    -> PhaseM RC l ()
storeCommandChannel node chan = do
  msp <- getStorageRC
  putStorageRC $ SSPLCmdChannels $ case msp of
    Nothing -> Map.singleton node chan
    Just (SSPLCmdChannels mp) -> Map.insert node chan mp

-- | Store iem channel, invalidating previous one.
storeIEMChannel :: R.Node
                -> Channel InterestingEventMessage
                -> PhaseM RC l ()
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
                          -> PhaseM RC (FieldRec l) () -- ^ Logging action
                          -> RuleM RC (FieldRec l) (Jump PhaseHandle)
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
    onCommandAck (HAEvent eid cmd) _ l =
      case (l ^. rlens fldCommandAck . rfield, commandAckUUID cmd) of
        (xs, Just y) | y `elem` xs -> return $ Just (eid, y, cmd)
        _ -> return Nothing

-- | Send 'InterestingEventMessage' to any IEM channel available.
sendInterestingEvent :: InterestingEventMessage
                     -> PhaseM RC l ()
sendInterestingEvent msg = do
  phaseLog "action" "Sending InterestingEventMessage."
  chanm <- listToMaybe <$> getAllIEMChannels
  case chanm of
    Just (Channel chan) -> liftProcess $ sendChan chan msg
    _ -> phaseLog "warning" "Cannot find IEM channel!"
