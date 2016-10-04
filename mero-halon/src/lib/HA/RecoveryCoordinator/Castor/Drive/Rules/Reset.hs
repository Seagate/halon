{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE ViewPatterns          #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Module containing some reset bits that multiple rules may want access to
module HA.RecoveryCoordinator.Castor.Drive.Rules.Reset
  ( handleResetExternal
  , ruleResetAttempt
  ) where

import HA.EventQueue.Types
  ( HAEvent(..)
  , UUID
  )
import HA.RecoveryCoordinator.Actions.Core
  ( LoopState
  , fldUUID
  , getLocalGraph
  , messageProcessed
  , promulgateRC
  , whenM
  )
import HA.RecoveryCoordinator.Actions.Hardware
import HA.RecoveryCoordinator.Actions.Mero
import HA.RecoveryCoordinator.Castor.Drive.Events
import HA.RecoveryCoordinator.Castor.Drive.Actions
import HA.RecoveryCoordinator.Job.Actions
import HA.RecoveryCoordinator.Job.Events
import HA.RecoveryCoordinator.Rules.Mero.Conf
import HA.Resources (Node(..))
import HA.Resources.Castor
import qualified HA.Resources.Mero as M0
import HA.Resources.Mero.Note (ConfObjectState(..), getState)
import HA.Resources.HalonVars
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
  ( Process )
import Control.Lens
import Control.Monad
  ( forM_
  , when
  , unless
  , join
  )
import Control.Monad.IO.Class

import Data.Foldable (for_)
import Data.Proxy (Proxy(..))
import Data.Text (Text, pack)
import Data.Vinyl
import Debug.Trace (traceEventIO)

import Network.CEP

data DeviceInfo = DeviceInfo {
    _diSDev :: StorageDevice
  , _diSerial :: Text
}

fldNode :: Proxy '("node", Maybe Node)
fldNode = Proxy

type FldDeviceInfo = '("deviceInfo", Maybe DeviceInfo)
-- | Device info used in SMART rule
fldDeviceInfo :: Proxy FldDeviceInfo
fldDeviceInfo = Proxy

--------------------------------------------------------------------------------
-- Reset bit                                                                  --
--------------------------------------------------------------------------------

-- | Time to allow for SSPL to reply on a reset request.
driveResetTimeout :: Int
driveResetTimeout = 5*60

-- | Time to allow for SMART rule to reply on SMART request.
smartTestTimeout :: Int
smartTestTimeout = 16*60

-- | Drive state change handler for 'reset' functionality.
--
--   Called whenever a drive changes state. This function is
--   responsible for potentially starting a reset attempt on
--   one or more drives.
handleResetExternal :: Set -> PhaseM LoopState l ()
handleResetExternal (Set ns) = do
  liftIO $ traceEventIO "START mero-halon:external-handler:reset"
  for_ ns $ \(Note mfid tpe) ->
    case tpe of
      _ | tpe == M0_NC_TRANSIENT || tpe == M0_NC_FAILED -> do
        sdevm <- lookupConfObjByFid mfid
        for_ sdevm $ \m0sdev -> do
          msdev <- lookupStorageDevice m0sdev
          case msdev of
            Just sdev -> do
              -- Drive reset rule may be triggered if drive is removed, we
              -- can't do anything sane here, so skipping this rule.
              mstatus <- driveStatus sdev
              isDrivePowered <- isStorageDevicePowered sdev
              isDriveRemoved <- isStorageDriveRemoved sdev
              phaseLog "info" $ "Handle reset"
              phaseLog "storage-device" $ show sdev
              phaseLog "storage-device.status" $ show mstatus
              phaseLog "storage-device.powered" $ show isDrivePowered
              phaseLog "storage-device.removed" $ show isDriveRemoved
              case (\(StorageDeviceStatus s _) -> s) <$> mstatus of
                _ | isDriveRemoved ->
                  phaseLog "info" "Drive is physically removed, skipping reset."
                _ | not isDrivePowered ->
                  phaseLog "info" "Drive is not powered, skipping reset."
                Just "EMPTY" ->
                  phaseLog "info" "Expander reset in progress, skipping reset."
                _ -> do
                  st <- getState m0sdev <$> getLocalGraph

                  unless (st == M0.SDSFailed) $ do
                    ongoing <- hasOngoingReset sdev
                    if ongoing
                    then phaseLog "debug" $ "Reset ongoing on a drive - ignoring message"
                    else do
                      ratt <- getDiskResetAttempts sdev
                      resetAttemptThreshold <- fmap _hv_drive_reset_max_retries getHalonVars
                      let status = if ratt <= resetAttemptThreshold
                                   then M0.sdsFailTransient st
                                   else M0.SDSFailed

                      -- We handle this status inside external rule, because we need to
                      -- update drive manager if and only if failure is set because of
                      -- mero notifications, not because drive removal or other event.
                      when (ratt > resetAttemptThreshold) $ do
                        phaseLog "warning" "drive have failed to reset too many times => making as failed."
                        updateDriveManagerWithFailure sdev "HALON-FAILED" (Just "MERO-Timeout")

                      -- Notify rest of system if stat actually changed
                      when (st /= status) $ do
                        applyStateChangesCreateFS [ stateSet m0sdev status ]
                        promulgateRC $ ResetAttempt sdev

            _ -> do
              phaseLog "warning" $ "Cannot find all entities attached to M0"
                                ++ " storage device: "
                                ++ show m0sdev
                                ++ ": "
                                ++ show msdev
      _ -> return () -- Should we do anything here?
  liftIO $ traceEventIO "STOP mero-halon:external-handler:reset"

ruleResetAttempt :: Definitions LoopState ()
ruleResetAttempt = define "reset-attempt" $ do
      home          <- phaseHandle "home"
      reset         <- phaseHandle "reset"
      resetComplete <- phaseHandle "reset-complete"
      smart         <- phaseHandle "smart"
      smartResponse <- phaseHandle "smart-response"
      failure       <- phaseHandle "failure"
      end           <- phaseHandle "end"
      drive_removed <- phaseHandle "drive-removed"

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
            modify Local $ rlens fldUUID . rfield .~ Just uid
            modify Local $ rlens fldNode . rfield .~ Just node
            modify Local $ rlens fldDeviceInfo . rfield .~
              (Just $ DeviceInfo sdev (pack serial))

            whenM (isStorageDriveRemoved sdev) $ do
              phaseLog "info" $ "Cancelling drive reset as drive is removed."
              phaseLog "sdev" $ show sdev
              continue end
            markOnGoingReset sdev
            switch [drive_removed, reset]
          [] -> do
            -- XXX: send IEM message
            phaseLog "warning" $ "Cannot perform reset attempt for drive "
                              ++ show sdev
                              ++ " as it has no device serial number associated."
            messageProcessed uid
            stop

      (disk_detached, detachDisk) <- mkDetachDisk
        (\l -> fmap join $ traverse
          (lookupStorageDeviceSDev . _diSDev)
          (l ^. rlens fldDeviceInfo . rfield))
        (\_ _ -> switch [drive_removed, resetComplete, timeout driveResetTimeout failure])
        (\_ -> switch [drive_removed, resetComplete, timeout driveResetTimeout failure])

      directly reset $ do
        Just (DeviceInfo sdev serial) <- gets Local (^. rlens fldDeviceInfo . rfield)
        Just (Node nid) <- gets Local (^. rlens fldNode . rfield)
        i <- getDiskResetAttempts sdev
        phaseLog "debug" $ "Current reset attempts: " ++ show i
        resetAttemptThreshold <- fmap _hv_drive_reset_max_retries getHalonVars
        if i <= resetAttemptThreshold
        then do
          incrDiskResetAttempts sdev
          sent <- sendNodeCmd nid Nothing (DriveReset serial)
          if sent
          then do
            phaseLog "debug" $ "DriveReset message sent for device " ++ show serial
            markDiskPowerOff sdev
            msd <- lookupStorageDeviceSDev sdev
            case msd of
              Nothing -> switch [drive_removed, resetComplete, timeout driveResetTimeout failure]
              Just sd -> do detachDisk sd
                            continue disk_detached
          else continue failure
        else continue failure

      setPhaseIf resetComplete (onCommandAck DriveReset) $ \(result, eid) -> do
        Just (DeviceInfo sdev _) <- gets Local (^. rlens fldDeviceInfo . rfield)
        markResetComplete sdev
        if result
        then do
          phaseLog "debug" $ "Drive reset success for sdev: " ++ show sdev
          markDiskPowerOn sdev
          messageProcessed eid
          switch [drive_removed, smart]
        else do
          phaseLog "debug" $ "Drive reset failure for sdev: " ++ show sdev
          messageProcessed eid
          continue failure

      directly smart $ do
        Just (DeviceInfo sdev _) <- gets Local (^. rlens fldDeviceInfo . rfield)
        Just node <- gets Local (^. rlens fldNode . rfield)
        smartId <- startJob $ SMARTRequest node sdev
        modify Local $ rlens fldListenerId . rfield .~ Just smartId
        switch [ drive_removed, smartResponse
               , timeout smartTestTimeout failure ]

      (disk_attached, attachDisk) <- mkAttachDisk
        (\l -> fmap join $ traverse
          (lookupStorageDeviceSDev . _diSDev)
          (l ^. rlens fldDeviceInfo . rfield))
        (\_ _ -> do phaseLog "error" "failed to attach disk"
                    continue end)
        (\m0sdev -> do
           getLocalGraph <&> getState m0sdev >>= \case
             M0.SDSTransient _ ->
               applyStateChangesCreateFS [ stateSet m0sdev M0.SDSOnline ]
             x ->
               phaseLog "info" $ "Cannot bring drive Online from state "
                               ++ show x
           continue end)

      setPhaseIf smartResponse onSameSdev $ \status -> do
        Just (DeviceInfo sdev _) <- gets Local (^. rlens fldDeviceInfo . rfield)
        phaseLog "sdev" $ show sdev
        phaseLog "smart.response" $ show status
        case status of
          SRSSuccess -> do
            promulgateRC $ ResetSuccess sdev
            sd <- lookupStorageDeviceSDev sdev
            forM_ sd $ \m0sdev -> do
              attachDisk m0sdev
              continue disk_attached
            continue end
          _ -> do
            phaseLog "info" "Unsuccessful SMART test."
            continue failure

      directly failure $ do
        Just (DeviceInfo sdev _) <- gets Local (^. rlens fldDeviceInfo . rfield)
        phaseLog "info" $ "Drive reset failure for " ++ show sdev
        promulgateRC $ ResetFailure sdev
        sd <- lookupStorageDeviceSDev sdev
        forM_ sd $ \m0sdev -> do
          updateDriveManagerWithFailure sdev "HALON-FAILED" (Just "MERO-Timeout")
          -- Let note handler deal with repair logic
          getLocalGraph <&> getState m0sdev >>= \case
            M0.SDSTransient _ ->
              applyStateChangesCreateFS [ stateSet m0sdev M0.SDSFailed ]
            x -> do
              phaseLog "info" $ "Cannot bring drive Failed from state "
                              ++ show x
        continue end

      directly end $ do
        Just uid <- gets Local (^. rlens fldUUID . rfield)
        messageProcessed uid
        stop

      setPhaseIf drive_removed onDriveRemoved $ \sdev -> do
        phaseLog "info" "Cancelling drive reset as drive removed."
        -- Claim all things are complete
        markResetComplete sdev
        continue end

      startFork home args
  where
    args = fldUUID       =: Nothing
       <+> fldNode       =: Nothing
       <+> fldDeviceInfo =: Nothing
       <+> fldListenerId =: Nothing

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

onCommandAck :: forall g l. (FldDeviceInfo ∈ l)
             => (Text -> NodeCmd)
             -> HAEvent CommandAck
             -> g
             -> FieldRec l
             -> Process (Maybe (Bool, UUID))
onCommandAck k (HAEvent eid cmd _) _
               ((view $ rlens fldDeviceInfo . rfield)
                -> Just (DeviceInfo _ serial)) =
  case commandAckType cmd of
    Just x | (k serial) == x -> return $ Just
              (commandAck cmd == AckReplyPassed, eid)
           | otherwise       -> return Nothing
    _ -> return Nothing
onCommandAck _ _ _ _ = return Nothing

onDriveRemoved :: forall g l. (FldDeviceInfo ∈ l)
               => DriveRemoved
               -> g
               -> FieldRec l
               -> Process (Maybe StorageDevice)
onDriveRemoved dr _ ((view $ rlens fldDeviceInfo . rfield)
                      -> Just (DeviceInfo sdev _)) =
    if drDevice dr == sdev
    then return $ Just sdev
    else return Nothing
onDriveRemoved _ _ _ = return Nothing

onSameSdev :: forall g l. (FldDeviceInfo ∈ l, FldListenerId ∈ l)
           => JobFinished SMARTResponse
           -> g
           -> FieldRec l
           -> Process (Maybe SMARTResponseStatus)
onSameSdev (JobFinished listenerIds (SMARTResponse sdev' status)) _ l =
  return $ case (,) <$> ( l ^. rlens fldDeviceInfo . rfield )
                    <*> ( l ^. rlens fldListenerId . rfield ) of
    Just (DeviceInfo sdev _, smartId)
         | smartId `elem` listenerIds
        && sdev == sdev' -> Just status
    _ -> Nothing
