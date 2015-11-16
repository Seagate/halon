-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE OverloadedStrings          #-}

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
    -- * Interface related functions
  , registerInterface
    -- * Drive related functions
  , driveStatus
  , findEnclosureStorageDevices
  , findHostStorageDevices
  , findStorageDeviceIdentifiers
  , hasStorageDeviceIdentifier
  , identifyStorageDevice
  , lookupStorageDevicePaths
  , locateStorageDeviceInEnclosure
  , locateStorageDeviceOnHost
  , mergeStorageDevices
  , updateDriveStatus
  , incrDiskPowerOnAttempts
  , incrDiskPowerOffAttempts
  , incrDiskResetAttempts
  , markDiskPowerOn
  , markSMARTTestIsRunning
  , getDiskResetAttempts
  , markDiskPowerOff
  , markSMARTTestComplete
  , hasOngoingReset
  , markOnGoingReset
  , markResetComplete
) where

import HA.RecoveryCoordinator.Actions.Core
import qualified HA.ResourceGraph as G
import HA.Resources
import HA.Resources.Castor

import Control.Category ((>>>))
import Control.Distributed.Process (liftIO)

import Data.Maybe (catMaybes, listToMaybe)
import Data.UUID.V4 (nextRandom)

import Network.CEP

import Text.Regex.TDFA ((=~))

-- | Register a new rack in the system.
registerRack :: Rack
             -> PhaseM LoopState l ()
registerRack rack = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ "Registering rack: "
              ++ show rack

  let rg' = G.newResource rack
        >>> G.connect Cluster Has rack
          $ rg
  return rg'

registerEnclosure :: Rack
                  -> Enclosure
                  -> PhaseM LoopState l ()
registerEnclosure rack enc = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ unwords
                  [ "Registering enclosure", show enc
                  , "in rack", show rack
                  ]
  return  $ G.newResource enc
        >>> G.connect rack Has enc
          $ rg

registerBMC :: Enclosure
            -> BMC
            -> PhaseM LoopState l ()
registerBMC enc bmc = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ unwords
                  [ "Registering BMC", show bmc
                  , "for enclosure", show enc
                  ]

  let rg' = G.newResource bmc
        >>> G.connect enc Has bmc
          $ rg
  return rg'

-- | Find the IP address of the BMC corresponding to this host.
findBMCAddress :: Host
               -> PhaseM LoopState l (Maybe String)
findBMCAddress host = do
    phaseLog "rg-query" $ "Getting BMC address for host " ++ show host
    g <- getLocalGraph
    return . listToMaybe $
      [ bmc_addr bmc
      | (enc :: Enclosure) <- G.connectedFrom Has host g
      , bmc <- G.connectedTo enc Has g
      ]

----------------------------------------------------------
-- Host related functions                               --
----------------------------------------------------------

-- | Find the host running the given node
findNodeHost :: Node
             -> PhaseM LoopState l (Maybe Host)
findNodeHost node =  do
  phaseLog "rg-query" $ "Looking for host running " ++ show node
  g <- getLocalGraph
  return $ case G.connectedFrom Runs node g of
    [h] -> Just h
    _ -> Nothing

-- | Find the enclosure containing the given host.
findHostEnclosure :: Host
                  -> PhaseM LoopState l (Maybe Enclosure)
findHostEnclosure host = do
  phaseLog "rg-query" $ "Looking for enclosure containing " ++ show host
  g <- getLocalGraph
  return $ case G.connectedFrom Has host g of
    [h] -> Just h
    _ -> Nothing

-- | Find a list of all hosts in the system matching a given
--   regular expression.
findHosts :: String
          -> PhaseM LoopState l [Host]
findHosts regex = do
  phaseLog "rg-query" $ "Looking for hosts matching regex " ++ regex
  g <- getLocalGraph
  return $ [ host | host@(Host hn) <- G.connectedTo Cluster Has g
                  , hn =~ regex]

-- | Find all nodes running on the given host.
nodesOnHost :: Host
            -> PhaseM LoopState l [Node]
nodesOnHost host = do
  phaseLog "rg-query" $ "Looking for nodes on host " ++ show host
  fmap (G.connectedTo host Runs) getLocalGraph

-- | Register a new host in the system.
registerHost :: Host
             -> PhaseM LoopState l ()
registerHost host = registerOnCluster host $ "Registering host: " ++ show host

-- | Register a new thing on 'Cluster' as long as it has a 'Has'
-- 'G.Relation' instance.
registerOnCluster :: G.Relation Has Cluster a
                  => a -- ^ The thing to register
                  -> String -- ^ The message to log
                  -> PhaseM LoopState l ()
