{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
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
  , checkDiskFailureWithinTolerance
  , updateStorageDevicePresence
  , updateStorageDeviceStatus
  ) where

import           Data.Binary (Binary)
import           Data.Char (toUpper)
import           Data.Function (fix)
import           Data.Functor (void)
import           Data.List (nub)
import           Data.Maybe (mapMaybe)
import           Data.Typeable
import           Data.UUID (UUID)
import           Data.Word (Word32)
import           GHC.Generics

import qualified HA.ResourceGraph as G
import           HA.RecoveryCoordinator.Castor.Drive.Actions.Graph
import           HA.RecoveryCoordinator.Castor.Drive.Events
import           HA.RecoveryCoordinator.RC.Actions.Core
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.RecoveryCoordinator.Hardware.StorageDevice.Actions as StorageDevice
import           HA.RecoveryCoordinator.Mero.Actions.Spiel
import           HA.RecoveryCoordinator.Mero.Actions.Core
import           HA.RecoveryCoordinator.Mero.Events
import qualified HA.RecoveryCoordinator.Mero.Transitions as Tr
import qualified HA.RecoveryCoordinator.Mero.Transitions.Internal as TrI
import           HA.Resources (Cluster(..), Has(..))
import qualified HA.Resources as Res
import           HA.Resources.Castor
  ( StorageDevice
  , StorageDeviceAttr(SDRemovedFromRAID)
  )
