-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Rules specific to drives in RAID arrays.
--

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
import HA.RecoveryCoordinator.Actions.Hardware
  ( getSDevNode
  , lookupStorageDevicePaths
  , lookupStorageDeviceRaidDevice
  )
import HA.RecoveryCoordinator.Actions.Mero.Conf (nodeToM0Node)
import HA.RecoveryCoordinator.Castor.Drive.Events
  ( RaidUpdate(..)
  , ResetAttempt(..)
  , ResetFailure(..)
  , ResetSuccess(..)
  , DriveReady(..)
  )
import HA.RecoveryCoordinator.Events.Mero (stateSet)
import HA.RecoveryCoordinator.Rules.Mero.Conf (applyStateChanges)
import HA.Resources (Node(..))
import qualified HA.Resources.Mero as M0
import HA.Services.SSPL.CEP
  ( sendInterestingEvent
  , sendNodeCmd
  )
import HA.Services.SSPL.LL.Resources
  ( NodeCmd(..)
  , RaidCmd(..)
  , InterestingEventMessage(..)
  )
import HA.Services.SSPL.IEM

import Control.Distributed.Process (liftIO)
import Control.Monad (void)

import Data.Foldable (for_)
import Data.Maybe (listToMaybe)
import Data.Monoid ((<>))
import qualified Data.Text as T
import Data.UUID.V4 (nextRandom)

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
  end <- phaseHandle "end"

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
            switch [reset_success, reset_failure, timeout 120 end]
          else do
            phaseLog "error" $ "Failed to send ResetAttept command via SSPL."
            continue end
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
      -- At this point we are done
      continue end

  setPhaseIf reset_failure
    ( \(HAEvent eid (ResetFailure x) _) _ l -> case l of
        Just (node,_,y,rdev,path) | x == y -> return $ Just (eid, node, rdev, path)
        _ -> return Nothing
    ) $ \(eid, node, rdev, path) -> do
      todo eid
      -- Mark the node as being failed.
      rg <- getLocalGraph
      for_ (nodeToM0Node node rg) $ \n -> do
        phaseLog "info" "Marking node as failed due to failed RAID reset."
        applyStateChanges [ stateSet n M0.NSFailedUnrecoverable ]
      sendInterestingEvent . InterestingEventMessage $ logRaidArrayFailure
        ( "{'raidDevice':" <> rdev <> ", 'failedDevice': " <> path <> "}")
      done eid
      continue end

  directly end stop

  startFork raid_update Nothing

-- | RAID device replacement
--   This is triggered on drive being declared ready for use to the system.
--   We verify that the drive is in fact a metadata drive and, if so, attempt
--   to add it into the RAID array.
replacement :: Definitions LoopState ()
replacement = define "castor::drive::raid::replaced" $ do

  drive_replaced <- phaseHandle "drive_replaced"
  end <- phaseHandle "end"

  setPhase drive_replaced $ \(HAEvent eid (DriveReady sdev) _) -> do
    todo eid
    phaseLog "device" $ show sdev
    -- Check if this is a metadata drive
    lookupStorageDeviceRaidDevice sdev >>= \case
      [] -> do
        done eid -- Not part of a raid array
        continue end
      (rd:[]) -> do
        -- Add drive back into array
        mnode <- listToMaybe <$> getSDevNode sdev
        mpath <- listToMaybe <$> lookupStorageDevicePaths sdev
        case (,) <$> mnode <*> mpath of
          Just ((Node nid), path) ->
            void $ sendNodeCmd nid Nothing (NodeRaidCmd (T.pack rd) (RaidAdd $ T.pack path))
          Nothing -> do
            phaseLog "warning" "Cannot find node or path for device."
            phaseLog "node" $ show mnode
            phaseLog "path" $ show mpath
        done eid
        -- At this point we are done
        continue end
      xs -> do
        phaseLog "warning" "Device is part of multiple RAID arrays"
        phaseLog "raidDevices" $ show xs
        done eid
        continue end

  directly end stop

  startFork drive_replaced ()
