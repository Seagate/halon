-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Module containing some reset bits that multiple rules may want access to
module HA.RecoveryCoordinator.Rules.Castor.Reset where

import HA.EventQueue.Types
  ( HAEvent(..)
  , UUID
  )
import HA.RecoveryCoordinator.Actions.Core
  ( LoopState
  , messageProcessed
  , promulgateRC
  , syncGraph
  , unlessM
  , whenM
  )
import HA.RecoveryCoordinator.Actions.Hardware
import HA.RecoveryCoordinator.Actions.Mero (notifyDriveStateChange)
import HA.RecoveryCoordinator.Actions.Mero.Conf
  ( lookupConfObjByFid
  , lookupStorageDevice
  , lookupStorageDeviceSDev
  , queryObjectStatus
  )
import HA.Resources (Node(..))
import HA.Resources.Castor
import HA.Resources.Mero.Note (ConfObjectState(..))
import HA.Services.SSPL.CEP
  ( sendNodeCmd
  , updateDriveManagerWithFailure
  )
import HA.Services.SSPL.LL.Resources
  ( AckReply(..)
  , CommandAck(..)
  , NodeCmd(..)
  , commandAck
  )

import Mero.Notification (Set(..))
import Mero.Notification.HAState (Note(..))

import Control.Distributed.Process
  ( Process
  , say
  )
import Control.Monad
  ( forM_
  , when
  , unless
  )

import Data.Binary (Binary)
import Data.Foldable (for_)
import Data.Text (Text, pack)
import Data.Typeable (Typeable)

import GHC.Generics (Generic)

import Network.CEP
--------------------------------------------------------------------------------
-- Reset bit                                                                  --
--------------------------------------------------------------------------------

-- | When the number of reset attempts is greater than this threshold, a 'Disk'
--   should be in 'DiskFailure' status.
resetAttemptThreshold :: Int
resetAttemptThreshold = 10

-- | Time to allow for SSPL to reply on a reset request.
driveResetTimeout :: Int
driveResetTimeout = 5*60

-- | Time to allow for SSPL reply on a smart test request.
smartTestTimeout :: Int
smartTestTimeout = 15*60

-- | Event sent when to many failures has been sent for a 'Disk'.
data ResetAttempt = ResetAttempt StorageDevice
  deriving (Eq, Generic, Show, Typeable)

instance Binary ResetAttempt

-- | Event sent when a ResetAttempt were successful.
newtype ResetSuccess =
    ResetSuccess StorageDevice
    deriving (Eq, Show, Binary)

-- | Event sent when a ResetAttempt failed.
newtype ResetFailure =
    ResetFailure StorageDevice
    deriving (Eq, Show, Binary)

-- | Drive state change handler for 'reset' functionality.
--
--   Called whenever a drive changes state. This function is
--   responsible for potentially starting a reset attempt on
--   one or more drives.
handleReset :: Set -> PhaseM LoopState l ()
handleReset (Set ns) = do
  for_ ns $ \(Note mfid tpe) ->
    case tpe of
      M0_NC_TRANSIENT -> do
        sdevm <- lookupConfObjByFid mfid
        for_ sdevm $ \m0sdev -> do
          msdev <- lookupStorageDevice m0sdev
          case msdev of
            Just sdev -> do
              mst <- queryObjectStatus m0sdev
              unless (mst == Just M0_NC_FAILED) $ do
                ongoing <- hasOngoingReset sdev
                when (not ongoing) $ do
                  ratt <- getDiskResetAttempts sdev
                  let status = if ratt <= resetAttemptThreshold
                               then M0_NC_TRANSIENT
                               else M0_NC_FAILED

                  when (status == M0_NC_FAILED) $ do
                    notifyDriveStateChange m0sdev status
                    -- TODO Move this into its own handler.
                    updateDriveManagerWithFailure sdev "HALON-FAILED" (Just "MERO-Timeout")

                  when (status == M0_NC_TRANSIENT) $ do
                    promulgateRC $ ResetAttempt sdev

                  syncGraph $ say "handleReset synchronized"
            _ -> do
              phaseLog "warning" $ "Cannot find all entities attached to M0"
                                ++ " storage device: "
                                ++ show m0sdev
                                ++ ": "
                                ++ show msdev
      _ -> return () -- Should we do anything here?

