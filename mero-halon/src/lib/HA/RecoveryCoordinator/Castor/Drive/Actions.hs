{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
module  HA.RecoveryCoordinator.Castor.Drive.Actions
  ( mkAttachDisk
  , mkDetachDisk
  ) where

import Data.Functor (void)
import Data.Binary (Binary)
import Data.Typeable
import Data.Maybe (listToMaybe)
import Data.Bifunctor
import GHC.Generics

import qualified HA.ResourceGraph as G
import           HA.Resources
import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Mero.Conf
import HA.RecoveryCoordinator.Actions.Mero.Spiel
import HA.RecoveryCoordinator.Actions.Mero.Core
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note (showFid)
import Control.Distributed.Process hiding (try)
import Control.Monad.Catch (SomeException, try)

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

    next <- liftProcess $ do
      rc <- getSelfPid
      return $ usend rc . SpielDeviceAttached sdev . first (show :: SomeException -> String)
    mp <- listToMaybe . G.connectedTo Cluster Has <$> getLocalGraph
    case mdisk of
      Just d ->
        void $ withSpielRC $ \sc m0 ->
          m0asynchronously m0 next $ withRConfIO sc mp $ Spiel.deviceAttach sc (M0.fid d)
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

    next <- liftProcess $ do
      rc <- getSelfPid
      return $ usend rc . SpielDeviceDetached sdev . first (show :: SomeException -> String)
    mp <- listToMaybe . G.connectedTo Cluster Has <$> getLocalGraph
    case mdisk of
      Just d ->
        void $ withSpielRC $ \sc m0 -> do
          m0asynchronously m0 next $ withRConfIO sc mp $ Spiel.deviceDetach sc (M0.fid d)
      Nothing -> do
        phaseLog "warning" $ "Disk for found for " ++ showFid sdev ++ " ignoring."
        onFailure sdev "no such disk")
