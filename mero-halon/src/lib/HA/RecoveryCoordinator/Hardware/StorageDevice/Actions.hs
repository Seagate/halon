{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE FlexibleContexts #-}
-- |
-- Module    : HA.RecoveryCoordinator.Hardware.StorageDevice.Actions
-- Copyright : (C) 2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Actions on 'StorageDevice's.
module HA.RecoveryCoordinator.Hardware.StorageDevice.Actions
  ( exists
    -- * Drive location.
  , isAt
  , mkLocation
  , atSlot
  , location
  , insertTo
  , InsertionError(..)
  , ejectFrom
    -- * Drive status.
  , status
  , setStatus
    -- * Identifiers
  , getIdentifiers
  , hasIdentifier
    -- * Attributes
  , setAttr
  , unsetAttr
  , findAttrs
    -- ** Helpers.
  , path
  , setPath
  , enclosure
    --, setPath
  , raidDevice
    -- * Drive power.
  , poweron
  , poweroff
  , isPowered
    -- * Various attributes.
  , identify
  ) where

import           Control.Arrow ((>>>))
import           Data.Bool (bool)
import           Data.Proxy
import           Data.List (foldl')
import           Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import           Data.Foldable (for_)
import           HA.RecoveryCoordinator.RC.Application
import           HA.RecoveryCoordinator.RC.Actions.Core
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import           HA.Resources (Cluster(..), Has(..))
import           HA.Resources.Castor
import qualified HA.ResourceGraph as G
import           Network.CEP

-- | Check if storage device exists in a graph. If so
-- it returns 'StorageDevice' object
exists :: String   -- ^ Serial number.
       -> PhaseM RC l (Maybe StorageDevice)
exists sn =  bool Nothing (Just sdev)
          .  G.isConnected Cluster Has sdev
         <$> getGraph
  where sdev = StorageDevice sn

-- | Check if 'StorageDevice' is locted in given enclosure.
isAt :: StorageDevice -> Slot -> PhaseM RC l Bool
isAt sdev loc = G.isConnected sdev Has loc <$> getGraph

-- | Get device that is in slot currently.
atSlot :: Slot -> PhaseM RC l (Maybe StorageDevice)
atSlot loc = G.connectedFrom Has loc <$> getGraph

-- | Get location of current device.
location :: StorageDevice -> PhaseM RC l (Maybe Slot)
location sdev = G.connectedTo sdev Has <$> getGraph

-- | Get device enclosure, if there is no connection to location,
-- then this call tries to find direct connection.
enclosure :: StorageDevice -> PhaseM RC l (Maybe Enclosure)
enclosure sdev = do
 rg <- getGraph
 return $ slotEnclosure <$> G.connectedTo sdev Has rg

-- | Register device location in graph.
mkLocation :: Enclosure -> Int -> PhaseM RC l Slot
mkLocation enc num = do
  modifyGraph $ G.connect enc Has loc
  return loc
  where loc = Slot enc num

-- | Failure to insert a 'StorageDevice' into a 'Slot' has occured.
data InsertionError
  = AnotherInSlot StorageDevice
  | AlreadyInstalled
  | InAnotherSlot Slot
  deriving (Show, Eq)

-- | Insert storage device in location.
--
-- Returns previous storage device that were inserted in that slot.
--
-- This method doesn't create deprecated @'Enclosure' -> 'StorageDevice'@
-- relation because this relation is not needed when connection to
-- 'Slot' exits.
insertTo :: StorageDevice
         -> Slot
         -> PhaseM RC l (Either InsertionError ())
insertTo sdev sdev_loc = do
  rg <- getGraph
  case G.connectedFrom Has sdev_loc rg of
    -- No storage device is associated with current location, we
    -- are free to just associate drive with that.
    Nothing -> case G.connectedTo sdev Has rg of
      -- This StorageDevice is already associated with another slot
      Just loc' -> return $ Left $ InAnotherSlot loc'
      -- The slot is empty and StorageDevice doesn't belong anywhere,
      -- put it in the slot
      Nothing  -> do
        Log.rcLog' Log.DEBUG ("Device inserted in the slot"::String)
        modifyGraph $ G.connect sdev Has sdev_loc
                  -- We don't know how many slots there are in the
                  -- enclosure ahead of time: if we're getting
                  -- information about a whole new drive (MD/RAID) in
                  -- some previously unseen slot, we need to connect
                  -- the slot up to the enclosure too.
                  >>> G.connect (slotEnclosure sdev_loc) Has sdev_loc
        return $ Right ()
    -- The slot is already filled by the StorageDevice
    Just sdev' | sdev' == sdev -> do
       Log.rcLog' Log.DEBUG ("Drive is already installed in this slot."::String)
       return $ Left AlreadyInstalled
    -- Some other StorageDevice is filling the slot already.
    Just sdev' -> do
       Log.rcLog' Log.ERROR [("info"::String, "Another drive was inserted in the slot.")
                            ,("sdev", show sdev')]
       return $ Left $ AnotherInSlot sdev'

-- | Remove 'StorageDevice' from it's slot.
--
-- TODO: remove device identifiers what are not applicable now.
ejectFrom :: StorageDevice -> Slot -> PhaseM RC l ()
ejectFrom sdev sdev_loc = do
  Log.rcLog' Log.DEBUG ("Ejecting " ++ show sdev ++ " from " ++ show sdev_loc :: String)
  modifyGraph $ G.disconnect sdev Has sdev_loc
            >>> G.disconnectAllFrom sdev Has (Proxy :: Proxy StorageDeviceAttr)
            >>> (\rg -> case G.connectedTo sdev Is rg of
                          Just (StorageDeviceStatus "HALON-FAILED" _) -> rg
                          Just (StorageDeviceStatus "FAILED" _) -> rg
                          _ -> G.connect sdev Is (StorageDeviceStatus "EMPTY" "None") rg)

-- | Turn 'StorageDevice' power on.
poweron :: StorageDevice -> PhaseM RC l () -- XXX: move to location.
poweron sdev = do
  setAttr sdev (SDPowered True)
  unsetAttr sdev (SDPowered False)

-- | Turn 'StorageDevice' power off.
poweroff :: StorageDevice -> PhaseM RC l ()
poweroff sdev = do -- XXX: move to locat
  setAttr sdev (SDPowered False)
  unsetAttr sdev (SDPowered True)

-- | Check if 'StorageDevice' is powered.
isPowered :: StorageDevice -> PhaseM RC l Bool
isPowered sdev = maybe True id . listToMaybe . mapMaybe unwrap
              <$> findAttrs (const True) sdev
  where
    unwrap (SDPowered x) = Just x
    unwrap _             = Nothing

-- | Get the status of a storage device.
status :: StorageDevice
       -> PhaseM RC l StorageDeviceStatus
status dev =
    fromMaybe (StorageDeviceStatus "UNKNOWN" "UNKNOWN") . G.connectedTo dev Is
        <$> getGraph

-- | Update the status of a storage device.
--
-- XXX: keep in mind that some statuses are final.
setStatus :: StorageDevice
          -> String -- ^ Status.
          -> String -- ^ Reason.
          -> PhaseM RC l ()
setStatus dev st reason = do
  ds <- status dev
  let statusNode = StorageDeviceStatus st reason
  Log.rcLog' Log.TRACE $ "Updating status for device"
  Log.rcLog' Log.DEBUG [("status.old", show ds)
                       ,("status.new", show statusNode)
                       ]
  modifyGraph $ G.connect dev Is statusNode

-- | Add an additional identifier to a logical storage device.
identify :: StorageDevice -> [DeviceIdentifier] -> PhaseM RC l ()
identify ld dis = do
 Log.rcLog' Log.DEBUG $ "Adding identifiers " ++ show dis ++ " to device " ++ show ld
 modifyGraph $ \rg -> foldl' (\g i -> G.connect ld Has i g) rg dis

-- Internal

-- | Set an attribute on a storage device.
setAttr :: StorageDevice -> StorageDeviceAttr -> PhaseM RC l ()
setAttr sd attr  = do
    Log.rcLog' Log.TRACE $ "Setting disk attribute " ++ show attr ++ " on " ++ show sd
    modifyGraph $ G.connect sd Has attr

-- | Unset an attribute on a storage device.
unsetAttr :: StorageDevice -> StorageDeviceAttr -> PhaseM RC l ()
unsetAttr sd attr = do
    Log.rcLog' Log.TRACE $ "Unsetting disk attribute "
                  ++ show attr ++ " on " ++ show sd
    modifyGraph (G.disconnect sd Has attr)

-- | Find attributes matching the given filter on a storage device.
findAttrs :: (StorageDeviceAttr -> Bool)
                       -> StorageDevice
                       -> PhaseM RC l [StorageDeviceAttr]
findAttrs k sdev = do
    rg <- getGraph
    return [ attr | attr <- G.connectedTo sdev Has rg :: [StorageDeviceAttr]
                  , k attr
                  ]

-- | Lookup filesystem paths for storage devices (e.g. /dev/sda1)
path :: StorageDevice -> PhaseM RC l (Maybe String)
path sd =
    listToMaybe . mapMaybe extractPath <$> getIdentifiers sd
  where
    extractPath (DIPath x) = Just x
    extractPath _ = Nothing

-- | Set the path ('DIPath') 'DeviceIdentifier' for the
-- 'StorageDevice' to the given 'String'.
setPath :: StorageDevice -> String -> PhaseM RC l ()
setPath sd path' = do
   old <- mapMaybe extractPath <$> getIdentifiers sd
   for_ old $ \o -> modifyGraph $ G.disconnect sd Has o
   modifyGraph $ G.connect sd Has (DIPath path')
  where
    extractPath x@DIPath{} = Just x
    extractPath _ = Nothing

-- | Get all 'DeviceIdentifier's for the 'StorageDevice'.
getIdentifiers :: StorageDevice
               -> PhaseM RC l [DeviceIdentifier]
getIdentifiers sd = G.connectedTo sd Has <$> getGraph

-- | Test if a drive have a given identifier
hasIdentifier :: StorageDevice
              -> DeviceIdentifier
              -> PhaseM RC l Bool
hasIdentifier ld di = elem di <$> getIdentifiers ld

-- | Lookup raid device associated with a storage device.
raidDevice :: StorageDevice -> PhaseM RC l [String]
raidDevice sd =
    mapMaybe extract <$> getIdentifiers sd
  where
    extract (DIRaidDevice x) = Just x
    extract _ = Nothing
