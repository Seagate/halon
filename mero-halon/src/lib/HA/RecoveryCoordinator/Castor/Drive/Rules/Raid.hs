-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Rules specific to drives in RAID arrays.
--

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE RecordWildCards   #-}
module HA.RecoveryCoordinator.Castor.Drive.Rules.Raid
  ( rules
    -- * Individual rules exported
  , failed
  , replacement
  ) where

import HA.EventQueue.Types (HAEvent(..))
import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Dispatch
import HA.RecoveryCoordinator.Actions.Hardware
  ( getSDevNode
  , lookupStorageDevicePaths
  , lookupStorageDeviceRaidDevice
  )
import HA.RecoveryCoordinator.Castor.Drive.Events
  ( RaidUpdate(..)
  , ResetAttempt(..)
  , ResetFailure(..)
  , ResetSuccess(..)
  , DriveReady(..)
  )
import HA.Resources (Node(..))
import HA.Resources.Castor (StorageDevice)
import HA.Services.SSPL.CEP
  ( sendInterestingEvent
  , sendNodeCmd
  , updateDriveManagerWithFailure
  )
import HA.Services.SSPL.LL.RC.Actions
  ( fldCommandAck
  , mkDispatchAwaitCommandAck
  )
import HA.Services.SSPL.LL.Resources
  ( NodeCmd(..)
  , RaidCmd(..)
  , InterestingEventMessage(..)
  )
import HA.Services.SSPL.IEM

import Control.Distributed.Process (liftIO)
import Control.Lens

import Data.Foldable (for_)
import Data.Maybe (listToMaybe)
import Data.Monoid ((<>))
import Data.Proxy
import qualified Data.Text as T
import Data.UUID.V4 (nextRandom)
import Data.Vinyl

import Network.CEP

fldNode :: Proxy '("node", Maybe Node)
fldNode = Proxy

data RaidInfo = RaidInfo {
    _riRaidDevice :: T.Text
  , _riCompSDev :: StorageDevice
  , _riCompPath :: T.Text
  }
makeLenses ''RaidInfo

fldRaidInfo :: Proxy '("raidInfo", Maybe RaidInfo)
fldRaidInfo = Proxy

-- | Log info about the state of this operation
logInfo :: forall a l. ( '("node", Maybe Node) ∈ l
                       , '("raidInfo", Maybe RaidInfo) ∈ l
                       )
        => PhaseM a (FieldRec l) ()
logInfo = do
  node <- gets Local (^. rlens fldNode . rfield)
  mrinfo <- gets Local (^. rlens fldRaidInfo . rfield)
  phaseLog "node" $ show node
  for_ mrinfo $ \rinfo -> do
    phaseLog "raid.device" $ show (rinfo ^. riRaidDevice)
    phaseLog "raid.consituent.sdev" $ show (rinfo ^. riCompSDev)
    phaseLog "raid.consituent.path" $ show (rinfo ^. riCompPath)

-- | RAID device failure rule.
failed :: Definitions LoopState ()
failed = define "castor::drive::raid::failed" $ do
    raid_update <- phaseHandle "raid_update"
    remove_done <- phaseHandle "remove_done"
    reset_success <- phaseHandle "reset_success"
    reset_failure <- phaseHandle "reset_failure"
    add_success <- phaseHandle "add_success"
    failure <- phaseHandle "failure"
    dispatcher <- mkDispatcher
    sspl_notify_done <- mkDispatchAwaitCommandAck dispatcher failure (return ())

    setPhase raid_update $ \(HAEvent eid (RaidUpdate{..}) _) -> do
      let
        (Node nid) = ruNode
        go [] = return ()
        go ((sdev, path, _sn):xs) = do
          fork CopyNewerBuffer $ do
            phaseLog "action" $ "Metadrive drive " ++ show path
                              ++ "failed on " ++ show nid ++ "."
            msgUuid <- liftIO $ nextRandom
            modify Local $ rlens fldNode . rfield .~ (Just ruNode)
            modify Local $ rlens fldRaidInfo . rfield .~
              (Just $ RaidInfo ruRaidDevice sdev path)
            -- Tell SSPL to remove the drive from the array
            removed <- sendNodeCmd nid (Just msgUuid)
                        (NodeRaidCmd ruRaidDevice (RaidRemove path))
            -- Start the reset operation for this disk
            if removed
            then do
              modify Local $ rlens fldCommandAck . rfield .~ [msgUuid]
              waitFor sspl_notify_done
              onSuccess remove_done
              onTimeout 30 failure
              continue dispatcher
            else do
              phaseLog "error" $ "Failed to send ResetAttept command via SSPL."
          go xs

      todo eid
      go ruFailedComponents
      done eid

    directly remove_done $ do
      Just sdev <- (fmap (^. riCompSDev)) <$> gets Local (^. rlens fldRaidInfo . rfield)
      promulgateRC $ ResetAttempt sdev
      switch [reset_success, reset_failure]

    setPhaseIf reset_success
      -- TODO: relies on drive reset rule
      ( \(HAEvent eid (ResetSuccess x) _) _ l ->
        case (l ^. rlens fldRaidInfo . rfield) of
          Just y | (y ^. riCompSDev) == x -> return $ Just eid
          _ -> return Nothing
      ) $ \eid -> do
        todo eid
        logInfo
        Just rinfo <- gets Local (^. rlens fldRaidInfo . rfield)
        Just (Node nid) <- gets Local (^. rlens fldNode . rfield)
        -- Add drive back into array
        msgUUID <- liftIO $ nextRandom
        sent <- sendNodeCmd nid Nothing (NodeRaidCmd (rinfo ^. riRaidDevice)
                                        (RaidAdd (rinfo ^. riCompPath)))
        done eid
        if sent
        then do
          modify Local $ rlens fldCommandAck . rfield .~ [msgUUID]
          waitFor sspl_notify_done
          onSuccess add_success
          onTimeout 30 failure
          continue dispatcher
        else do
          phaseLog "error" "Cannot send drive add command to SSPL."

    directly add_success $ do
      phaseLog "info" "Successfully returned RAID array to operation."
      logInfo

    setPhaseIf reset_failure
      ( \(HAEvent eid (ResetFailure x) _) _ l ->
        case (l ^. rlens fldRaidInfo . rfield) of
          Just y | (y ^. riCompSDev) == x -> return $ Just eid
          _ -> return Nothing
      ) $ \eid -> do
        todo eid
        logInfo
        Just rinfo <- gets Local (^. rlens fldRaidInfo . rfield)
        -- Send SSPL message requiring the drive to be replaced.
        sendInterestingEvent . InterestingEventMessage $ logRaidArrayFailure
           ( "{ 'raidDevice':" <> (rinfo ^. riRaidDevice)
          <> ", 'failedDevice': " <> (rinfo ^. riCompPath)
          <> "}")
        updateDriveManagerWithFailure (rinfo ^. riCompSDev)
          "HALON-FAILED" (Just "RAID_FAILURE")
        done eid

    directly failure $ do
      Just rinfo <- gets Local (^. rlens fldRaidInfo . rfield)
      sendInterestingEvent . InterestingEventMessage $ logRaidArrayFailure
         ( "{ 'raidDevice':" <> (rinfo ^. riRaidDevice)
        <> ", 'failedDevice': " <> (rinfo ^. riCompPath)
        <> "}")
      updateDriveManagerWithFailure (rinfo ^. riCompSDev)
        "HALON-FAILED" (Just "RAID_FAILURE")

    startFork raid_update (args raid_update)
  where
    args st = fldUUID =: Nothing
          <+> fldNode =: Nothing
          <+> fldRaidInfo =: Nothing
          <+> fldCommandAck =: []
          <+> fldDispatch =: Dispatch [] st Nothing

