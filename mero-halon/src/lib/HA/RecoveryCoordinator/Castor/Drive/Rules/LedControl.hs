{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module    : HA.RecoveryCoordinator.Castor.Drive.Rules.LedControl
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Central place dealing with LED control for drives.
module HA.RecoveryCoordinator.Castor.Drive.Rules.LedControl (rules) where

import           Control.Monad (void)
import           Data.Foldable (for_)
import           Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import qualified Data.Text as T
import           HA.EventQueue.Types (HAEvent(..))
import           HA.RecoveryCoordinator.Actions.Core
import           HA.RecoveryCoordinator.Actions.Hardware
  ( getSDevHost
  , lookupStorageDeviceSerial
  )
import           HA.RecoveryCoordinator.Castor.Drive.Events (DriveReady(..), ResetFailure(..))
import           HA.RecoveryCoordinator.Rules.Mero.Conf (setPhaseInternalNotificationWithState)
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..), Has(..))
import           HA.Resources.Castor
import qualified HA.Resources.Mero as M0
import           HA.Services.SSPL.CEP (DriveLedUpdate(..), sendLedUpdate, sendNodeCmd)
import           HA.Services.SSPL.LL.Resources (NodeCmd(DriveLed), LedControlState(..))
import           Network.CEP
import           SSPL.Bindings

rules :: Definitions LoopState ()
rules = sequence_
  [ ruleDriveFailed
  , ruleDriveReplaced
  , ruleSsplStarted
  ]

-- | A drive has become failed, set LED.
ruleDriveFailed :: Definitions LoopState ()
ruleDriveFailed = define "castor::drive::led::ruleDriveFailed" $ do

  rule_init <- phaseHandle "rule_init"
  mero_drives_failed <- phaseHandle "mero_drives_failed"
  raid_drive_failed <- phaseHandle "raid_drive_failed"

  directly rule_init $ switch [mero_drives_failed, raid_drive_failed]

  -- Drives with SDev (mero drives) have transitioned into a failing
  -- state, switch LED on.
  setPhaseInternalNotificationWithState mero_drives_failed freshly_failed $ \(eid, sds) -> do
    todo eid
    rg <- getLocalGraph
    let storDevs = [ storD | sd <- (map fst sds :: [M0.SDev])
                           , disk <- G.connectedTo sd M0.IsOnHardware rg :: [M0.Disk]
                           , storD <- G.connectedTo disk M0.At rg ]
    for_ storDevs $ \sd -> sendFailedLed sd
    done eid

  setPhaseIf raid_drive_failed is_raid_drive sendFailedLed

  startFork rule_init ()
  where
    sendFailedLed storDev = getSDevHost storDev >>= \case
      h : _ -> void $! sendLedUpdate DrivePermanentlyFailed h storDev
      _ -> phaseLog "warn" $ "No host associated with " ++ show storDev

    is_raid_drive (ResetFailure sd) ls _ = do
      let extractRaid (DIRaidDevice _) = Just ()
          extractRaid _ = Nothing
      case mapMaybe extractRaid $ G.connectedTo sd Has (lsGraph ls) of
        [] -> return $ Nothing
        _ -> return $ Just sd

    freshly_failed o n = not (isFailedState o) && isFailedState n

    isFailedState :: M0.SDevState -> Bool
    isFailedState M0.SDSFailed      = True
    isFailedState M0.SDSRepairing   = True
    isFailedState M0.SDSRepaired    = True
    isFailedState M0.SDSRebalancing = True
    isFailedState _                 = False

-- | A drive has been replaced and is ready, unset LED.
ruleDriveReplaced :: Definitions LoopState ()
ruleDriveReplaced = define "castor::drive::led::ruleDriveReplaced" $ do
  drive_ready <- phaseHandle "drive_ready"

  setPhaseIf drive_ready is_drive_ready $ \(uid, sd) -> do
    todo uid
    sendReadyLed sd
    done uid

  start drive_ready ()
  where
    sendReadyLed storDev = getSDevHost storDev >>= \case
      h : _ -> void $! sendLedUpdate DriveOk h storDev
      _ -> phaseLog "error" $ "No host associated with " ++ show storDev

    is_drive_ready (HAEvent uid msg _) _ _ = case msg of
      DriveReady sd -> return $ Just (uid, sd)

-- | SSPL has started on a node, send all LED statuses we know about.
-- If we don't have a status assigned to a slot, send 'FaultOff' for
-- it anyway.
ruleSsplStarted :: Definitions LoopState ()
ruleSsplStarted = defineSimpleTask "castor::drive::led::ruleSsplStarted" $ \(nid, artc) ->
  let module_name = actuatorResponseMessageActuator_response_typeThread_controllerModule_name artc
      thread_response = actuatorResponseMessageActuator_response_typeThread_controllerThread_response artc
  in case (T.toUpper module_name, T.toUpper thread_response) of
      ("THREADCONTROLLER", "SSPL-LL SERVICE HAS STARTED SUCCESSFULLY") -> do
        rg <- getLocalGraph
        let l = [ (sd, listToMaybe $ G.connectedTo sd Has rg)
                | host :: Host <- G.connectedTo Cluster Has rg
                , sd :: StorageDevice <- G.connectedTo host Has rg
                ]
        for_ l $ \(sdev, mled) -> do
          let ledSt = fromMaybe FaultOff mled
          mserial <- listToMaybe <$> lookupStorageDeviceSerial sdev
          for_ mserial $ \sn ->
            void $ sendNodeCmd nid Nothing (DriveLed (T.pack sn) ledSt)
      _ -> return ()
