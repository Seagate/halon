{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TypeOperators     #-}
-- |
-- Module    : HA.RecoveryCoordinator.Castor.Drive.Rules.Raid
-- Copyright : (C) 2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Rules specific to drives in RAID arrays.
module HA.RecoveryCoordinator.Castor.Drive.Rules.Raid
  ( rules
    -- * Individual rules exported
  , failed
  , replacement
  ) where

import HA.EventQueue (HAEvent(..))
import HA.RecoveryCoordinator.RC.Actions
import HA.RecoveryCoordinator.RC.Actions.Dispatch
import qualified HA.RecoveryCoordinator.Hardware.StorageDevice.Actions as StorageDevice
import HA.RecoveryCoordinator.Actions.Hardware
  ( getSDevNode
  )
import HA.RecoveryCoordinator.Castor.Drive.Actions
import HA.RecoveryCoordinator.Castor.Drive.Events
  ( RaidUpdate(..)
  , ResetAttempt(..)
  , ResetAttemptResult(..)
  , DriveReady(..)
  , RaidAddToArray(..)
  , RaidAddResult(..)
  )
import HA.RecoveryCoordinator.Job.Actions
import HA.RecoveryCoordinator.Job.Events (JobFinished(..))
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import HA.Resources (Node(..))
import HA.Resources.Castor (StorageDevice)
import HA.Services.SSPL.LL.CEP
  ( sendInterestingEvent
  , sendNodeCmd
  , updateDriveManagerWithFailure
  )
import HA.Services.SSPL.LL.RC.Actions
  ( fldCommandAck
  , mkDispatchAwaitCommandAck
  )
import HA.Services.SSPL.LL.Resources (NodeCmd(..), RaidCmd(..), InterestingEventMessage(..))
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
import Text.Printf (printf)

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

-- | Fail the RAID 'StorageDevice'. As RAID devices don't have mero
-- disks associated with them, this basically resolves to sending
-- "RAID_FAILURE" to the drive manager.
failRaidStorageDevice :: StorageDevice -> PhaseM RC l ()
failRaidStorageDevice sd = updateDriveManagerWithFailure sd "HALON-FAILED" (Just "RAID_FAILURE")

-- | Log info about the state of this operation
logInfo :: forall l. ( '("node", Maybe Node) ∈ l
                     , '("raidInfo", Maybe RaidInfo) ∈ l
                     )
        => PhaseM RC (FieldRec l) ()
logInfo = do
  mnode <- gets Local (^. rlens fldNode . rfield)
  mrinfo <- gets Local (^. rlens fldRaidInfo . rfield)
  Log.rcLog' Log.DEBUG $ "node=" ++ show mnode
  for_ mrinfo $ \rinfo -> do
    Log.rcLog' Log.DEBUG $ concat [ "device=", show (rinfo ^. riRaidDevice)
                                  , " constituent.sdev=", show (rinfo ^. riCompSDev)
                                  , " constituent.path=", show (rinfo ^. riCompPath)
                                  ]