ruleResetAttempt :: Definitions LoopState ()
ruleResetAttempt = define "reset-attempt" $ do
      home          <- phaseHandle "home"
      reset         <- phaseHandle "reset"
      resetComplete <- phaseHandle "reset-complete"
      smart         <- phaseHandle "smart"
      smartSuccess  <- phaseHandle "smart-success"
      smartFailure  <- phaseHandle "smart-failure"
      failure       <- phaseHandle "failure"
      end           <- phaseHandle "end"

      setPhase home $ \(HAEvent uid (ResetAttempt sdev) _) -> fork NoBuffer $ do
        nodes <- getSDevNode sdev
        node <- case nodes of
          node:_ -> return node
          [] -> do
             -- XXX: send IEM message
             phaseLog "warning" $ "Can't perform query to SSPL as node can't be found"
             messageProcessed uid
             stop
        paths <- lookupStorageDeviceSerial sdev
        case paths of
          serial:_ -> do
            put Local (Just (sdev, pack serial, node, uid))
            unlessM (isStorageDevicePowered sdev) $
              switch [resetComplete, timeout driveResetTimeout failure]
            whenM (isStorageDeviceRunningSmartTest sdev) $
              switch [smartSuccess, smartFailure, timeout smartTestTimeout failure]
            markOnGoingReset sdev
            continue reset
          [] -> do
            -- XXX: send IEM message
            phaseLog "warning" $ "Cannot perform reset attempt for drive "
                              ++ show sdev
                              ++ " as it has no device paths associated."
            messageProcessed uid
            stop

      directly reset $ do
        Just (sdev, serial, Node nid, _) <- get Local
        i <- getDiskResetAttempts sdev
        if i <= resetAttemptThreshold
        then do
          incrDiskResetAttempts sdev
          sent <- sendNodeCmd nid Nothing (DriveReset serial)
          if sent
          then do markDiskPowerOff sdev
                  switch [resetComplete, timeout driveResetTimeout failure]
          else continue failure
        else continue failure

      setPhaseIf resetComplete (onCommandAck DriveReset) $ \(result, eid) -> do
        Just (sdev, _, _, _) <- get Local
        markResetComplete sdev
        if result
        then do markDiskPowerOn sdev
                messageProcessed eid
                continue smart
        else do messageProcessed eid
                continue failure

      directly smart $ do
        Just (sdev, serial, Node nid, _) <- get Local
        sent <- sendNodeCmd nid Nothing (SmartTest serial)
        if sent
        then do markSMARTTestIsRunning sdev
                switch [smartSuccess, smartFailure, timeout smartTestTimeout failure]
        else continue failure

      setPhaseIf smartSuccess onSmartSuccess $ \eid -> do
        Just (sdev, _, _, _) <- get Local
        markSMARTTestComplete sdev
        sd <- lookupStorageDeviceSDev sdev
        forM_ sd $ \m0sdev ->
          notifyDriveStateChange m0sdev M0_NC_ONLINE
        messageProcessed eid
        continue end

      setPhaseIf smartFailure onSmartFailure $ \eid -> do
        Just (sdev, _, _, _) <- get Local
        markSMARTTestComplete sdev
        messageProcessed eid
        continue failure

      directly failure $ do
        Just (sdev, _, _, _) <- get Local
        sd <- lookupStorageDeviceSDev sdev
        forM_ sd $ \m0sdev -> do
          updateDriveManagerWithFailure sdev "HALON-FAILED" (Just "MERO-Timeout")
          -- Let note handler deal with repair logic
          notifyDriveStateChange m0sdev M0_NC_FAILED
        continue end

      directly end $ do
        Just (_, _, _, uid) <- get Local
        messageProcessed uid
        stop

      start home Nothing


--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- | States of the Timeout rule.OB
data TimeoutState = TimeoutNormal | ResetAttemptSent

onCommandAck :: (Text -> NodeCmd)
           -> HAEvent CommandAck
           -> g
           -> Maybe (StorageDevice, Text, Node, UUID)
           -> Process (Maybe (Bool, UUID))
onCommandAck _ _ _ Nothing = return Nothing
onCommandAck k (HAEvent eid cmd _) _ (Just (_, serial, _, _)) =
  case commandAckType cmd of
    Just x | (k serial) == x -> return $ Just
              (commandAck cmd == AckReplyPassed, eid)
           | otherwise       -> return Nothing
    _ -> return Nothing

onSmartSuccess :: HAEvent CommandAck
               -> g
               -> Maybe (StorageDevice, Text, Node, UUID)
               -> Process (Maybe UUID)
onSmartSuccess (HAEvent eid cmd _) _ (Just (_, serial, _, _)) =
    case commandAckType cmd of
      Just (SmartTest x)
        | serial == x ->
          case commandAck cmd of
            AckReplyPassed -> return $ Just eid
            _              -> return Nothing
        | otherwise -> return Nothing
      _ -> return Nothing
onSmartSuccess _ _ _ = return Nothing

onSmartFailure :: HAEvent CommandAck
               -> g
               -> Maybe (StorageDevice, Text, Node, UUID)
               -> Process (Maybe UUID)
onSmartFailure (HAEvent eid cmd _) _ (Just (_, serial, _, _)) =
    case commandAckType cmd of
      Just (SmartTest x)
        | serial == x ->
          case commandAck cmd of
            AckReplyFailed  -> return $ Just eid
            AckReplyError _ -> return $ Just eid
            _               -> return Nothing
        | otherwise -> return Nothing
      _ -> return Nothing
onSmartFailure _ _ _ = return Nothing