-- | RAID device replacement
--   This is triggered on drive being declared ready for use to the system.
--   We verify that the drive is in fact a metadata drive and, if so, attempt
--   to add it into the RAID array.
replacement :: Definitions LoopState ()
replacement = define "castor::drive::raid::replaced" $ do

    drive_replaced <- phaseHandle "drive_replaced"
    failure <- phaseHandle "failure"
    success <- phaseHandle "success"
    dispatcher <- mkDispatcher
    sspl_notify_done <- mkDispatchAwaitCommandAck dispatcher failure logInfo
    tidyup <- phaseHandle "tidyup"

    setPhase drive_replaced $ \(HAEvent eid (DriveReady sdev) _) -> do
      todo eid
      -- Check if this is a metadata drive
      lookupStorageDeviceRaidDevice sdev >>= \case
        [] -> do
          done eid -- Not part of a raid array
        (rd:[]) -> do
          phaseLog "device" $ show sdev
          modify Local $ rlens fldUUID . rfield .~ (Just eid)
          -- Add drive back into array
          mnode <- listToMaybe <$> getSDevNode sdev
          mpath <- listToMaybe <$> lookupStorageDevicePaths sdev
          case (,) <$> mnode <*> mpath of
            Just (node@(Node nid), path) -> do
              modify Local $ rlens fldNode . rfield .~ (Just node)
              modify Local $ rlens fldRaidInfo . rfield .~
                (Just $ RaidInfo (T.pack rd) sdev (T.pack path))
              cmdUUID <- liftIO $ nextRandom
              sent <- sendNodeCmd nid Nothing (NodeRaidCmd (T.pack rd) (RaidAdd $ T.pack path))
              if sent
              then do
                modify Local $ rlens fldCommandAck . rfield .~ [cmdUUID]
                waitFor sspl_notify_done
                onSuccess success
                onTimeout 30 failure
                continue dispatcher
              else do
                phaseLog "error" "Cannot send drive add command to SSPL."
                continue failure
            Nothing -> do
              phaseLog "warning" "Cannot find node or path for device."
              phaseLog "node" $ show mnode
              phaseLog "path" $ show mpath
              continue failure
        xs -> do
          phaseLog "warning" "Device is part of multiple RAID arrays"
          phaseLog "raidDevices" $ show xs
          continue failure

    directly success $ do
      phaseLog "info" $ "RAID device added successfully."
      logInfo
      continue tidyup

    directly failure $ do
      phaseLog "error" $ "RAID device could not be added."
      logInfo
      continue tidyup

    -- Tidy up phase, runs after either a successful or unsuccessful
    -- completion and:
    -- - Removes the raid reassembly marker on the host
    -- - Acknowledges the message
    directly tidyup $ do
      Just uuid <- gets Local (^. rlens fldUUID . rfield)
      done uuid

    startFork drive_replaced (args drive_replaced)
  where
    args st = fldUUID =: Nothing
          <+> fldNode =: Nothing
          <+> fldRaidInfo =: Nothing
          <+> fldCommandAck =: []
          <+> fldDispatch =: Dispatch [] st Nothing

-- | All rules exported by this module.
rules :: Definitions LoopState ()
rules = sequence_
  [ failed
  , replacement
  ]