registerOnCluster x m = modifyLocalGraph $ \rg -> do
  phaseLog "rg" m
  let rg' = G.newResource x
        >>> G.connect Cluster Has x
          $ rg
  return rg'

-- | Record that a host is running in an enclosure.
locateHostInEnclosure :: Host
                      -> Enclosure
                      -> PhaseM LoopState l ()
locateHostInEnclosure host enc = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ "Locating host "
              ++ show host
              ++ " in enclosure "
              ++ show enc

  return $ G.connect enc Has host rg

-- | Record that a node is running on a host.
locateNodeOnHost :: Node
                 -> Host
                 -> PhaseM LoopState l ()
locateNodeOnHost node host = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ "Locating node " ++ (show node) ++ " on host "
              ++ show host

  return $ G.connect host Runs node rg

----------------------------------------------------------
-- Host attribute functions                             --
----------------------------------------------------------

-- | Test if a host has the specified attribute.
hasHostAttr :: HostAttr
            -> Host
            -> PhaseM LoopState l Bool
hasHostAttr f h = do
  phaseLog "rg-query" $ "Checking host "
                      ++ show h
                      ++ " for attribute "
                      ++ show f
  g <- getLocalGraph
  return $ G.isConnected h Has f g

-- | Set an attribute on a host. Note that this will not replace
--   any existing attributes - that must be done manually.
setHostAttr :: Host
            -> HostAttr
            -> PhaseM LoopState l ()
setHostAttr h f = do
  phaseLog "rg" $ unwords [ "Setting attribute", show f
                , "on host", show h ]
  modifyLocalGraph
      $ return
      . (G.newResource f
    >>> G.connect h Has f)

unsetHostAttr :: Host
              -> HostAttr
              -> PhaseM LoopState l ()
unsetHostAttr h f = do
  phaseLog "rg" $ unwords [ "Unsetting attribute", show f
                          , "on host", show h ]
  modifyLocalGraph
    $ return
    . G.disconnect h Has f

-- | Find hosts with attributes satisfying the user supplied predicate
findHostsByAttributeFilter :: String -- ^ Message to log
                           -> ([HostAttr] -> Bool) -- ^ Filter predicate
                           -> PhaseM LoopState l [Host]
findHostsByAttributeFilter msg p = do
  phaseLog "rg-query" msg
  g <- getLocalGraph
  return $ [ host | host@(Host {}) <- G.connectedTo Cluster Has g
                  , p (G.connectedTo host Has g) ]

-- | A specialised version of 'findHostsByAttributeFilter' that returns all
-- hosts labelled with at least the given attribute.
findHostsByAttr :: HostAttr
                -> PhaseM LoopState l [Host]
findHostsByAttr label =
    findHostsByAttributeFilter ( "Looking for hosts with attribute "
                                ++ show label) p
  where
    p = elem label

-- | Find all attributes possessed by the given host.
findHostAttrs :: Host
              -> PhaseM LoopState l [HostAttr]
findHostAttrs host = do
  phaseLog "rg-query" $ "Getting attributes for host " ++ show host
  g <- getLocalGraph
  return $ G.connectedTo host Has g

----------------------------------------------------------
-- Interface related functions                          --
----------------------------------------------------------

-- | Register an interface on a host.
registerInterface :: Host -- ^ Host on which the interface resides.
                  -> Interface
                  -> PhaseM LoopState l ()
registerInterface host int = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ "Registering interface on host " ++ show host

  let rg' = G.newResource host
        >>> G.newResource int
        >>> G.connect host Has int
          $ rg
  return rg'

----------------------------------------------------------
-- Drive related functions                              --
----------------------------------------------------------

-- | Find logical devices on a host
findHostStorageDevices :: Host
                       -> PhaseM LoopState l [StorageDevice]
findHostStorageDevices host = do
  phaseLog "rg-query" $ "Looking for storage devices on host "
                    ++ show host
  fmap (G.connectedTo host Has) getLocalGraph

-- | Find physical devices in an enclosure
findEnclosureStorageDevices :: Enclosure
                            -> PhaseM LoopState l [StorageDevice]
findEnclosureStorageDevices enc = do
  phaseLog "rg-query" $ "Looking for storage devices in enclosure "
                    ++ show enc
  fmap (G.connectedTo enc Has) getLocalGraph

-- | Find additional identifiers for a (physical) storage device.
findStorageDeviceIdentifiers :: StorageDevice
                             -> PhaseM LoopState l [DeviceIdentifier]
