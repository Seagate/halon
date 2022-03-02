{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module    : HA.RecoveryCoordinator.Castor.Drive.Rules.LedControl
-- Copyright : (C) 2016-2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Central place dealing with LED control for drives.
module HA.RecoveryCoordinator.Castor.Drive.Rules.LedControl (rules) where

import           Control.Monad (void)
import           Data.Foldable (for_)
import           Data.Maybe (fromMaybe, mapMaybe, maybeToList)
import qualified Data.Text as T
import           HA.EventQueue.Types (HAEvent(..))
import           HA.RecoveryCoordinator.Actions.Hardware (getSDevHost)
import           HA.RecoveryCoordinator.Castor.Drive.Events (DriveReady(..), ResetAttemptResult(..))
import           HA.RecoveryCoordinator.Mero.Notifications (setPhaseInternalNotification)
import           HA.RecoveryCoordinator.RC.Actions.Core
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.ResourceGraph as G
import           HA.Resources (Has(..))
import           HA.Resources.Castor
import qualified HA.Resources.Mero as M0
import           HA.Services.SSPL.LL.CEP (DriveLedUpdate(..), sendLedUpdate, sendNodeCmd)
import           HA.Services.SSPL.LL.Resources (NodeCmd(DriveLed), LedControlState(..))
import           Network.CEP
import           SSPL.Bindings

rules :: Definitions RC ()
rules = sequence_
  [ ruleDriveFailed
  , ruleDriveReplaced
  , ruleSsplStarted
  ]

-- | A drive has become failed, set LED.
ruleDriveFailed :: Definitions RC ()
ruleDriveFailed = define "castor::drive::led::ruleDriveFailed" $ do

  rule_init <- phaseHandle "rule_init"
  mero_drives_failed <- phaseHandle "mero_drives_failed"
  raid_drive_failed <- phaseHandle "raid_drive_failed"

  directly rule_init $ switch [mero_drives_failed, raid_drive_failed]

  -- Drives with SDev (mero drives) have transitioned into a failing
  -- state, switch LED on.
  setPhaseInternalNotification mero_drives_failed freshly_failed $ \(eid, sds) -> do
    todo eid
    rg <- getGraph
    let storDevs = [ storD | sd <- (map fst sds :: [M0.SDev])
                           , slot@Slot{} <- maybeToList $ G.connectedTo sd M0.At rg
                           , storD <- maybeToList $ G.connectedFrom Has slot rg ]
    for_ storDevs $ \sd -> sendFailedLed sd
    done eid

  setPhaseIf raid_drive_failed is_raid_drive sendFailedLed

  startFork rule_init ()
  where
    sendFailedLed storDev = getSDevHost storDev >>= \case
      h : _ -> void $! sendLedUpdate DrivePermanentlyFailed h storDev
      _ -> Log.rcLog' Log.WARN $ "No host associated with " ++ show storDev

    is_raid_drive msg ls _ = case msg of
      ResetFailure sd -> do
        let extractRaid (DIRaidDevice _) = Just ()
            extractRaid _ = Nothing
        case mapMaybe extractRaid $ G.connectedTo sd Has (lsGraph ls) of
          [] -> return $ Nothing
          _ -> return $ Just sd
      _ -> return Nothing

    freshly_failed o n = not (isFailedState o) && isFailedState n

    isFailedState :: M0.SDevState -> Bool
    isFailedState M0.SDSFailed      = True
    isFailedState M0.SDSRepairing   = True
    isFailedState M0.SDSRepaired    = True
    isFailedState M0.SDSRebalancing = True
    isFailedState _                 = False

-- | A drive has been replaced and is ready, unset LED.
ruleDriveReplaced :: Definitions RC ()
ruleDriveReplaced = define "castor::drive::led::ruleDriveReplaced" $ do
  drive_ready <- phaseHandle "drive_ready"

  setPhaseIf drive_ready is_drive_ready $ \(uid, sd) -> do
    todo uid
    sendReadyLed sd
    done uid

  start drive_ready ()
  where
    sendReadyLed storDev = getSDevHost storDev >>= \case
      h:_ -> void $! sendLedUpdate DriveOk h storDev
      _ -> Log.rcLog' Log.ERROR $ "No host associated with " ++ show storDev

    is_drive_ready (HAEvent uid msg) _ _ = case msg of
      DriveReady sd -> return $ Just (uid, sd)

-- | SSPL has started on a node, send all LED statuses we know about.
-- If we don't have a status assigned to a slot, send 'FaultOff' for
-- it anyway.
ruleSsplStarted :: Definitions RC ()
ruleSsplStarted = defineSimpleTask "castor::drive::led::ruleSsplStarted" $ \(nid, artc) ->
  let module_name = actuatorResponseMessageActuator_response_typeThread_controllerModule_name artc
      thread_response = actuatorResponseMessageActuator_response_typeThread_controllerThread_response artc
  in case (T.toUpper module_name, T.toUpper thread_response) of
       ("THREADCONTROLLER", "SSPL-LL SERVICE HAS STARTED SUCCESSFULLY") -> do
         rg <- getGraph
         let l = [ (sd, G.connectedTo slot Has rg)
                 | site :: M0.Site <- G.connectedTo (M0.getM0Root rg) M0.IsParentOf rg
                 , rack :: M0.Rack <- G.connectedTo site M0.IsParentOf rg
                 , m0enc :: M0.Enclosure <- G.connectedTo rack M0.IsParentOf rg
                 , enc :: Enclosure <- maybeToList $ G.connectedTo m0enc M0.At rg
                 , slot :: Slot <- G.connectedTo enc Has rg
                 , sd :: StorageDevice <- maybeToList $ G.connectedFrom Has slot rg
                 ]
         for_ l $ \(StorageDevice sn, mled) -> do
           let ledSt = fromMaybe FaultOff mled
           void $ sendNodeCmd nid Nothing (DriveLed (T.pack sn) ledSt)
       _ -> return ()
