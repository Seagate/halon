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
  ( ruleResetAttempt
  , ruleResetInit
  ) where

import HA.EventQueue.Types
  ( HAEvent(..)
  , UUID
  )
import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Hardware
import HA.RecoveryCoordinator.Actions.Mero
import HA.RecoveryCoordinator.Castor.Drive.Events
import HA.RecoveryCoordinator.Castor.Drive.Actions
import HA.RecoveryCoordinator.Events.Mero
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
import Mero.Notification.HAState (HAMsg(..), Note(..), StobIoqError(..))

import Control.Distributed.Process
  ( Process )
import Control.Lens
import Control.Monad
  ( forM_
  , when
  , unless
  , join
  )
import Data.Either (isRight)
import Data.Foldable (for_)
import Data.Proxy (Proxy(..))
import Data.Maybe (mapMaybe)
import Data.Text (Text, pack)
import Data.Vinyl

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

-- | Wait for disk messages indicating that we should perhaps start
-- disk reset. This can either be 'M0_NC_TRANSIENT' for an 'M0.SDev'
-- sent through @m0_ha_state_set@ ('Set') or 'StobIoqError'.
ruleResetInit :: Definitions LoopState ()
ruleResetInit = define "rule-reset-init" $ do
  dispatch_wait <- phaseHandle "dispatch_wait"
  disks_transient <- phaseHandle "wait_disks_transient"
  disk_ioq_error <- phaseHandle "disk_ioq_error"

  directly dispatch_wait $ do
    switch [disks_transient, disk_ioq_error]

  setPhaseIf disks_transient nvecTransients $ \(eid, m0sdevs) -> do
    todo eid
    tryStartReset m0sdevs
    done eid

  setPhaseIf disk_ioq_error ioqDisk $ \(eid, m0sdev) -> do
    todo eid
    tryStartReset [m0sdev]
    done eid

  startFork dispatch_wait ()
  where
    ioqDisk (HAEvent eid (HAMsg stob _) _) ls _ = return $
      (eid,) <$> M0.lookupConfObjByFid (_sie_conf_sdev stob) (lsGraph ls)

    mkTransientDisk rg (Note fid' M0_NC_TRANSIENT) = M0.lookupConfObjByFid fid' rg
    mkTransientDisk _ _ = Nothing

    nvecTransients (HAEvent eid (Set nvec) _) ls _ =
      return $ case mapMaybe (mkTransientDisk (lsGraph ls)) nvec of
        xs@(_ : _) -> Just (eid, xs)
        _ -> Nothing

-- | Try to start reset (through 'ResetAttempt') on the given 'M0.SDev's.
tryStartReset :: [M0.SDev] -> PhaseM LoopState l ()
tryStartReset sdevs = for_ sdevs $ \m0sdev -> do
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

              sdevTransition <- checkDiskFailureWithinTolerance m0sdev status <$> getLocalGraph
              when (ratt > resetAttemptThreshold) $ do
                phaseLog "warning" "drive have failed to reset too many times => making as failed."
                when (isRight sdevTransition) $
                  updateDriveManagerWithFailure sdev "HALON-FAILED" (Just "MERO-Timeout")

              -- Notify rest of system if stat actually changed
              when (st /= status) $ do
                either
                  (\failedTransition -> do
                    iemFailureOverTolerance m0sdev
                    applyStateChangesCreateFS [ failedTransition ])
                  (\okTransition -> applyStateChangesCreateFS [ okTransition ])
                  sdevTransition

                promulgateRC $ ResetAttempt sdev

    _ -> do
      phaseLog "warning" $ "Cannot find all entities attached to M0"
                        ++ " storage device: "
                        ++ show m0sdev
                        ++ ": "
                        ++ show msdev

jobResetAttempt :: Job ResetAttempt ResetAttemptResult
jobResetAttempt = Job "reset-attempt"

ruleResetAttempt :: Definitions LoopState ()
ruleResetAttempt = mkJobRule jobResetAttempt args $ \finish -> do
      reset         <- phaseHandle "reset"
      resetComplete <- phaseHandle "reset-complete"
      smart         <- phaseHandle "smart"
      smartResponse <- phaseHandle "smart-response"
      failure       <- phaseHandle "failure"
      drive_removed <- phaseHandle "drive-removed"

      let home (ResetAttempt sdev) = do
            nodes <- getSDevNode sdev
            paths <- lookupStorageDeviceSerial sdev
            case (nodes, paths) of
              (node : _, serial : _) -> do
                modify Local $ rlens fldNode . rfield .~ Just node
                modify Local $ rlens fldRep . rfield .~ Just (ResetAttemptFailure $ ResetFailure sdev)
                modify Local $ rlens fldDeviceInfo . rfield .~
                  (Just $ DeviceInfo sdev (pack serial))

                isStorageDriveRemoved sdev >>= \case
                  True -> do
                    phaseLog "info" $ "Cancelling drive reset as drive is removed."
                    phaseLog "sdev" $ show sdev
                    return $ Just [finish]
                  False -> do
                    markOnGoingReset sdev
                    return $ Just [drive_removed, reset]
              ([], _) -> do
                 -- XXX: send IEM message
                 phaseLog "warning" $ "Can't perform query to SSPL as node can't be found"
                 return $ Just [finish]
              (_, []) -> do
                -- XXX: send IEM message
                phaseLog "warning" $ "Cannot perform reset attempt for drive "
                                  ++ show sdev
                                  ++ " as it has no device serial number associated."
                return $ Just [finish]

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
          switch [drive_removed, smart, timeout driveResetTimeout failure]
        else do
          phaseLog "debug" $ "Drive reset failure for sdev: " ++ show sdev
          messageProcessed eid
          continue failure

      setPhaseIf smart driveOKSdev $ \() -> do
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
                    continue finish)
        (\m0sdev -> do
           getLocalGraph <&> getState m0sdev >>= \case
             M0.SDSTransient _ -> do
               applyStateChangesCreateFS [ stateSet m0sdev M0.SDSOnline ]
               Just (ResetAttempt sdev) <- gets Local (^. rlens fldReq . rfield)
               modify Local $ rlens fldRep . rfield .~ Just (ResetAttemptSuccess $ ResetSuccess sdev)
             x ->
               phaseLog "info" $ "Cannot bring drive Online from state "
                               ++ show x
           continue finish)

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
            modify Local $ rlens fldRep . rfield .~ Just (ResetAttemptSuccess $ ResetSuccess sdev)
            continue finish
          _ -> do
            phaseLog "info" "Unsuccessful SMART test."
            continue failure

      directly failure $ do
        Just (DeviceInfo sdev _) <- gets Local (^. rlens fldDeviceInfo . rfield)
        phaseLog "info" $ "Drive reset failure for " ++ show sdev
        promulgateRC $ ResetFailure sdev
        sd <- lookupStorageDeviceSDev sdev
        forM_ sd $ \m0sdev -> do
          sdevTransition <- checkDiskFailureWithinTolerance m0sdev M0.SDSFailed <$> getLocalGraph
          when (isRight sdevTransition) $
            updateDriveManagerWithFailure sdev "HALON-FAILED" (Just "MERO-Timeout")

            -- Let note handler deal with repair logic
          getLocalGraph <&> getState m0sdev >>= \case
            M0.SDSTransient _ -> do
              either (\failedTransition -> do
                         iemFailureOverTolerance m0sdev
                         applyStateChangesCreateFS [ failedTransition ])
                     (\okTransition -> applyStateChangesCreateFS [ okTransition ])
                     sdevTransition
            x -> do
              phaseLog "info" $ "Cannot bring drive Failed from state "
                              ++ show x
        continue finish

      setPhaseIf drive_removed onDriveRemoved $ \sdev -> do
        phaseLog "info" "Cancelling drive reset as drive removed."
        -- Claim all things are complete
        markResetComplete sdev
        modify Local $ rlens fldRep . rfield .~ Just (ResetAttemptSuccess $ ResetSuccess sdev)
        continue finish

      return home
  where
    fldRep = Proxy :: Proxy '("reply", Maybe ResetAttemptResult)
    fldReq = Proxy :: Proxy '("request", Maybe ResetAttempt)
    args = fldNode       =: Nothing
       <+> fldDeviceInfo =: Nothing
       <+> fldListenerId =: Nothing
       <+> fldRep        =: Nothing
       <+> fldReq        =: Nothing

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

driveOKSdev :: forall g l. (FldDeviceInfo ∈ l)
            => DriveOK
            -> g
            -> FieldRec l
            -> Process (Maybe ())
driveOKSdev (DriveOK _ _ _ x) _ l =
  return $ case l ^. rlens fldDeviceInfo . rfield of
    Just (DeviceInfo sdev _) | sdev == x -> Just ()
    _ -> Nothing