findStorageDeviceIdentifiers sd = do
  phaseLog "rg-query" $ "Looking for identifiers for physical device "
                    ++ show sd
  fmap (G.connectedTo sd Has) getLocalGraph

-- | Test if a drive have a given identifier
hasStorageDeviceIdentifier :: StorageDevice
                           -> DeviceIdentifier
                           -> PhaseM LoopState l Bool
hasStorageDeviceIdentifier ld di = do
  ids <- findStorageDeviceIdentifiers ld
  return $ elem di ids

-- | Add an additional identifier to a logical storage device.
identifyStorageDevice :: StorageDevice
                      -> DeviceIdentifier
                      -> PhaseM LoopState l ()
identifyStorageDevice ld di = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ "Adding identifier "
              ++ show di
              ++ " to device "
              ++ show ld

  let rg' = G.newResource ld
        >>> G.newResource di
        >>> G.connect ld Has di
          $ rg

  return rg'

-- | Lookup filesystem
lookupStorageDevicePaths :: StorageDevice -> PhaseM LoopState l [String]
lookupStorageDevicePaths sd =
  catMaybes . map extractPath <$> findStorageDeviceIdentifiers sd
  where
    extractPath (DIPath x) = Just x
    extractPath _ = Nothing

-- | Register a new drive in the system.
locateStorageDeviceInEnclosure :: Enclosure
                                -> StorageDevice
                                -> PhaseM LoopState l ()
locateStorageDeviceInEnclosure enc dev = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ "Registering storage device: "
              ++ show dev
              ++ " in enclosure "
              ++ show enc

  let rg' = G.newResource enc
        >>> G.newResource dev
        >>> G.connect Cluster Has enc
        >>> G.connect enc Has dev
          $ rg

  return rg'

-- | Register a new drive in the system.
locateStorageDeviceOnHost :: Host
                          -> StorageDevice
                          -> PhaseM LoopState l ()
locateStorageDeviceOnHost host dev = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ "Registering storage device: "
              ++ show dev
              ++ " on host "
              ++ show host

  let rg' = G.newResource host
        >>> G.newResource dev
        >>> G.connect Cluster Has host
        >>> G.connect host Has dev
          $ rg

  return rg'

-- | Merge multiple storage devices into one.
--   Returns the new (merged) device.
mergeStorageDevices :: [StorageDevice]
                    -> PhaseM LoopState l StorageDevice
mergeStorageDevices sds = do
  phaseLog "rg" $ "Merging multiple storage devices: "
              ++ (show sds)
  rg <- getLocalGraph
  newUUID <- liftProcess . liftIO $ nextRandom
  let newDisk = StorageDevice newUUID
      rg' = G.mergeResources (\_ -> newDisk) sds
          $ rg
  putLocalGraph rg'
  return newDisk

-- | Get the status of a storage device.
driveStatus :: StorageDevice
            -> PhaseM LoopState l (Maybe StorageDeviceStatus)
driveStatus dev = do
  phaseLog "rg-query" $ "Querying status of device " ++ show dev
  rg <- getLocalGraph
  return $ case G.connectedTo dev Is rg of
    [a] -> Just a
    _ -> Nothing

-- | Update the status of a storage device.
updateDriveStatus :: StorageDevice
                  -> String
                  -> PhaseM LoopState l ()
updateDriveStatus dev status = modifyLocalGraph $ \rg -> do
  phaseLog "rg" $ "Updating status for device " ++ show dev ++ " to " ++ status
  ds <- driveStatus dev
  phaseLog "rg" $ "Old status was " ++ show ds
  let statusNode = StorageDeviceStatus status
      removeOldNode = case ds of
        Just f -> G.disconnect dev Is f
        Nothing -> id
      rg' = G.newResource statusNode
        >>> G.connect dev Is statusNode
        >>> removeOldNode
          $ rg
  return rg'

setStorageDeviceAttr :: StorageDevice -> StorageDeviceAttr -> PhaseM LoopState l ()
setStorageDeviceAttr sd attr  = do
    phaseLog "rg" $ "Setting disk attribute " ++ show attr ++ " on " ++ show sd
    modifyGraph (G.newResource attr >>> G.connect sd Has attr)

unsetStorageDeviceAttr :: StorageDevice -> StorageDeviceAttr -> PhaseM LoopState l ()
unsetStorageDeviceAttr sd attr = do
    phaseLog "rg" $ "Unsetting disk attribute "
                  ++ show attr ++ " on " ++ show sd
    modifyGraph (G.disconnect sd Has attr)

