{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
-- |
-- Copyright : (C) 2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
module  HA.RecoveryCoordinator.Castor.Drive.Actions
  ( module HA.RecoveryCoordinator.Castor.Drive.Actions.Graph
    -- * Attach/detach
  , mkAttachDisk
  , mkDetachDisk
    -- * RAID Drive functions
  , isRemovedFromRAID
  , markRemovedFromRAID
  , unmarkRemovedFromRAID
    -- * Exported for test
  , SpielDeviceAttached(..)
  , SpielDeviceDetached(..)
  -- * SDev state transitions
  , sdevFailureWouldBeDUDly
  , updateStorageDevicePresence
  , updateStorageDeviceStatus
  ) where

import           Data.Binary (Binary)
import           Data.Char (toUpper)
import           Data.Function (fix)
import           Data.Functor (void)
import           Data.List (nub)
import           Data.Typeable
import           Data.UUID (UUID)
import           Data.Word (Word32)
import           GHC.Generics

import           HA.RecoveryCoordinator.Castor.Drive.Actions.Graph
import           HA.RecoveryCoordinator.Castor.Drive.Events
import qualified HA.RecoveryCoordinator.Hardware.StorageDevice.Actions as StorageDevice
import           HA.RecoveryCoordinator.Mero.Actions.Conf (theProfile)
import           HA.RecoveryCoordinator.Mero.Actions.Core
import           HA.RecoveryCoordinator.Mero.Actions.Spiel
import           HA.RecoveryCoordinator.RC.Actions.Core
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.ResourceGraph as G
import qualified HA.Resources as R (Node)
import           HA.Resources.Castor
  ( StorageDevice
  , StorageDeviceAttr(SDRemovedFromRAID)
  )
import qualified HA.Resources.Castor as Cas
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0

import           Mero.ConfC (PDClustAttr(_pa_K))
import qualified Mero.Spiel as Spiel

import           Control.Distributed.Process hiding (try)
import           Control.Monad.Catch (SomeException, try, fromException)
import           System.IO.Error

import           Network.CEP

-- | Notification that happens in case if new spiel device is attached.
data SpielDeviceAttached = SpielDeviceAttached M0.SDev (Either String ())
  deriving (Eq, Show, Typeable, Generic)
instance Binary SpielDeviceAttached

-- | Notification that happens in case if new spiel device is detached.
data SpielDeviceDetached = SpielDeviceDetached M0.SDev (Either String ())
  deriving (Eq, Show, Typeable, Generic)
instance Binary SpielDeviceDetached

-- | Handle result of attach or detach action.
handleSNSReply :: Either SomeException () -> Either String ()
handleSNSReply (Right x) = Right x
handleSNSReply (Left se) = case fromException se of
  Just t | isAlreadyExistsError t -> Right () -- Drive was already attached - fine
         | isAlreadyInUseError  t -> Right () -- Drive was already attached - fine
  _                               -> Left (show se)


-- | Create all code that allow to ask mero (IO services) to attach certain disk.
--
-- In case if 'M0.Disk' for the 'M0.SDev' is not found - failure handler is called
-- directly.
--
-- In case if there was an exception during call - failure handler is called.
--
-- In case if everything was successful - call normal handler
--
-- @
-- (phase, attachDisk) <- mkAttachDisk
--   (\m0sdev reson -> logReason reason >> continue failureCase)
--   $ \m0dev -> ...
--
--
-- directly $ do
--   attachDisk m0sdev
-- @
mkAttachDisk ::
      (l -> PhaseM RC l (Maybe M0.SDev))
   -> (M0.SDev -> String -> PhaseM RC l ()) -- ^ Action in case of failure
   -> (M0.SDev -> PhaseM RC l ())           -- ^ Action in case of success
   -> RuleM RC l (Jump PhaseHandle, M0.SDev -> PhaseM RC l ())
mkAttachDisk getter onFailure onSuccess = do
  ph <- phaseHandle "Disk was attached."

  setPhase ph $ \(SpielDeviceAttached sdev eresult) -> do
    mdev0 <- getter =<< get Local
    case mdev0 of
      Nothing -> onFailure sdev "Drive accidentaly lost."
      Just sdev0
        | sdev0 == sdev ->
              either (onFailure sdev) (const $ onSuccess sdev) eresult
        | otherwise -> continue ph

  return (ph, \sdev -> do
    Log.actLog "Attaching disk" [ ("disk.fid", show $ M0.fid sdev) ]
    mdisk <- lookupSDevDisk sdev
    unlift <- mkUnliftProcess
    next <- liftProcess $ do
      rc <- getSelfPid
      return $ usend rc . SpielDeviceAttached sdev . handleSNSReply
    mprof <- theProfile  -- XXX-MULTIPOOLS
    case mdisk of
      Just d ->
        void $ withSpielIO $
          withRConfIO mprof $ try (Spiel.deviceAttach (M0.fid d)) >>= unlift . next
      Nothing -> do
        Log.rcLog' Log.WARN $ "Disk not found for " ++ M0.showFid sdev ++ ", ignoring."
        onFailure sdev "no such disk")

-- | Create all code that allow to ask mero (IO services) to detach certain disk.
--
--
-- In case if 'M0.Disk' for the 'M0.SDev' is not found - failure handler is called
-- directly.
--
-- In case if there was an exception during call - failure handler is called.
--
-- In case if everything was successful - call normal handler
--
-- @
-- (phase, attachDisk) <- mkAttachDisk
--   (\m0sdev reson -> logReason reason >> continue failureCase)
--   $ \m0dev -> ...
--
--
-- directly $ do
--   attachDisk m0sdev
-- @
--
-- XXX REFACTORME: Code duplication! 'mkAttachDisk' and 'mkDetachDisk'
-- are quite similar.
mkDetachDisk ::
      (l -> PhaseM RC l (Maybe M0.SDev))
   -> (M0.SDev -> String -> PhaseM RC l ())
   -> (M0.SDev -> PhaseM RC l ())
   -> RuleM RC l (Jump PhaseHandle, M0.SDev -> PhaseM RC l ())
mkDetachDisk getter onFailure onSuccess = do
  ph <- phaseHandle "Disk was detached."

  setPhase ph $ \(SpielDeviceDetached sdev eresult) -> do
    mdev0 <- getter =<< get Local
    case mdev0 of
      Nothing -> onFailure sdev "Drive accidentaly lost."
      Just sdev0
        | sdev0 == sdev ->
              either (onFailure sdev) (const $ onSuccess sdev) eresult
        | otherwise -> continue ph

  return (ph, \sdev -> do
    Log.actLog "Detaching disk" [ ("disk.fid", show $ M0.fid sdev) ]
    mdisk <- lookupSDevDisk sdev
    unlift <- mkUnliftProcess
    next <- liftProcess $ do
      rc <- getSelfPid
      return $ usend rc . SpielDeviceDetached sdev . handleSNSReply
    mprof <- theProfile
    case mdisk of
      Just d ->
        void $ withSpielIO $
          withRConfIO mprof $ try (Spiel.deviceDetach (M0.fid d)) >>= unlift . next
      Nothing -> do
        Log.rcLog' Log.WARN $ "Disk not found for " ++ M0.showFid sdev ++ ", ignoring."
        onFailure sdev "no such disk")

-- | Mark that a device has been removed from the RAID array of which it
--   is part.
markRemovedFromRAID :: StorageDevice -> PhaseM RC l ()
markRemovedFromRAID sdev = StorageDevice.setAttr sdev SDRemovedFromRAID

-- | Remove the marker indicating that a device has been removed from the RAID
--   array of which it is part.
unmarkRemovedFromRAID :: StorageDevice -> PhaseM RC l ()
unmarkRemovedFromRAID sdev = StorageDevice.unsetAttr sdev SDRemovedFromRAID

-- | Check whether a device has been removed from its RAID array.
isRemovedFromRAID :: StorageDevice -> PhaseM RC l Bool
isRemovedFromRAID = fmap (not . null) . StorageDevice.findAttrs go
  where
    go SDRemovedFromRAID = True
    go _ = False

-- | Will failing the @sdev@ render any of its pools DUD?
--
-- (A pool is DUD iff there exists a failure domain level L such that
-- the number of failed devices at L exceeds tolerance of L.)
--
-- TODO: Think about this a bit more. If we're updating a lot of
-- drives at once, it's highly inefficient to run all this on every
-- update.
sdevFailureWouldBeDUDly :: M0.SDev -> G.Graph -> Bool
sdevFailureWouldBeDUDly sdev rg =
    -- It's only a new failure if we're not in a failed state already.
    -- For example we may be moving from REPAIRING to FAILED which
    -- doesn't change the number of failures.
    isUsable sdev &&
        any (\pv -> length (unusableDrives pv) >= fromIntegral (getK pv))
            actualSnsPvers
  where
    isUsable :: M0.SDev -> Bool
    isUsable d = let st = M0.getState d rg
                 in M0.toConfObjState d st `elem` [ M0.M0_NC_UNKNOWN
                                                  , M0.M0_NC_ONLINE
                                                  , M0.M0_NC_TRANSIENT
                                                  ]

    connectedToList a r g = G.asUnbounded $ G.connectedTo a r g
    connectedFromList r b g = G.asUnbounded $ G.connectedFrom r b g

    -- Actual pool versions of the SNS pools which 'sdev' belongs to.
    --
    -- An SNS pool is guaranteed to have one and only one actual
    -- (aka base) pool version; see createSNSPool.
    actualSnsPvers :: [M0.PVer]
    actualSnsPvers = nub
      [ pver
      | disk :: M0.Disk <- connectedToList sdev M0.IsOnHardware rg
      , diskv :: M0.DiskV <- G.connectedTo disk M0.IsRealOf rg
      , ctrlv :: M0.ControllerV <- connectedFromList M0.IsParentOf diskv rg
      , enclv :: M0.EnclosureV <- connectedFromList M0.IsParentOf ctrlv rg
      , rackv :: M0.RackV <- connectedFromList M0.IsParentOf enclv rg
      , sitev :: M0.SiteV <- connectedFromList M0.IsParentOf rackv rg
      , pver :: M0.PVer <- connectedFromList M0.IsParentOf sitev rg
      , pool :: M0.Pool <- connectedFromList M0.IsParentOf pver rg
      , let root = M0.getM0Root rg
      , M0.fid pool /= M0.rt_mdpool root  -- XXX-MULTIPOOLS QnD
      , not (G.isConnected pver Cas.Is M0.MetadataPVer rg)  -- exclude MD pver
      , M0.v_fid pver /= M0.rt_imeta_pver root              -- exclude DIX pver
      ]

    getK :: M0.PVer -> Word32
    getK pver = let Right pva = M0.v_data pver  -- pver is known to be actual
                in _pa_K (M0.va_attrs pva)

    unusableDrives :: M0.PVer -> [M0.Disk]
    unusableDrives pver = nub
        [ disk
        | sitev :: M0.SiteV <- G.connectedTo pver M0.IsParentOf rg
        , rackv :: M0.RackV <- G.connectedTo sitev M0.IsParentOf rg
        , enclv :: M0.EnclosureV <- G.connectedTo rackv M0.IsParentOf rg
        , ctrlv :: M0.ControllerV <- G.connectedTo enclv M0.IsParentOf rg
        , diskv :: M0.DiskV <- G.connectedTo ctrlv M0.IsParentOf rg
        , disk :: M0.Disk <- connectedFromList M0.IsRealOf diskv rg
        , d :: M0.SDev <- connectedFromList M0.IsOnHardware disk rg
        , not (isUsable d)
        ]

-- | Install storage device into the slot.
updateStorageDevicePresence :: UUID          -- ^ Thread id.
                            -> R.Node        -- ^ Node in question.
                            -> StorageDevice -- ^ Installed storage device.
                            -> Cas.Slot      -- ^ Slot of the device.
                            -> Bool          -- ^ Is device installed.
                            -> Maybe Bool    -- ^ Is device powered.
                            -> PhaseM RC l ()
updateStorageDevicePresence uuid node sdev sdev_loc is_installed mis_powered = do
  was_powered <- StorageDevice.isPowered sdev
  fix $ \next -> do
    eresult <- StorageDevice.insertTo sdev sdev_loc
    case eresult of
      -- New drive was installed
      Right () | is_installed ->
        notify $ DriveInserted uuid node sdev_loc sdev mis_powered
      -- Same drive but it was removed.
      Right () -> do -- this is a bad case, as it means that we have missed notifcatio about drive
                     -- removal
        StorageDevice.ejectFrom sdev sdev_loc
      -- removing device
      Left StorageDevice.AlreadyInstalled | not is_installed -> do
        StorageDevice.ejectFrom sdev sdev_loc
        Log.rcLog' Log.DEBUG ("Removing no longer installed device from slot" :: String)
        notify $ DriveRemoved uuid node sdev_loc sdev mis_powered
      Left StorageDevice.AlreadyInstalled | Just is_powered <- mis_powered
                                          , was_powered /= is_powered ->
        notify $ DrivePowerChange uuid node sdev_loc sdev is_powered
      -- Nothing changed
      Left StorageDevice.AlreadyInstalled -> return ()
      Left (StorageDevice.AnotherInSlot asdev) -> do
        Log.withLocalContext' $ do
          Log.tagLocalContext asdev Nothing
          Log.tagLocalContext [("location" :: String, show sdev_loc)] Nothing
          Log.rcLog Log.ERROR
            ("Insertion in a slot where previous device was inserted - removing old device." :: String)
          StorageDevice.ejectFrom asdev sdev_loc
          notify $ DriveRemoved uuid node sdev_loc asdev mis_powered
        next
      Left (StorageDevice.InAnotherSlot slot) -> do
        Log.rcLog' Log.ERROR
          ("Storage device was associated with another slot." :: String)
        StorageDevice.ejectFrom sdev slot
        notify $ DriveRemoved uuid node sdev_loc sdev mis_powered
        next

-- | Update status of the storage device.
updateStorageDeviceStatus :: UUID              -- ^ Thread UUID.
                          -> R.Node            -- ^ Node in question.
                          -> Cas.StorageDevice -- ^ Updated storage device.
                          -> Cas.Slot          -- ^ Storage device location.
                          -> String            -- ^ Storage device status.
                          -> String            -- ^ Status reason.
                          -> PhaseM RC l Bool
updateStorageDeviceStatus uuid node disk slot status reason = do
    oldDriveStatus <- StorageDevice.status disk
    case (status, reason) of
     (s, r) | oldDriveStatus == Cas.StorageDeviceStatus s r -> do
       Log.rcLog' Log.DEBUG $ "status unchanged: " ++ show oldDriveStatus
       return True
     (map toUpper -> "FAILED", _) -> do
       StorageDevice.setStatus disk status reason
       notify $ DriveFailed uuid node slot disk
       return True
     (map toUpper -> "EMPTY", map toUpper -> "NONE") -> do
       -- This is probably indicative of expander reset, or some other error.
       StorageDevice.setStatus disk status reason
       notify $ DriveTransient uuid node slot disk
       return True
     (map toUpper -> "OK", map toUpper -> "NONE") -> do
       -- Disk has returned to normal after some failure.
       StorageDevice.setStatus disk status reason
       notify $ DriveOK uuid node slot disk
       return True
     _ -> return False
