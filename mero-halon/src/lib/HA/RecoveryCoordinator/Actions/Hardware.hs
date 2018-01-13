{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Actions on hardware entities.
module HA.RecoveryCoordinator.Actions.Hardware
  ( -- * Infrastructure functions
    registerRack
  , registerEnclosure
  , registerBMC
  , findBMCAddress
    -- * Host related functions
  , findHosts
  , findHostEnclosure
  , findNodeHost
  , locateHostInEnclosure
  , locateNodeOnHost
  , registerHost
  , registerOnCluster
  , nodesOnHost
  , hasHostAttr
  , setHostAttr
  , unsetHostAttr
  , findHostsByAttributeFilter
  , findHostsByAttr
  , findHostAttrs
    -- * Drive related functions
    -- ** Searching devices
  , findHostStorageDevices
  , lookupStorageDevicesWithDI
  , lookupStorageDevicesWithAttr
    -- ** Querying device properties
  , getSDevNode
  , getSDevHost
    --- *** Reset
  , markOnGoingReset
  , markResetComplete
  , hasOngoingReset
  , getDiskResetAttempts
  , incrDiskResetAttempts
    --- *** Power
  , isStorageDriveRemoved
) where

import           Data.Maybe (listToMaybe, maybeToList)
import qualified HA.RecoveryCoordinator.Hardware.StorageDevice.Actions as SDev
import           HA.RecoveryCoordinator.RC.Actions
import           HA.RecoveryCoordinator.RC.Actions.Log (actLog)
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..), Has(..), Node_XXX2, Runs(..))
import qualified HA.Resources.Castor as Cas
import           HA.Services.Ekg.RC
import           Network.CEP
import           Text.Regex.TDFA ((=~))

-- | Register a new rack in the system.
registerRack :: Cas.Rack -> PhaseM RC l ()
registerRack rack = do
    actLog "registerRack" [("rack", show rack)]
    modifyGraph $ G.connect Cluster Has rack

-- | 'G.connect' the given 'Enclosure' to the 'Rack'.
registerEnclosure :: Cas.Rack -> Cas.Enclosure -> PhaseM RC l ()
registerEnclosure rack enc = do
  actLog "registerEnclosure" [("rack", show rack), ("enclosure", show enc)]
  modifyGraph $ G.connect rack Has enc

-- | 'G.connect' the givne 'BMC' to the 'Enclosure'.
registerBMC :: Cas.Enclosure -> Cas.BMC -> PhaseM RC l ()
registerBMC enc bmc = do
  actLog "registerBMC" [("bmc", show bmc), ("enclosure", show enc)]
  modifyGraph $ G.connect enc Has bmc

-- | Find the IP address of the BMC corresponding to this host.
findBMCAddress :: Cas.Host -> PhaseM RC l (Maybe String)
findBMCAddress host = do
    g <- getLocalGraph
    return . listToMaybe $
      [ Cas.bmc_addr bmc
      | Just (enc :: Cas.Enclosure) <- [G.connectedFrom Has host g]
      , bmc <- G.connectedTo enc Has g
      ]

----------------------------------------------------------
-- Host related functions                               --
----------------------------------------------------------

-- | Find the host running the given node
findNodeHost :: Node_XXX2 -> PhaseM RC l (Maybe Cas.Host)
findNodeHost node = G.connectedFrom Runs node <$> getLocalGraph

-- | Find the enclosure containing the given host.
findHostEnclosure :: Cas.Host -> PhaseM RC l (Maybe Cas.Enclosure)
findHostEnclosure host = G.connectedFrom Has host <$> getLocalGraph

-- | Find a list of all hosts in the system matching a given
--   regular expression.
findHosts :: String -> PhaseM RC l [Cas.Host]
findHosts regex = do
  g <- getLocalGraph
  return $ [ host | host@(Cas.Host hn) <- G.connectedTo Cluster Has g
                  , hn =~ regex]

-- | Find all nodes running on the given host.
nodesOnHost :: Cas.Host -> PhaseM RC l [Node_XXX2]
nodesOnHost host = fmap (G.connectedTo host Runs) getLocalGraph

-- | Register a new host in the system.
registerHost :: Cas.Host -> PhaseM RC l ()
registerHost host = registerOnCluster host $ "Registering host on cluster: " ++ show host

