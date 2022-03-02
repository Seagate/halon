{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright : (C) 2015-2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Actions on hardware entities.
module HA.RecoveryCoordinator.Actions.Hardware
  ( -- * Infrastructure functions
    registerSite
  , registerRack
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
import           HA.Resources
import           HA.Resources.Castor
import           HA.Services.Ekg.RC
import           Network.CEP
import           Text.Regex.TDFA ((=~))

-- | Register a new site in the system.
registerSite :: Site
             -> PhaseM RC l ()
registerSite site = do
  actLog "registerSite" [("site", show site)]
  modifyGraph $ G.connect Cluster Has site

-- | 'G.connect' the given 'Rack' to the 'Site'.
registerRack :: Site
             -> Rack
             -> PhaseM RC l ()
registerRack site rack = do
  actLog "registerRack" [("site", show site), ("rack", show rack)]
  modifyGraph $ G.connect site Has rack

-- | 'G.connect' the given 'Enclosure' to the 'Rack'.
registerEnclosure :: Rack
                  -> Enclosure
                  -> PhaseM RC l ()
registerEnclosure rack enc = do
  actLog "registerEnclosure" [("rack", show rack), ("enclosure", show enc)]
  modifyGraph $ G.connect rack Has enc

-- | 'G.connect' the givne 'BMC' to the 'Enclosure'.
registerBMC :: Enclosure
            -> BMC
            -> PhaseM RC l ()
registerBMC enc bmc = do
  actLog "registerBMC" [("bmc", show bmc), ("enclosure", show enc)]
  modifyGraph $ G.connect enc Has bmc

-- | Find the IP address of the BMC corresponding to this host.
findBMCAddress :: Host
               -> PhaseM RC l (Maybe String)
findBMCAddress host = do
    rg <- getGraph
    return . listToMaybe $
      [ bmc_addr bmc
      | Just (enc :: Enclosure) <- [G.connectedFrom Has host rg]
      , bmc <- G.connectedTo enc Has rg
      ]

----------------------------------------------------------
-- Host related functions                               --
----------------------------------------------------------

-- | Find the host running the given node
findNodeHost :: Node
             -> PhaseM RC l (Maybe Host)
findNodeHost node = G.connectedFrom Runs node <$> getGraph

-- | Find the enclosure containing the given host.
findHostEnclosure :: Host
                  -> PhaseM RC l (Maybe Enclosure)
findHostEnclosure host =
    G.connectedFrom Has host <$> getGraph

-- | Find a list of all hosts in the system matching a given
--   regular expression.
findHosts :: String
          -> PhaseM RC l [Host]
findHosts regex = do
  rg <- getGraph
  return $ [ host | host@(Host hn) <- G.connectedTo Cluster Has rg
                  , hn =~ regex]

-- | Find all nodes running on the given host.
nodesOnHost :: Host
            -> PhaseM RC l [Node]
nodesOnHost host = do
  fmap (G.connectedTo host Runs) getGraph

-- | Register a new host in the system.
registerHost :: Host
             -> PhaseM RC l ()
registerHost host = registerOnCluster host $ "Registering host on cluster: " ++ show host

-- | Register a new thing on 'Cluster' as long as it has a 'Has'
-- 'G.Relation' instance. Does nothing if the resource is already
-- connected.
registerOnCluster :: G.Relation Has Cluster a
                  => a -- ^ The thing to register
                  -> String -- ^ The message to log
                  -> PhaseM RC l ()
registerOnCluster x m = modifyGraphM $ \rg ->
  if G.isConnected Cluster Has x rg
  then return rg
  else do
    Log.rcLog' Log.TRACE m
    return $! G.connect Cluster Has x rg

-- | Record that a host is running in an enclosure.
locateHostInEnclosure :: Host
                      -> Enclosure
                      -> PhaseM RC l ()
locateHostInEnclosure host enc = do
  actLog "locateHostInEnclosure" [("host", show host), ("enclosure", show enc)]
  modifyGraph $ G.connect enc Has host

-- | Record that a node is running on a host. Does not re-connect if
-- the 'Node' is already connected to the given 'Host'.
locateNodeOnHost :: Node
                 -> Host
                 -> PhaseM RC l ()
locateNodeOnHost node host = modifyGraphM $ \rg ->
  if G.isConnected host Runs node rg
  then return rg
  else do
    actLog "locateHostInEnclosure" [("host", show host), ("node", show node)]
    return $ G.connect host Runs node rg

----------------------------------------------------------
-- Host attribute functions                             --
----------------------------------------------------------

-- | Test if a host has the specified attribute.
hasHostAttr :: HostAttr
            -> Host
            -> PhaseM RC l Bool
hasHostAttr f h = do
  rg <- getGraph
  return $ G.isConnected h Has f rg

-- | Set an attribute on a host. Note that this will not replace
--   any existing attributes - that must be done manually.
setHostAttr :: Host
            -> HostAttr
            -> PhaseM RC l ()
setHostAttr h f = do
  actLog "setHostAttr" [("host", show h), ("attr", show f)]
  modifyGraph $ G.connect h Has f

-- | Remove the given 'HostAttr' from the 'Host'.
unsetHostAttr :: Host
              -> HostAttr
              -> PhaseM RC l ()
unsetHostAttr h f = do
  actLog "unsetHostAttr" [("host", show h), ("attr", show f)]
  modifyGraph $ G.disconnect h Has f

-- | Find hosts with attributes satisfying the user supplied predicate
findHostsByAttributeFilter :: String -- ^ Message to log
                           -> ([HostAttr] -> Bool) -- ^ Filter predicate
                           -> PhaseM RC l [Host]
findHostsByAttributeFilter msg p = do
  Log.rcLog' Log.TRACE msg
  rg <- getGraph
  return $ [ host | host@(Host {}) <- G.connectedTo Cluster Has rg
                  , p (G.connectedTo host Has rg) ]

-- | A specialised version of 'findHostsByAttributeFilter' that returns all
-- hosts labelled with at least the given attribute.
findHostsByAttr :: HostAttr
                -> PhaseM RC l [Host]
findHostsByAttr label =
    findHostsByAttributeFilter ( "Looking for hosts with attribute "
                                ++ show label) p
  where
    p = elem label

-- | Find all attributes possessed by the given host.
findHostAttrs :: Host -> PhaseM RC l [HostAttr]
findHostAttrs host = G.connectedTo host Has <$> getGraph

----------------------------------------------------------
-- Drive related functions                              --
----------------------------------------------------------

-- | Find logical devices on a host
findHostStorageDevices :: Host
                       -> PhaseM RC l [StorageDevice]
findHostStorageDevices host = flip fmap getGraph $ \rg ->
  [ sdev | enc  :: Enclosure <- maybeToList $ G.connectedFrom Has host rg
         , loc  :: Slot <- G.connectedTo enc Has rg
         , sdev :: StorageDevice <- maybeToList $ G.connectedFrom Has loc rg ]

-- | Check if the 'StorageDevice' is still attached (from halon
-- perspective).
isStorageDriveRemoved :: StorageDevice -> PhaseM RC l Bool
isStorageDriveRemoved sd = do
  rg <- getGraph
  return . maybe True (\Slot{} -> False) $ G.connectedTo sd Has rg

-- | Find all 'StorageDevice's with the given 'DeviceIdentifier'.
lookupStorageDevicesWithDI :: DeviceIdentifier -> PhaseM RC l [StorageDevice]
lookupStorageDevicesWithDI di = G.connectedFrom Has di <$> getGraph

-- | Find all 'StorageDevice's with the given 'StorageDeviceAttr'.
lookupStorageDevicesWithAttr :: StorageDeviceAttr -> PhaseM RC l [StorageDevice]
lookupStorageDevicesWithAttr attr = G.connectedFrom Has attr <$> getGraph

-- | Update a metric monitoring how many drives are currently
-- undergoing reset. Note that increasing when we start reset and
-- decreasing when we stop reset can provide bad results: consider
-- what happens if we start EKG service half way through a rule doing
-- the marking. We will decrease but haven't increased and we end up
-- with reported data being wrong.
updateDiskResetCount :: PhaseM RC l ()
updateDiskResetCount = do
  i <- fromIntegral . length <$> lookupStorageDevicesWithAttr SDOnGoingReset
  runEkgMetricCmd (ModifyGauge "ongoing_disk_resets" $ GaugeSet i)

-- | Test whether a given device is currently undergoing a reset operation.
hasOngoingReset :: StorageDevice -> PhaseM RC l Bool
hasOngoingReset =
    fmap (not . null) . SDev.findAttrs go
  where
    go SDOnGoingReset = True
    go _              = False

-- | Mark that a storage device is undergoing reset.
markOnGoingReset :: StorageDevice -> PhaseM RC l ()
markOnGoingReset sdev = do
    let _F SDOnGoingReset = True
        _F _              = False
    m <- listToMaybe <$> SDev.findAttrs _F sdev
    case m of
      Nothing -> do
        SDev.setAttr sdev SDOnGoingReset
        updateDiskResetCount
      _       -> return ()

-- | Mark that a storage device has completed reset.
markResetComplete :: StorageDevice -> PhaseM RC l ()
markResetComplete sdev = do
    let _F SDOnGoingReset = True
        _F _              = False
    m <- listToMaybe <$> SDev.findAttrs _F sdev
    case m of
      Nothing  -> return ()
      Just old -> do
        SDev.unsetAttr sdev old
        updateDiskResetCount

-- | Increment the number of disk reset attempts the 'StorageDevice'
-- has gone through.
incrDiskResetAttempts :: StorageDevice -> PhaseM RC l ()
incrDiskResetAttempts sdev = do
    let _F (SDResetAttempts _) = True
        _F _                   = False
    m <- listToMaybe <$> SDev.findAttrs _F sdev
    case m of
      Just old@(SDResetAttempts i) -> do
        SDev.unsetAttr sdev old
        SDev.setAttr sdev (SDResetAttempts (i+1))
      _ -> SDev.setAttr sdev (SDResetAttempts 1)

-- | Number of times the given 'StorageDevice' has been tried to
-- reset.
getDiskResetAttempts :: StorageDevice -> PhaseM RC l Int
getDiskResetAttempts sdev = do
  let _F (SDResetAttempts _) = True
      _F _                   = False
  m <- listToMaybe <$> SDev.findAttrs _F sdev
  case m of
    Just (SDResetAttempts i) -> return i
    _                        -> return 0

-- | Find 'Node's that are in the same 'Enclosure' as the given
-- 'StorageDevice'.
--
-- TODO: Should be @'Maybe' 'Node'@.
-- TODO: Is this function and are uses of this function correct?
-- TODO: Same questions for 'getSDevHost'
getSDevNode :: StorageDevice -> PhaseM RC l [Node]
getSDevNode sdev = do
  rg <- getGraph
  hosts <- getSDevHost sdev
  return [ node | host <- hosts
                , node <- G.connectedTo host Runs rg ]

-- | Find 'Host's that are in the same 'Enclosure' as the given
-- 'StorageDevice'.
--
-- TODO: See 'getSDevNode' TODOs.
getSDevHost :: StorageDevice -> PhaseM RC l [Host]
getSDevHost sdev = do
  rg <- getGraph
  maybe [] (\enc -> G.connectedTo enc Has rg) <$> SDev.enclosure sdev
