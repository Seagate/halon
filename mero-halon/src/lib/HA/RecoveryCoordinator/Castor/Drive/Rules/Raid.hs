-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Rules specific to drives in RAID arrays.
--

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
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
import Control.Monad (void)

import Data.Maybe (listToMaybe)
import Data.Monoid ((<>))
import Data.Proxy
import qualified Data.Text as T
import Data.UUID.V4 (nextRandom)
import Data.Vinyl

import Network.CEP

-- | All rules exported by this module.
rules :: Definitions LoopState ()
rules = sequence_
  [ failed
  , replacement
  ]

-- | RAID device failure rule.
failed :: Definitions LoopState ()
failed = define "castor::drive::raid::failed" $ do

  raid_update <- phaseHandle "raid_update"
  reset_success <- phaseHandle "reset_success"
  reset_failure <- phaseHandle "reset_failure"
  reset_timeout <- phaseHandle "reset_timeout"

  setPhase raid_update $ \(HAEvent eid (RaidUpdate{..}) _) -> do
    let
      (Node nid) = ruNode
      go [] = return ()
      go ((sdev, path, _sn):xs) = do
        fork CopyNewerBuffer $ do
          phaseLog "action" $ "Metadrive drive " ++ show path
                            ++ "failed on " ++ show nid ++ "."
          msgUuid <- liftIO $ nextRandom
          put Local $ Just (ruNode, msgUuid, sdev, ruRaidDevice, path)
          -- Tell SSPL to remove the drive from the array
          removed <- sendNodeCmd nid (Just msgUuid)
                      (NodeRaidCmd ruRaidDevice (RaidRemove path))
          -- Start the reset operation for this disk
          if removed
          then do
            promulgateRC $ ResetAttempt sdev
            switch [reset_success, reset_failure, timeout 120 reset_timeout]
          else do
            phaseLog "error" $ "Failed to send ResetAttept command via SSPL."
        go xs

    todo eid
    go ruFailedComponents
    done eid

  setPhaseIf reset_success
    -- TODO: relies on drive reset rule; TODO: nicer local state
    ( \(HAEvent eid (ResetSuccess x) _) _ l -> case l of
        Just (_,_,y,_,_) | x == y -> return $ Just eid
        _ -> return Nothing
    ) $ \eid -> do
      todo eid
      Just (Node nid, _, _, device, path) <- get Local
      -- Add drive back into array
      void $ sendNodeCmd nid Nothing (NodeRaidCmd device (RaidAdd path))
      done eid

  setPhaseIf reset_failure
    ( \(HAEvent eid (ResetFailure x) _) _ l -> case l of
        Just (node,_,y,rdev,path) | x == y -> return $ Just (eid, node, y, rdev, path)
        _ -> return Nothing
    ) $ \(eid, _, sdev, rdev, path) -> do
      todo eid
      -- Send SSPL message requiring the drive to be replaced.
      sendInterestingEvent . InterestingEventMessage $ logRaidArrayFailure
        ( "{'raidDevice':" <> rdev <> ", 'failedDevice': " <> path <> "}")
      updateDriveManagerWithFailure sdev "HALON-FAILED" (Just "RAID_FAILURE")
      done eid

  -- We should not generally hit this phase, since the reset job *should*
  -- return.
  directly reset_timeout $ do
    Just (_, _, sdev, rdev, path) <- get Local
    sendInterestingEvent . InterestingEventMessage $ logRaidArrayFailure
      ( "{'raidDevice':" <> rdev <> ", 'failedDevice': " <> path <> "}")
    updateDriveManagerWithFailure sdev "HALON-FAILED" (Just "RAID_FAILURE")

  startFork raid_update Nothing

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
    sspl_notify_done <- mkDispatchAwaitCommandAck dispatcher failure (return ())
    tidyup <- phaseHandle "tidyup"

    setPhase drive_replaced $ \(HAEvent eid (DriveReady sdev) _) -> do
      todo eid
      phaseLog "device" $ show sdev
      -- Check if this is a metadata drive
      lookupStorageDeviceRaidDevice sdev >>= \case
        [] -> do
          done eid -- Not part of a raid array
        (rd:[]) -> do
          -- Add drive back into array
          mnode <- listToMaybe <$> getSDevNode sdev
          mpath <- listToMaybe <$> lookupStorageDevicePaths sdev
          case (,) <$> mnode <*> mpath of
            Just (node@(Node nid), path) -> do
              modify Local $ rlens fldNode . rfield .~ (Just node)
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
      Just node <- gets Local (^. rlens fldNode . rfield)
      phaseLog "info" $ "RAID device added successfully."
      phaseLog "node" $ show node
      continue tidyup

    directly failure $ do
      Just node <- gets Local (^. rlens fldNode . rfield)
      phaseLog "error" $ "RAID device could not be added."
      phaseLog "node" $ show node
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
    fldNode :: Proxy '("node", Maybe Node)
    fldNode = Proxy
    args st = fldUUID =: Nothing
          <+> fldNode =: Nothing
          <+> fldCommandAck =: []
          <+> fldDispatch =: Dispatch [] st Nothing
