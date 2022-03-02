{-# LANGUAGE DataKinds    #-}
{-# LANGUAGE GADTs        #-}
{-# LANGUAGE LambdaCase   #-}
{-# LANGUAGE Rank2Types   #-}
{-# LANGUAGE ViewPatterns #-}
-- |
-- Module    : HA.RecoveryCoordinator.Castor.Drive.Rules.Failure
-- Copyright : (C) 2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Permanent failure rules for drives.
--
-- This module covers the transition from Transient failures to Permanent ones.
-- Whether to make the transition depends upon other factors, including:
--
-- - Other operations ongoing on the drive (e.g. reset)
-- - Other failures in the system - we do not want to fail more than `K`
--   drives in a given pool, since this will render the system unrecoverable.
-- - Other transient failures in the system - lots of transient failures may
--   indicate an expander reset, for example. In this case we do not want to
--   fail any drives, and instead wait for them to return (or forcibly reset
--   them if they do not).

module HA.RecoveryCoordinator.Castor.Drive.Rules.Failure
  ( rules ) where

import           Control.Lens
import           Control.Monad
import           Data.Foldable (for_)
import           Data.Maybe
import           Data.Monoid ((<>))
import           Data.Proxy (Proxy(..))
import qualified Data.Text as T
import           Data.Vinyl

import           HA.RecoveryCoordinator.Actions.Hardware
import           HA.RecoveryCoordinator.Castor.Drive.Actions
  ( lookupStorageDevice
  , sdevFailureWouldBeDUDly
  )
import           HA.RecoveryCoordinator.Castor.Drive.Events
import qualified HA.RecoveryCoordinator.Hardware.StorageDevice.Actions as StorageDevice
import           HA.RecoveryCoordinator.Mero.Notifications
import           HA.RecoveryCoordinator.Mero.State
import           HA.RecoveryCoordinator.Mero.Transitions (sdevFailTransient)
import           HA.RecoveryCoordinator.Mero.Transitions.Internal
  ( constTransition )
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.ResourceGraph as G
import           HA.Resources (Has(..))
import qualified HA.Resources.Castor as Cas
import           HA.Resources.HalonVars
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           HA.Services.SSPL
import           HA.Services.SSPL.IEM (logFailureOverK)
import           HA.Services.SSPL.LL.CEP
  ( sendInterestingEvent
  , updateDriveManagerWithFailure
  )
import           Network.CEP

-- | Set of all rules related to the disk livetime. It's reexport to be
-- used at the toplevel castor module.
rules :: Definitions RC ()
rules = sequence_
  [ ruleTransientTimeout ]

-- | Send an IEM about 'M0.SDev' failure transition being prevented by
-- maximum allowed failure tolerance.
iemFailureOverTolerance :: M0.SDev -> PhaseM RC l ()
iemFailureOverTolerance sdev =
  sendInterestingEvent . InterestingEventMessage . logFailureOverK $ T.pack
      (" {'failedDevice':" <> show (M0.fid sdev) <> "}")

ruleTransientTimeout :: Definitions RC ()
ruleTransientTimeout = define "castor::drive::failure::transient-timeout" $ do
    transient_msg <- phaseHandle "transient_msg"
    subsequent_state_change <- phaseHandle "subsequent_state_change"
    reset_complete <- phaseHandle "reset_complete"
    check_expander_reset <- phaseHandle "check_expander_reset"
    permanent_failure <- phaseHandle "permanent_failure"
    reset_drive <- phaseHandle "reset_drive"
    finish <- phaseHandle "finish"

    let
      -- Check if a drive is transient
      isTransient (M0.SDSTransient _) = True
      isTransient _ = False

      -- Start running a timeout.
      startTimeout = do
        Just (_, sdev) <- gets Local (^. rlens fldHardware . rfield)
        removed <- isStorageDriveRemoved sdev
        removed_timeout <- getHalonVar _hv_drive_removal_timeout
        powered <- StorageDevice.isPowered sdev
        powered_timeout <- getHalonVar _hv_drive_unpowered_timeout
        resetting <- hasOngoingReset sdev
        fallback_timeout <- getHalonVar _hv_drive_transient_timeout

        let basePhases = [subsequent_state_change]
            additionalPhases =
              if resetting
              then [reset_complete]
              else [timeout timeToWait check_expander_reset]
            timeToWait = minimum $ catMaybes [
                ifMb removed removed_timeout
              , ifMb powered powered_timeout
              , Just fallback_timeout
              ]
            ifMb t a = if t then Just a else Nothing
            phases = basePhases <> additionalPhases

        switch phases

    setPhaseInternalNotification transient_msg
      (\o n -> (not (isTransient o) && isTransient n))
      $ \(uuid, objs) -> forM_ objs $ \(m0sdev, _) -> do
        fork NoBuffer $ do
          todo uuid
          modify Local $ rlens fldUUID . rfield .~ Just uuid
          Log.tagContext Log.SM m0sdev Nothing
          currentState <- M0.getState m0sdev <$> getGraph
          msdev <- lookupStorageDevice m0sdev
          case (msdev, currentState) of
            (Just sdev, s) | isTransient s -> do
              Log.tagContext Log.SM sdev Nothing
              -- Listen for any further notifications on this entity.
              modify Local $ rlens fldHardware . rfield .~ Just (m0sdev, sdev)
              -- Start a timeout
              startTimeout
            (Just sdev, s) -> do
              Log.tagContext Log.SM sdev Nothing
              Log.tagContext Log.SM [("sdev.state", show s)]
                $ Just "New sdev state"
              Log.rcLog' Log.WARN
                $ "Transient notification, but disk no longer transient."
              continue finish
            (Nothing, _) -> do
              Log.rcLog' Log.WARN "Missing sdev for m0sdev."
              continue finish

    -- This phase fires if the device is moved out of TRANSIENT state due to any
    -- other rule. In this case, we abort this rule entirely.
    setPhaseNotified subsequent_state_change
      (\l -> fmap (\hw -> (fst hw, not . isTransient))
                  (l ^. rlens fldHardware . rfield)
      )
      $ \(m0sdev, st) -> do
          currentState <- M0.getState m0sdev <$> getGraph
          case currentState of
            s | isTransient s -> do
              Log.rcLog' Log.WARN
                $ "Subsequent state change, but sdev is still transient."
              startTimeout
            _ -> do
              Log.tagContext Log.Phase [("sdev.state", show st)]
                $ Just "Device has transitioned out of TRANSIENT state."
              continue finish

    setPhaseIf reset_complete
      ( \msg _ l ->
        case (msg, l ^. rlens fldHardware . rfield) of
          (ResetSuccess x, Just (_, sdev)) | sdev == x -> return $ Just msg
          (ResetAborted x, Just (_, sdev)) | sdev == x -> return $ Just msg
          (ResetFailure x, Just (_, sdev)) | sdev == x -> return $ Just msg
          _ -> return Nothing
      )
      $ \case
        ResetSuccess _ -> do
          Log.rcLog' Log.DEBUG "Reset successful; stopping timeout rule."
          continue finish
        ResetAborted _ -> do
          Log.rcLog' Log.DEBUG "Reset aborted; starting timeout."
          startTimeout
        ResetFailure _ -> do
          Log.rcLog' Log.DEBUG "Reset failed; going directly to permanent failure."
          continue permanent_failure

    -- Check whether an expander reset seems likely on this expander.
    --
    -- In the case of an expander reset, we start a second timeout to await
    -- the drive returning; if it does not, we trigger a reset on the drive
    -- and await that.
    directly check_expander_reset $ do
      rg <- getGraph
      Just (_, sdev) <- gets Local (^. rlens fldHardware . rfield)
      expanderResetThreshold <- getHalonVar _hv_expander_reset_threshold
      let failuresInEnclosure =
            [ disk
            | Just encl <- [Cas.slotEnclosure <$> G.connectedTo sdev Has rg]
            , slot <- G.connectedTo encl Has rg :: [Cas.Slot]
            , Just disk <- [G.connectedFrom Has slot rg :: Maybe Cas.StorageDevice]
            , Just m0disk <- [G.connectedFrom M0.At disk rg :: Maybe M0.Disk]
            , isTransient $ M0.getState m0disk rg
            ]

      if length failuresInEnclosure >= expanderResetThreshold
      then Log.withLocalContext' $ do
        for_ failuresInEnclosure $ \fd ->
          Log.tagLocalContext fd (Just "Transient device")
        Log.rcLog Log.DEBUG "Expander reset inferred; not failing device."
        expanderResetTimeout <- getHalonVar _hv_expander_reset_reset_timeout
        Log.rcLog Log.DEBUG $ "Waiting " <> show expanderResetTimeout
                            <> " seconds before resetting drive."
        switch [ subsequent_state_change
               , timeout expanderResetTimeout reset_drive]
      else continue permanent_failure

    -- Attempt to move the drive to a permanent failure.
    -- Whether we actually move to a permanent failure is affected by
    -- whether we have more than K failures in a given pool.
    --
    -- In the case of more than K failures, we have no real choice; we send
    -- an IEM to alert to the situation, but otherwise must simply wait for
    -- a transient drive to magically "start working" again.
    directly permanent_failure $ do
      Just (m0sdev, sdev) <- gets Local (^. rlens fldHardware . rfield)
      dudly <- sdevFailureWouldBeDUDly m0sdev <$> getGraph
      transition <-
        if dudly
        then do
          Log.rcLog' Log.WARN $ "Want to fail drive, but doing so would"
                             <> " bring SNS pool to unusable (DUD) state!"
          iemFailureOverTolerance m0sdev
          pure sdevFailTransient
        else do
          updateDriveManagerWithFailure sdev "HALON-FAILED"
            (Just "MERO-Timeout")
          pure (constTransition M0.SDSFailed)
      void $ applyStateChanges [stateSet m0sdev transition]
      continue finish

    -- If we see an expander reset and drives do not return within
    -- '_hv_expander_reset_reset_timeout', directly try to reset the drive.
    directly reset_drive $ do
      Just (_, sdev) <- gets Local (^. rlens fldHardware . rfield)
      Log.rcLog' Log.DEBUG $ "Timed out waiting for drive to come online; "
                          <> "starting reset."
      promulgateRC $ ResetAttempt sdev
      switch [reset_complete, subsequent_state_change]

    directly finish $ do
      muuid <- gets Local (^. rlens fldUUID . rfield)
      for_ muuid done
      stop

    startFork transient_msg args
  where
    fldHardware = Proxy :: Proxy '("hardware", Maybe (M0.SDev, Cas.StorageDevice))
    args = fldHardware =: Nothing
       <+> fldUUID =: Nothing