findStorageDeviceAttr :: (StorageDeviceAttr -> Bool)
             -> StorageDevice
             -> PhaseM LoopState l (Maybe StorageDeviceAttr)
findStorageDeviceAttr k sdev = do
    rg <- getLocalGraph
    let attrs =
          [ attr | attr <- G.connectedTo sdev Has rg :: [StorageDeviceAttr]
                 , k attr
                 ]
    return $ listToMaybe attrs

hasOngoingReset :: StorageDevice -> PhaseM LoopState l Bool
hasOngoingReset =
    fmap (maybe False (const True)) . findStorageDeviceAttr go
  where
    go SDOnGoingReset = True
    go _              = False


incrDiskPowerOnAttempts :: StorageDevice -> PhaseM LoopState l ()
incrDiskPowerOnAttempts sdev = do
    let _F (SDPowerOnAttempts _) = True
        _F _                     = False
    m <- findStorageDeviceAttr _F sdev
    case m of
      Just old@(SDPowerOnAttempts i) -> do
        unsetStorageDeviceAttr sdev old
        setStorageDeviceAttr sdev (SDPowerOnAttempts (i+1))
      _ -> setStorageDeviceAttr sdev (SDPowerOnAttempts 1)

incrDiskPowerOffAttempts :: StorageDevice -> PhaseM LoopState l ()
incrDiskPowerOffAttempts sdev = do
    let _F (SDPowerOffAttempts _) = True
        _F _                           = False
    m <- findStorageDeviceAttr _F sdev
    case m of
      Just old@(SDPowerOffAttempts i) -> do
        unsetStorageDeviceAttr sdev old
        setStorageDeviceAttr sdev (SDPowerOffAttempts (i+1))
      _ -> setStorageDeviceAttr sdev (SDPowerOffAttempts 1)

incrDiskResetAttempts :: StorageDevice -> PhaseM LoopState l ()
incrDiskResetAttempts sdev = do
    let _F (SDResetAttempts _) = True
        _F _                        = False
    m <- findStorageDeviceAttr _F sdev
    case m of
      Just old@(SDResetAttempts i) -> do
        unsetStorageDeviceAttr sdev old
        setStorageDeviceAttr sdev (SDResetAttempts (i+1))
      _ -> setStorageDeviceAttr sdev (SDResetAttempts 1)

markOnGoingReset :: StorageDevice -> PhaseM LoopState l ()
markOnGoingReset sdev = do
    let _F SDOnGoingReset = True
        _F _                 = False
    m <- findStorageDeviceAttr _F sdev
    case m of
      Nothing -> setStorageDeviceAttr sdev SDOnGoingReset
      _       -> return ()

markResetComplete :: StorageDevice -> PhaseM LoopState l ()
markResetComplete sdev = do
    let _F SDOnGoingReset = True
        _F _                 = False
    m <- findStorageDeviceAttr _F sdev
    case m of
      Nothing  -> return ()
      Just old -> unsetStorageDeviceAttr sdev old

markDiskPowerOn :: StorageDevice -> PhaseM LoopState l ()
markDiskPowerOn sdev = do
    let _F SDPowered = True
        _F _              = False
    m <- findStorageDeviceAttr _F sdev
    case m of
      Nothing -> setStorageDeviceAttr sdev SDPowered
      _       -> return ()

markSMARTTestIsRunning :: StorageDevice -> PhaseM LoopState l ()
markSMARTTestIsRunning sdev = do
    let _F SDSMARTRunning = True
        _F _                   = False
    m <- findStorageDeviceAttr _F sdev
    case m of
      Nothing -> setStorageDeviceAttr sdev SDSMARTRunning
      _       -> return ()

markDiskPowerOff :: StorageDevice -> PhaseM LoopState l ()
markDiskPowerOff sdev = do
    let _F SDPowered = True
        _F _              = False
    m <- findStorageDeviceAttr _F sdev
    case m of
      Nothing  -> return ()
      Just old -> unsetStorageDeviceAttr sdev old

markSMARTTestComplete :: StorageDevice -> PhaseM LoopState l ()
markSMARTTestComplete sdev = do
    let _F SDSMARTRunning = True
        _F _                   = False
    m <- findStorageDeviceAttr _F sdev
    case m of
      Nothing  -> return ()
      Just old -> unsetStorageDeviceAttr sdev old

getDiskResetAttempts :: StorageDevice -> PhaseM LoopState l Int
getDiskResetAttempts sdev = do
    let _F (SDResetAttempts _) = True
        _F _                        = False
    m <- findStorageDeviceAttr _F sdev
    case m of
      Just (SDResetAttempts i) -> return i
      _                             -> return 0