import qualified HA.Resources.Castor as Res
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           Mero.ConfC
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
          case eresult of
            Left e -> onFailure sdev e
            Right _ -> onSuccess sdev
        | otherwise -> continue ph

  return (ph, \sdev -> do
    Log.actLog "Attaching disk" [ ("disk.fid", show $ M0.fid sdev) ]
    mdisk <- lookupSDevDisk sdev

    unlift <- mkUnliftProcess
    next <- liftProcess $ do
      rc <- getSelfPid
      return $ usend rc . SpielDeviceAttached sdev . handleSNSReply
    mp <- G.connectedTo Cluster Has <$> getGraph
    case mdisk of
      Just d ->
        void $ withSpielIO $
          withRConfIO mp $ try (Spiel.deviceAttach (M0.fid d)) >>= unlift . next
      Nothing -> do
        Log.rcLog' Log.WARN $ "Disk for found for " ++ M0.showFid sdev ++ " ignoring."
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
           case eresult of
             Left e -> onFailure sdev e
             Right _ -> onSuccess sdev
        | otherwise -> continue ph

  return (ph, \sdev -> do
    Log.actLog "Detaching disk" [ ("disk.fid", show $ M0.fid sdev) ]
    mdisk <- lookupSDevDisk sdev
    unlift <- mkUnliftProcess

    next <- liftProcess $ do
      rc <- getSelfPid
      return $ usend rc . SpielDeviceDetached sdev . handleSNSReply
    mp <- G.connectedTo Cluster Has <$> getGraph
    case mdisk of
      Just d ->
        void $ withSpielIO $
          withRConfIO mp $ try (Spiel.deviceDetach (M0.fid d)) >>= unlift . next
      Nothing -> do
        Log.rcLog' Log.WARN $ "Disk for found for " ++ M0.showFid sdev ++ " ignoring."
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

-- | Produce an 'SDevTransition' which, when unpacked into
-- 'AnyStateSet' (with 'sdevStateSet'), will either set the drive into
-- the desired state or will set the drive transient. Either succeeds
-- ('Right') or fails and becomes transient ('Left').
--
-- TODO: Think about this a bit more. If we're updating a lot of
-- drives at once, it's highly inefficient to run all this on every
-- update.
checkDiskFailureWithinTolerance :: M0.SDev -> M0.SDevState -> G.Graph
                                -> Either AnyStateSet AnyStateSet
checkDiskFailureWithinTolerance sdev st rg = case mk of
  Just (k, fs)
    -- We can't tolerate more failures so keep/set device transient.
    -- @newFailure@ ensures that transient doesn't wrap a state into
    -- what's considered a failed state.
    | newFailure && k <= fs -> Left $ stateSet sdev Tr.sdevFailTransient
    | otherwise -> Right $ stateSet sdev (TrI.constTransition st)
  -- Couldn't find K for some reason, just blindly change state
  Nothing -> Right $ stateSet sdev (TrI.constTransition st)
  where
    getK :: M0.PVer -> Maybe Word32
    getK pver = case M0.v_type pver of
      pva@M0.PVerActual{} -> case M0.v_attrs pva of
        PDClustAttr _ k _ _ _ -> Just k
      _ -> Nothing

    failingState :: M0.SDev -> M0.SDevState -> Bool
    failingState d s = case M0.toConfObjState d s of
      M0.M0_NC_FAILED -> True
      M0.M0_NC_REPAIR -> True
      M0.M0_NC_REPAIRED -> True
      M0.M0_NC_REBALANCE -> True
      _ -> False

    -- It's only a new failure if we're not in a failed state already.
    -- For example we may be moving from REPAIRED to REBALANCING which
    -- doesn't change number of failures.
    newFailure :: Bool
    newFailure = not (failingState sdev $ M0.getState sdev rg) && failingState sdev st

    -- Find maximum number of allowed failures and number of current failures.
    mk :: Maybe (Int, Int)
    mk = let connectedToList a b c = G.asUnbounded $ G.connectedTo a b c
             connectedFromList a b c = G.asUnbounded $ G.connectedFrom a b c
             Just root = G.connectedTo Cluster Has rg :: Maybe M0.Root
             -- XXX-MULTIPOOLS: Shouldn't we distinguish pvers of different pools?
             pvers = nub
               [ pver
               | disk  <- connectedToList sdev M0.IsOnHardware  rg :: [M0.Disk]
               , cntrl <- connectedFromList M0.IsParentOf disk  rg :: [M0.Controller]
               , encl  <- connectedFromList M0.IsParentOf cntrl rg :: [M0.Enclosure]
               , rack  <- connectedFromList M0.IsParentOf encl  rg :: [M0.Rack]
               , rackv <- G.connectedTo rack M0.IsRealOf        rg :: [M0.RackV]
               -- XXX-MULTIPOOLS: Site, SiteV
               , pver  <- connectedFromList M0.IsParentOf rackv rg :: [M0.PVer]
               , pool  <- connectedFromList M0.IsParentOf pver  rg :: [M0.Pool]
               , M0.fid pool /= M0.rt_mdpool root -- exclude metadata pool
               ]
             failedDisks = [ d
                           | rack :: M0.Rack <- G.connectedTo root M0.IsParentOf rg
                           , encl :: M0.Enclosure <- G.connectedTo rack M0.IsParentOf rg
                           , ctrl :: M0.Controller <- G.connectedTo encl M0.IsParentOf rg
                           , disk :: M0.Disk <- G.connectedTo ctrl M0.IsParentOf rg
                           , d :: M0.SDev <- connectedFromList M0.IsOnHardware disk rg
                           , failingState d (M0.getState d rg)
                           ]
         in case mapMaybe getK pvers of
              [] -> Nothing
              xs -> Just (fromIntegral $ maximum xs, length failedDisks)

-- | Install storage device into the slot.
updateStorageDevicePresence :: UUID          -- ^ Thread id.
                            -> Res.Node      -- ^ Node in question.
                            -> StorageDevice -- ^ Installed storage device.
                            -> Res.Slot      -- ^ Slot of the device.
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
          Log.tagLocalContext [("location"::String, show sdev_loc)] Nothing
          Log.rcLog Log.ERROR
            ("Insertion in a slot where previous device was inserted - removing old device.":: String)
          StorageDevice.ejectFrom asdev sdev_loc
          notify $ DriveRemoved uuid node sdev_loc asdev mis_powered
        next
      Left (StorageDevice.InAnotherSlot slot) -> do
        Log.rcLog' Log.ERROR
          ("Storage device was associated with another slot.":: String)
        StorageDevice.ejectFrom sdev slot
        notify $ DriveRemoved uuid node sdev_loc sdev mis_powered
        next

-- | Update status of the storage device.
updateStorageDeviceStatus ::
     UUID  -- ^ Thread UUID.
  -> Res.Node -- ^ Node in question.
  -> Res.StorageDevice -- ^ Updated storage device.
  -> Res.Slot -- ^ Storage device location.
  -> String -- ^ Storage device status.
  -> String -- ^ Status reason.
  -> PhaseM RC l Bool
updateStorageDeviceStatus uuid node disk slot status reason = do
    oldDriveStatus <- StorageDevice.status disk
    case (status, reason) of
     (s, r) | oldDriveStatus == Res.StorageDeviceStatus s r -> do
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