-- | RAID device failure rule.
failed :: Definitions RC ()
failed = define "castor::drive::raid::failed" $ do
    raid_update <- phaseHandle "raid_update"
    remove_done <- phaseHandle "remove_done"
    reset_success <- phaseHandle "reset_success"
    reset_failure <- phaseHandle "reset_failure"
    raid_add_reply <- phaseHandle "raid_add_reply"
    failure <- phaseHandle "failure"
    dispatcher <- mkDispatcher
    end <- phaseHandle "end"
    sspl_notify_done <- mkDispatchAwaitCommandAck dispatcher failure (return ())

    setPhase raid_update $ \(HAEvent eid RaidUpdate{..}) -> do
      let
        go [] = return ()
        go ((sdev, path):xs) = do
          fork CopyNewerBuffer $ do
            Log.rcLog' Log.DEBUG $ "Metadrive drive " ++ show path
                                ++ "failed on " ++ show ruNode ++ "."
            msgUuid <- liftIO $ nextRandom
            modify Local $ rlens fldNode . rfield .~ Just ruNode
            modify Local $ rlens fldRaidInfo . rfield .~
              (Just $ RaidInfo ruRaidDevice sdev path)
            -- Tell SSPL to remove the drive from the array
            sent <- sendNodeCmd [ruNode] (Just msgUuid)
                        (NodeRaidCmd ruRaidDevice (RaidRemove path))
            -- Start the reset operation for this disk
            if sent
            then do
              modify Local $ rlens fldCommandAck . rfield .~ [msgUuid]
              waitFor sspl_notify_done
              onSuccess remove_done
              onTimeout 30 failure
              continue dispatcher
            else do
              Log.rcLog' Log.ERROR
                ("Failed to send ResetAttept command via SSPL." :: String)
          go xs

      todo eid
      go ruFailedComponents
      done eid

    directly remove_done $ do
      Just sdev <- (fmap (^. riCompSDev)) <$> gets Local (^. rlens fldRaidInfo . rfield)
      markRemovedFromRAID sdev
      promulgateRC $ ResetAttempt sdev
      publish $ ResetAttempt sdev
      switch [reset_success, reset_failure]

    setPhaseIf reset_success
      -- TODO: relies on drive reset rule
      ( \msg _ l ->
        case (msg, l ^. rlens fldRaidInfo . rfield) of
          (ResetSuccess x, Just y) | (y ^. riCompSDev) == x -> return $ Just ()
          _ -> return Nothing
      ) $ \() -> do
        logInfo
        Just rinfo <- gets Local (^. rlens fldRaidInfo . rfield)
        l <- startJob $ RaidAddToArray (rinfo ^. riCompSDev)
        modify Local $ rlens fldJob . rfield .~ Just l
        continue raid_add_reply

    setPhaseIf raid_add_reply ourJob $ \(_ :: RaidAddResult) -> continue end

    setPhaseIf reset_failure
      ( \msg _ l ->
        case (msg, l ^. rlens fldRaidInfo . rfield) of
          (ResetFailure x, Just y) | (y ^. riCompSDev) == x -> return $ Just ()
          _ -> return Nothing
      ) $ \() -> do
        logInfo
        Just rinfo <- gets Local (^. rlens fldRaidInfo . rfield)
        -- Send SSPL message requiring the drive to be replaced.
        sendInterestingEvent . InterestingEventMessage $ logRaidArrayFailure
           ( "{ 'raidDevice':" <> (rinfo ^. riRaidDevice)
          <> ", 'failedDevice': " <> (rinfo ^. riCompPath)
          <> "}")
        failRaidStorageDevice (rinfo ^. riCompSDev)
        continue end

    directly failure $ do
      Just rinfo <- gets Local (^. rlens fldRaidInfo . rfield)
      sendInterestingEvent . InterestingEventMessage $ logRaidArrayFailure
         ( "{ 'raidDevice':" <> (rinfo ^. riRaidDevice)
        <> ", 'failedDevice': " <> (rinfo ^. riCompPath)
        <> "}")
      failRaidStorageDevice (rinfo ^. riCompSDev)
      continue end

    directly end stop

    startFork raid_update (args raid_update)
  where
    ourJob (JobFinished lis msg) _ ls =
      let Just l = ls ^. rlens fldJob . rfield
      in if l `elem` lis
         then return Nothing
         else return $ Just msg
    fldJob = Proxy :: Proxy '("listener", Maybe ListenerId)
    args st = fldUUID =: Nothing
          <+> fldNode =: Nothing
          <+> fldRaidInfo =: Nothing
          <+> fldCommandAck =: []
          <+> fldDispatch =: Dispatch [] st Nothing
          <+> fldJob =: Nothing

-- | RAID device replacement
--
-- This is triggered on drive being declared ready for use to the
-- system. We verify that the drive is in fact a metadata drive and,
-- if so, attempt to add it into the RAID array.
replacement :: Definitions RC ()
replacement = define "castor::drive::raid::replaced" $ do
  drive_replaced <- phaseHandle "drive_replaced"
  raid_add_reply <- phaseHandle "raid_add_reply"

  setPhase drive_replaced $ \(HAEvent eid (DriveReady sdev)) -> do
    todo eid
    StorageDevice.raidDevice sdev >>= \case
      -- Not a raid device so just do nothing.
      [] -> done eid
      -- If we have multiple arrays, just try anyway: probably want to
      -- fail the drive either way because something is wrong. If we
      -- don't, everything is fine.
      _ -> do
        l <- startJob $ RaidAddToArray sdev
        modify Local $ rlens fldUUID . rfield .~ Just eid
        modify Local $ rlens fldJob  . rfield .~ Just l
        continue raid_add_reply

  setPhaseIf raid_add_reply ourJob $ \(_ :: RaidAddResult) -> do
    Just uuid <- gets Local (^. rlens fldUUID . rfield)
    done uuid

  startFork drive_replaced args
  where
    ourJob (JobFinished lis msg) _ ls =
      let Just l = ls ^. rlens fldJob . rfield
      in if l `elem` lis
         then return Nothing
         else return $ Just msg
    fldJob = Proxy :: Proxy '("listener", Maybe ListenerId)
    args = fldUUID =: Nothing
       <+> fldJob =: Nothing

