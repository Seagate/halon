{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
module  HA.RecoveryCoordinator.Castor.Drive.Actions
  ( mkAttachDisk
  , mkDetachDisk
    -- * RAID Drive functions
  , isRemovedFromRAID
  , markRemovedFromRAID
  , unmarkRemovedFromRAID
    -- * Exported for test
  , SpielDeviceAttached(..)
  , SpielDeviceDetached(..)
  ) where

import Data.Functor (void)
import Data.Binary (Binary)
import Data.Typeable
import GHC.Generics

import qualified HA.ResourceGraph as G
import           HA.Resources
import HA.Resources.Castor (StorageDevice, StorageDeviceAttr(..))
import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Hardware
  ( findStorageDeviceAttrs
  , setStorageDeviceAttr
  , unsetStorageDeviceAttr
  )
import HA.RecoveryCoordinator.Actions.Mero.Conf
import HA.RecoveryCoordinator.Actions.Mero.Spiel
import HA.RecoveryCoordinator.Actions.Mero.Core
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note (showFid)
import Control.Distributed.Process hiding (try)
import Control.Monad.Catch (SomeException, try, fromException)
import System.IO.Error

import Network.CEP

import qualified Mero.Spiel as Spiel

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
      (l -> PhaseM LoopState l (Maybe M0.SDev))
   -> (M0.SDev -> String -> PhaseM LoopState l ()) -- ^ Action in case of failure
   -> (M0.SDev -> PhaseM LoopState l ())           -- ^ Action in case of success
   -> RuleM LoopState l (Jump PhaseHandle, M0.SDev -> PhaseM LoopState l ())
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
    phaseLog "spiel"    $ "Attaching disk."
    phaseLog "disk.fid" $ show $ M0.fid sdev
    mdisk <- lookupSDevDisk sdev

    unlift <- mkUnliftProcess
    next <- liftProcess $ do
      rc <- getSelfPid
      return $ usend rc . SpielDeviceAttached sdev . handleSNSReply
    mp <- G.connectedTo Cluster Has <$> getLocalGraph
    case mdisk of
      Just d ->
        void $ withSpielIO $
          withRConfIO mp $ try (Spiel.deviceAttach (M0.fid d)) >>= unlift . next
      Nothing -> do
        phaseLog "warning" $ "Disk for found for " ++ showFid sdev ++ " ignoring."
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
      (l -> PhaseM LoopState l (Maybe M0.SDev))
   -> (M0.SDev -> String -> PhaseM LoopState l ())
   -> (M0.SDev -> PhaseM LoopState l ())
   -> RuleM LoopState l (Jump PhaseHandle, M0.SDev -> PhaseM LoopState l ())
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
    phaseLog "spiel"    $ "Detaching disk."
    phaseLog "disk.fid" $ show $ M0.fid sdev
    mdisk <- lookupSDevDisk sdev
    unlift <- mkUnliftProcess

    next <- liftProcess $ do
      rc <- getSelfPid
      return $ usend rc . SpielDeviceDetached sdev . handleSNSReply
    mp <- G.connectedTo Cluster Has <$> getLocalGraph
    case mdisk of
      Just d ->
        void $ withSpielIO $
          withRConfIO mp $ try (Spiel.deviceDetach (M0.fid d)) >>= unlift . next
      Nothing -> do
        phaseLog "warning" $ "Disk for found for " ++ showFid sdev ++ " ignoring."
        onFailure sdev "no such disk")


-- | Mark that a device has been removed from the RAID array of which it
--   is part.
markRemovedFromRAID :: StorageDevice -> PhaseM LoopState l ()
markRemovedFromRAID sdev = setStorageDeviceAttr sdev SDRemovedFromRAID

-- | Remove the marker indicating that a device has been removed from the RAID
--   array of which it is part.
unmarkRemovedFromRAID :: StorageDevice -> PhaseM LoopState l ()
unmarkRemovedFromRAID sdev = unsetStorageDeviceAttr sdev SDRemovedFromRAID

-- | Check whether a device has been removed from its RAID array.
isRemovedFromRAID :: StorageDevice -> PhaseM LoopState l Bool
isRemovedFromRAID = fmap (not . null) . findStorageDeviceAttrs go
  where
    go SDRemovedFromRAID = True
    go _ = False
