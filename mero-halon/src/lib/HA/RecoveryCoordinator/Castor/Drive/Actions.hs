{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
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
  , iemFailureOverTolerance
  ) where

import Data.Binary (Binary)
import Data.Functor (void)
import Data.Maybe (mapMaybe)
import Data.Monoid ((<>))
import qualified Data.Text as T
import Data.Typeable
import Data.Word (Word32)
import GHC.Generics

import Data.List (nub)

import qualified HA.ResourceGraph as G
import           HA.Resources
import HA.Resources.Castor (StorageDevice, StorageDeviceAttr(..))
import HA.RecoveryCoordinator.Castor.Drive.Actions.Graph
import HA.RecoveryCoordinator.RC.Actions.Core
import HA.RecoveryCoordinator.Actions.Hardware
  ( findStorageDeviceAttrs
  , setStorageDeviceAttr
  , unsetStorageDeviceAttr
  )
import HA.RecoveryCoordinator.Mero.Actions.Spiel
import HA.RecoveryCoordinator.Mero.Actions.Core
import HA.RecoveryCoordinator.Mero.Events
import qualified HA.RecoveryCoordinator.Mero.Transitions as Tr
import qualified HA.RecoveryCoordinator.Mero.Transitions.Internal as TrI
import qualified HA.Resources as Res
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import HA.Services.SSPL.CEP (sendInterestingEvent)
import HA.Services.SSPL.IEM (logFailureOverK)
import HA.Services.SSPL.LL.Resources (InterestingEventMessage(..))
import Mero.ConfC
import qualified Mero.Spiel as Spiel

import Control.Distributed.Process hiding (try)
import Control.Monad.Catch (SomeException, try, fromException)
import System.IO.Error

import Network.CEP


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
        phaseLog "warning" $ "Disk for found for " ++ M0.showFid sdev ++ " ignoring."
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
        phaseLog "warning" $ "Disk for found for " ++ M0.showFid sdev ++ " ignoring."
        onFailure sdev "no such disk")


-- | Mark that a device has been removed from the RAID array of which it
--   is part.
markRemovedFromRAID :: StorageDevice -> PhaseM RC l ()
markRemovedFromRAID sdev = setStorageDeviceAttr sdev SDRemovedFromRAID

-- | Remove the marker indicating that a device has been removed from the RAID
--   array of which it is part.
unmarkRemovedFromRAID :: StorageDevice -> PhaseM RC l ()
unmarkRemovedFromRAID sdev = unsetStorageDeviceAttr sdev SDRemovedFromRAID

-- | Check whether a device has been removed from its RAID array.
isRemovedFromRAID :: StorageDevice -> PhaseM RC l Bool
isRemovedFromRAID = fmap (not . null) . findStorageDeviceAttrs go
  where
    go SDRemovedFromRAID = True
    go _ = False

-- | Send an IEM about 'M0.SDev' failure transition being prevented by
-- maximum allowed failure tolerance.
iemFailureOverTolerance :: M0.SDev -> PhaseM RC l ()
iemFailureOverTolerance sdev =
  sendInterestingEvent . InterestingEventMessage $ logFailureOverK
      (" {'failedDevice':" <> T.pack (fidToStr $ M0.fid sdev) <> "}")

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
    mk = let pvers = nub
               [ pver
               | disk  <- G.connectedToList sdev M0.IsOnHardware  rg :: [M0.Disk]
               , cntrl <- G.connectedFromList M0.IsParentOf disk  rg :: [M0.Controller]
               , encl  <- G.connectedFromList M0.IsParentOf cntrl rg :: [M0.Enclosure]
               , rack  <- G.connectedFromList M0.IsParentOf encl  rg :: [M0.Rack]
               , rackv <- G.connectedTo  rack M0.IsRealOf         rg :: [M0.RackV]
               , pver  <- G.connectedFromList M0.IsParentOf rackv rg :: [M0.PVer]
               , pool  <- G.connectedFromList M0.IsRealOf   pver  rg :: [M0.Pool]
               -- exclude metadata pools
               , M0.fid pool `notElem` mdFids
               ]
             mdFids = [ M0.f_mdpool_fid fs
                      | p <- G.connectedToList Res.Cluster Has rg :: [M0.Profile]
                      , fs <- G.connectedTo p M0.IsParentOf rg ]

             failedDisks = [ d | prof :: M0.Profile <- G.connectedToList Res.Cluster Has rg
                               , fs :: M0.Filesystem <- G.connectedTo prof M0.IsParentOf rg
                               , r :: M0.Rack <- G.connectedTo fs M0.IsParentOf rg
                               , enc :: M0.Enclosure <- G.connectedTo r M0.IsParentOf rg
                               , ctrl :: M0.Controller <- G.connectedTo enc M0.IsParentOf rg
                               , disk :: M0.Disk <- G.connectedTo ctrl M0.IsParentOf rg
                               , d :: M0.SDev <- G.connectedFromList M0.IsOnHardware disk rg
                               , failingState d (M0.getState d rg)
                               ]
         in case mapMaybe getK pvers of
              [] -> Nothing
              xs -> Just (fromIntegral $ maximum xs, length failedDisks)