-- | Register a new thing on 'Cluster' as long as it has a 'Has'
-- 'G.Relation' instance. Does nothing if the resource is already
-- connected.
registerOnCluster :: G.Relation Has Cluster a
                  => a -- ^ The thing to register
                  -> String -- ^ The message to log
                  -> PhaseM RC l ()
registerOnCluster x m = modifyLocalGraph $ \rg ->
  if G.isConnected Cluster Has x rg
  then return rg
  else do
    Log.rcLog' Log.TRACE m
    return $! G.connect Cluster Has x rg

-- | Record that a host is running in an enclosure.
locateHostInEnclosure :: Cas.Host -> Cas.Enclosure -> PhaseM RC l ()
locateHostInEnclosure host enc = do
  actLog "locateHostInEnclosure" [("host", show host), ("enclosure", show enc)]
  modifyGraph $ G.connect enc Has host

-- | Record that a node is running on a host. Does not re-connect if
-- the 'Node' is already connected to the given 'Host'.
locateNodeOnHost :: Node_XXX2 -> Cas.Host -> PhaseM RC l ()
locateNodeOnHost node host = modifyLocalGraph $ \rg ->
  if G.isConnected host Runs node rg
  then return rg
  else do
    actLog "locateHostInEnclosure" [("host", show host), ("node", show node)]
    return $ G.connect host Runs node rg

----------------------------------------------------------
-- Host attribute functions                             --
----------------------------------------------------------

-- | Test if a host has the specified attribute.
hasHostAttr :: Cas.HostAttr -> Cas.Host -> PhaseM RC l Bool
hasHostAttr a h = G.isConnected h Has a <$> getLocalGraph

-- | Set an attribute on a host. Note that this will not replace
--   any existing attributes - that must be done manually.
setHostAttr :: Cas.Host -> Cas.HostAttr -> PhaseM RC l ()
setHostAttr h a = do
  actLog "setHostAttr" [("host", show h), ("attr", show a)]
  modifyGraph $ G.connect h Has a

-- | Remove the given 'HostAttr' from the 'Host'.
unsetHostAttr :: Cas.Host -> Cas.HostAttr -> PhaseM RC l ()
unsetHostAttr h a = do
  actLog "unsetHostAttr" [("host", show h), ("attr", show a)]
  modifyGraph $ G.disconnect h Has a

-- | Find hosts with attributes satisfying the user supplied predicate
findHostsByAttributeFilter :: String -- ^ Message to log
                           -> ([Cas.HostAttr] -> Bool) -- ^ Filter predicate
                           -> PhaseM RC l [Cas.Host]
findHostsByAttributeFilter msg p = do
  Log.rcLog' Log.TRACE msg
  g <- getLocalGraph
  return $ [ host | host@(Cas.Host {}) <- G.connectedTo Cluster Has g
                  , p (G.connectedTo host Has g) ]

-- | A specialised version of 'findHostsByAttributeFilter' that returns all
-- hosts labelled with at least the given attribute.
findHostsByAttr :: Cas.HostAttr -> PhaseM RC l [Cas.Host]
findHostsByAttr a =
    findHostsByAttributeFilter ("Looking for hosts with attribute " ++ show a)
        (elem a)

-- | Find all attributes possessed by the given host.
findHostAttrs :: Cas.Host -> PhaseM RC l [Cas.HostAttr]
findHostAttrs h = G.connectedTo h Has <$> getLocalGraph

----------------------------------------------------------
-- Drive related functions                              --
----------------------------------------------------------

-- | Find logical devices on a host
findHostStorageDevices :: Cas.Host -> PhaseM RC l [Cas.StorageDevice]
findHostStorageDevices h = flip fmap getLocalGraph $ \rg ->
  [ sdev | enc  :: Cas.Enclosure <- maybeToList $ G.connectedFrom Has h rg
         , loc  :: Cas.Slot <- G.connectedTo enc Has rg
         , sdev :: Cas.StorageDevice <- maybeToList $ G.connectedFrom Has loc rg ]

-- | Check if the 'StorageDevice' is still attached (from halon
-- perspective).
isStorageDriveRemoved :: Cas.StorageDevice -> PhaseM RC l Bool
isStorageDriveRemoved sd = do
  rg <- getLocalGraph
  return . maybe True (\Cas.Slot{} -> False) $ G.connectedTo sd Has rg