jobRaidDeviceAdd :: Job RaidAddToArray RaidAddResult
jobRaidDeviceAdd = Job "castor::drive::raid::add-to-array"

-- | Try to add a device to RAID array.
--
-- Problem: when RAID device fails, we reset it and try to add it back
-- to an array if successful. But resetting device causes it to come
-- back online and we can end up triggering 'replacement' rule which
-- also tries to add the device into an array. We already check if
-- drive has been re-added but it's not good enough as notification
-- can be in transit, resulting in concurrent raid add request. It is
-- also not enough (or not obviously-correct) to simply remove this
-- addition from one of the rules: it is not guaranteed they will both
-- run and they dispatch on different pre-conditions anyway.
--
-- This job simply unifies the "add sdev to RAID array" logic and
-- stops concurrent requests.
ruleRaidDeviceAdd :: Definitions RC ()
ruleRaidDeviceAdd = mkJobRule jobRaidDeviceAdd args $ \(JobHandle _ finish) -> do
  failure <- phaseHandle "failure"
  success <- phaseHandle "success"
  dispatcher <- mkDispatcher
  sspl_notify_done <- mkDispatchAwaitCommandAck dispatcher failure logInfo

  let route (RaidAddToArray sdev) = do
        StorageDevice.raidDevice sdev >>= \case
          [rd] -> do
            removed <- isRemovedFromRAID sdev
            Log.rcLog' Log.DEBUG
              (printf "%s removed from RAID: %s" (show sdev) (show removed) :: String)
            mnode <- listToMaybe <$> getSDevNode sdev
            mpath <- StorageDevice.path sdev
            case (,) <$> mnode <*> mpath of
              Just (node, path) -> do
                modify Local $ rlens fldNode . rfield .~ (Just node)
                modify Local $ rlens fldRaidInfo . rfield .~
                  (Just $ RaidInfo (T.pack rd) sdev (T.pack path))
                cmdUUID <- liftIO $ nextRandom
                sent <- sendNodeCmd [node] (Just cmdUUID)
                         (NodeRaidCmd (T.pack rd) (RaidAdd $ T.pack path))
                if sent
                then do
                  modify Local $ rlens fldCommandAck . rfield .~ [cmdUUID]
                  waitFor sspl_notify_done
                  onSuccess success
                  onTimeout 120 failure
                  return [dispatcher]
                else do
                  Log.rcLog' Log.ERROR ("Cannot send drive add command to SSPL." :: String)
                  return [failure]
              Nothing -> do
                Log.rcLog' Log.WARN ("Cannot find node or path for device." :: String)
                Log.tagContext Log.Phase [ ("node" :: String, show mnode)
                                         , ("path" :: String, show mpath)
                                         ] Nothing
                return [failure]
          [] -> do
            Log.rcLog' Log.WARN $ ("Device not part of a RAID array." :: String)
            return [finish]
          rds -> do
            Log.rcLog' Log.WARN $ "Device part of multiple arrays: " ++ show rds
            return [finish]

  directly success $ do
    Just rinfo <- gets Local (^. rlens fldRaidInfo . rfield)
    Log.rcLog' Log.DEBUG ("Successfully returned RAID array to operation." :: String)
    unmarkRemovedFromRAID (rinfo ^. riCompSDev)
    modify Local $ rlens fldRep . rfield .~ Just (RaidAddOK $ rinfo ^. riCompSDev)
    logInfo
    continue finish

  directly failure $ do
    Just rinfo <- gets Local (^. rlens fldRaidInfo . rfield)
    Log.rcLog' Log.ERROR ("RAID device could not be added." :: String)
    logInfo
    sendInterestingEvent . InterestingEventMessage $ logRaidArrayFailure
       ( "{ 'raidDevice':" <> (rinfo ^. riRaidDevice)
      <> ", 'failedDevice': " <> (rinfo ^. riCompPath)
      <> "}")
    failRaidStorageDevice (rinfo ^. riCompSDev)
    continue finish

  return $! (\req@(RaidAddToArray sd) -> route req <&> \phs ->
                Right (RaidAddFailed sd, phs))
  where
    fldReq = Proxy :: Proxy '("request", Maybe RaidAddToArray)
    fldRep = Proxy :: Proxy '("reply", Maybe RaidAddResult)
    args = fldReq =: Nothing
       <+> fldRep =: Nothing
       <+> fldUUID =: Nothing
       <+> fldNode =: Nothing
       <+> fldRaidInfo =: Nothing
       <+> fldCommandAck =: []
       <+> fldDispatch =: Dispatch [] (error "No success phase set") Nothing

-- | All rules exported by this module.
rules :: Definitions RC ()
rules = sequence_
  [ failed
  , replacement
  , ruleRaidDeviceAdd
  ]
