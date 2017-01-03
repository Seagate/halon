{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE FlexibleContexts #-}
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
import           Data.Bool
import           Data.Proxy
import           Data.List (foldl')
import           Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import           Data.Foldable (for_)
import           HA.RecoveryCoordinator.RC.Application
import           HA.RecoveryCoordinator.RC.Actions.Core
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.Resources as R
import           HA.Resources.Castor
import qualified HA.ResourceGraph as G
import           Network.CEP

-- | Check if storage device exists in a graph. If so
-- it returns 'StorageDevice' object
exists :: String   -- ^ Serial number.
       -> PhaseM RC l (Maybe StorageDevice)
exists sn =  bool Nothing (Just sdev)
          .  G.isConnected R.Cluster R.Has sdev
         <$> getLocalGraph
  where sdev = StorageDevice sn

-- | Check if 'StorageDevice' is locted in given enclosure.
isAt :: StorageDevice -> Slot -> PhaseM RC l Bool
isAt sdev loc = G.isConnected sdev R.Has loc <$> getLocalGraph

-- | Get device that is in slot currently.
atSlot :: Slot -> PhaseM RC l (Maybe StorageDevice)
atSlot loc = G.connectedFrom R.Has loc <$> getLocalGraph

-- | Get location of current device.
location :: StorageDevice -> PhaseM RC l (Maybe Slot)
location sdev = G.connectedTo sdev R.Has <$> getLocalGraph

-- | Get device enclosure, if there is no connection to location,
-- then thi call tries to find direct connection.
enclosure :: StorageDevice -> PhaseM RC l (Maybe Enclosure)
enclosure sdev = do
 rg <- getLocalGraph
 return $ 
   maybe (G.connectedFrom R.Has sdev rg)
         (\(Slot e _) -> Just e) $ G.connectedTo sdev R.Has rg

-- | Register device location in graph.
mkLocation :: Enclosure -> Int -> PhaseM RC l Slot
mkLocation enc num = do
  modifyGraph $ G.connect enc R.Has loc
  return loc
  where loc = Slot enc num

data InsertionError
  = AnotherInSlot StorageDevice
  | AlreadyInstalled
  | InAnotherSlot Slot
  | InAnotherEnclosure Enclosure
  deriving (Show, Eq)

-- | Insert storage device in location.
--
-- Returns previous storage device that were inserted in that slot.
--
-- This method doesn't create deprecated 'Enclosure'-&gt;'StorageDevice' relation
-- because this relation is not needed when connection to 'StorageDeviceLocation'
-- exits.
insertTo :: StorageDevice
         -> Slot 
         -> PhaseM RC l (Either InsertionError ())
insertTo sdev sdev_loc@(Slot enc _) = do
  rg <- getLocalGraph
  case G.connectedFrom R.Has sdev_loc rg of
    -- No storage device is associated with current location, we
    -- are free to just associate drive with that.
    Nothing -> case G.connectedTo sdev R.Has rg of
      Just loc -> return $ Left $ InAnotherSlot loc
      Nothing  -> case G.connectedFrom R.Has sdev rg of
        Nothing -> do
          Log.rcLog' Log.DEBUG ("Device inserted in the slot"::String)
          modifyGraph $ G.connect sdev R.Has sdev_loc
          return $ Right ()
        Just enc' | enc == enc' -> do
          Log.rcLog' Log.WARN ("Populating missing slot device info"::String)
          modifyGraph $ G.connect sdev R.Has sdev_loc
          return $ Left $ AlreadyInstalled
        Just enc' -> return $ Left $ InAnotherEnclosure enc'
    Just sdev' | sdev' == sdev -> do
       Log.rcLog' Log.DEBUG ("Drive is already installed in this slot."::String)
       return $ Left $ AlreadyInstalled
    Just sdev' -> do
       Log.rcLog' Log.ERROR [("info"::String, "Another drive was inserted in the slot.")
                            ,("sdev", show sdev')]
       return $ Left $ AnotherInSlot sdev'

-- | Remove 'StorageDevice' from it's slot.
--
-- TODO: remove device identifiers what are not applicable now.
ejectFrom :: StorageDevice -> Slot -> PhaseM RC l ()
ejectFrom sdev sdev_loc = do
  modifyGraph $ G.disconnect sdev R.Has sdev_loc
            >>> G.disconnectAllFrom sdev R.Has (Proxy :: Proxy StorageDeviceAttr)
            >>> G.disconnectAllTo (Proxy :: Proxy Enclosure) R.Has sdev
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
status dev = fromMaybe (StorageDeviceStatus "UNKNOWN" "UNKNOWN") . G.connectedTo dev Is <$> getLocalGraph

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
  phaseLog "rg" $ "Updating status for device"
  Log.rcLog' Log.DEBUG [("status.old", show ds)
                       ,("status.new", show statusNode)
                       ]
  modifyGraph $ G.connect dev Is statusNode

-- | Add an additional identifier to a logical storage device.
identify :: StorageDevice
         -> [DeviceIdentifier]
         -> PhaseM RC l ()
identify ld dis = do
 Log.rcLog' Log.DEBUG $ "Adding identifiers " ++ show dis ++ " to device " ++ show ld
 modifyGraph $ \rg -> foldl' (\g i -> G.connect ld R.Has i g) rg dis

-- Internal

-- | Set an attribute on a storage device.
setAttr :: StorageDevice -> StorageDeviceAttr -> PhaseM RC l ()
setAttr sd attr  = do
    phaseLog "rg" $ "Setting disk attribute " ++ show attr ++ " on " ++ show sd
    modifyGraph $ G.connect sd R.Has attr

-- | Unset an attribute on a storage device.
unsetAttr :: StorageDevice -> StorageDeviceAttr -> PhaseM RC l ()
unsetAttr sd attr = do
    phaseLog "rg" $ "Unsetting disk attribute "
                  ++ show attr ++ " on " ++ show sd
    modifyGraph (G.disconnect sd R.Has attr)

-- | Find attributes matching the given filter on a storage device.
findAttrs :: (StorageDeviceAttr -> Bool)
                       -> StorageDevice
                       -> PhaseM RC l [StorageDeviceAttr]
findAttrs k sdev = do
    rg <- getLocalGraph
    return [ attr | attr <- G.connectedTo sdev R.Has rg :: [StorageDeviceAttr]
                  , k attr
                  ]

-- | Lookup filesystem paths for storage devices (e.g. /dev/sda1)
path :: StorageDevice -> PhaseM RC l (Maybe String)
path sd =
    listToMaybe . mapMaybe extractPath <$> getIdentifiers sd
  where
    extractPath (DIPath x) = Just x
    extractPath _ = Nothing

setPath :: StorageDevice -> String -> PhaseM RC l ()
setPath sd path' = do
   old <- mapMaybe extractPath <$> getIdentifiers sd
   for_ old $ \o -> modifyGraph $ G.disconnect sd R.Has o
   modifyGraph $ G.connect sd R.Has (DIPath path')
  where
    extractPath x@DIPath{} = Just x
    extractPath _ = Nothing
   

-- setPath :: StorageDevice -> String -> PhaseM RC l ()
-- setPath =
  
getIdentifiers :: StorageDevice
               -> PhaseM RC l [DeviceIdentifier]
getIdentifiers sd = G.connectedTo sd R.Has <$> getLocalGraph

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