-- | Find all 'StorageDevice's with the given 'DeviceIdentifier'.
lookupStorageDevicesWithDI :: Cas.DeviceIdentifier -> PhaseM RC l [Cas.StorageDevice]
lookupStorageDevicesWithDI di = G.connectedFrom Has di <$> getLocalGraph

-- | Find all 'StorageDevice's with the given 'StorageDeviceAttr'.
lookupStorageDevicesWithAttr :: Cas.StorageDeviceAttr -> PhaseM RC l [Cas.StorageDevice]
lookupStorageDevicesWithAttr attr = G.connectedFrom Has attr <$> getLocalGraph

-- | Update a metric monitoring how many drives are currently
-- undergoing reset. Note that increasing when we start reset and
-- decreasing when we stop reset can provide bad results: consider
-- what happens if we start EKG service half way through a rule doing
-- the marking. We will decrease but haven't increased and we end up
-- with reported data being wrong.
updateDiskResetCount :: PhaseM RC l ()
updateDiskResetCount = do
  i <- fromIntegral . length <$> lookupStorageDevicesWithAttr Cas.SDOnGoingReset
  runEkgMetricCmd (ModifyGauge "ongoing_disk_resets" $ GaugeSet i)

-- | Test whether a given device is currently undergoing a reset operation.
hasOngoingReset :: Cas.StorageDevice -> PhaseM RC l Bool
hasOngoingReset =
    let go Cas.SDOnGoingReset = True
        go _                  = False
    in fmap (not . null) . SDev.findAttrs go

-- | Mark that a storage device is undergoing reset.
markOnGoingReset :: Cas.StorageDevice -> PhaseM RC l ()
markOnGoingReset sdev = do
    let _F Cas.SDOnGoingReset = True
        _F _                  = False
    m <- listToMaybe <$> SDev.findAttrs _F sdev
    case m of
      Nothing -> do
        SDev.setAttr sdev Cas.SDOnGoingReset
        updateDiskResetCount
      _       -> return ()

-- | Mark that a storage device has completed reset.
markResetComplete :: Cas.StorageDevice -> PhaseM RC l ()
markResetComplete sdev = do
    let _F Cas.SDOnGoingReset = True
        _F _                  = False
    m <- listToMaybe <$> SDev.findAttrs _F sdev
    case m of
      Nothing  -> return ()
      Just old -> do
        SDev.unsetAttr sdev old
        updateDiskResetCount

-- | Increment the number of disk reset attempts the 'StorageDevice'
-- has gone through.
incrDiskResetAttempts :: Cas.StorageDevice -> PhaseM RC l ()
incrDiskResetAttempts sdev = do
    let _F (Cas.SDResetAttempts _) = True
        _F _                       = False
    m <- listToMaybe <$> SDev.findAttrs _F sdev
    case m of
      Just old@(Cas.SDResetAttempts i) -> do
        SDev.unsetAttr sdev old
        SDev.setAttr sdev (Cas.SDResetAttempts (i+1))
      _ -> SDev.setAttr sdev (Cas.SDResetAttempts 1)

-- | Number of times the given 'StorageDevice' has been tried to
-- reset.
getDiskResetAttempts :: Cas.StorageDevice -> PhaseM RC l Int
getDiskResetAttempts sdev = do
    let _F (Cas.SDResetAttempts _) = True
        _F _                       = False
    m <- listToMaybe <$> SDev.findAttrs _F sdev
    return $ case m of
        Just (Cas.SDResetAttempts i) -> i
        _                            -> 0

-- | Find 'Node's that are in the same 'Enclosure' as the given
-- 'StorageDevice'.
--
-- TODO: Should be @'Maybe' 'Node'@.
-- TODO: Is this function and are uses of this function correct?
-- TODO: Same questions for 'getSDevHost'
getSDevNode :: Cas.StorageDevice -> PhaseM RC l [Node_XXX2]
getSDevNode sdev = do
  rg <- getLocalGraph
  hosts <- getSDevHost sdev
  return [ node | host <- hosts
                , node <- G.connectedTo host Runs rg ]

-- | Find 'Host's that are in the same 'Enclosure' as the given
-- 'StorageDevice'.
--
-- TODO: See 'getSDevNode' TODOs.
getSDevHost :: Cas.StorageDevice -> PhaseM RC l [Cas.Host]
getSDevHost sdev = do
  rg <- getLocalGraph
  maybe [] (\enc -> G.connectedTo enc Has rg) <$> SDev.enclosure sdev
