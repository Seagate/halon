-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE OverloadedStrings          #-}

module HA.RecoveryCoordinator.Actions.Hardware
  ( -- * Host related functions
    findHosts
  , findHostEnclosure
  , findNodeHost
  , locateHostInEnclosure
  , locateNodeOnHost
  , registerHost
  , nodesOnHost
    -- * Interface related functions
  , registerInterface
    -- * Drive related functions
  , driveStatus
  , findEnclosureStorageDevices
  , findHostLogicalDevices
  , findLogicalDeviceIdentifiers
  , findStorageDeviceIdentifiers
  , hasLogicalDeviceIdentifier
  , hasStorageDeviceIdentifier
  , identifyLogicalDevice
  , identifyStorageDevice
  , registerStorageDevice
  , registerLogicalDevice
  , locateLogicalOnStorageDevice
  , updateDriveStatus
) where

import HA.RecoveryCoordinator.Actions.Core
import qualified HA.ResourceGraph as G
import HA.Resources
import HA.Resources.Mero

import Control.Category ((>>>))
import qualified Control.Monad.State.Strict as State

import Network.CEP

import Text.Regex.TDFA ((=~))

----------------------------------------------------------
-- Host related functions                               --
----------------------------------------------------------

-- | Find the host running the given node
findNodeHost :: Node
             -> CEP LoopState (Maybe Host)
findNodeHost node = do
  cepLog "rg-query" $ "Looking for host running " ++ show node
  g <- State.gets lsGraph
  return $ case G.connectedFrom Runs node g of
    [h] -> Just h
    _ -> Nothing

-- | Find the enclosure containing the given host.
findHostEnclosure :: Host
                  -> CEP LoopState (Maybe Enclosure)
findHostEnclosure host = do
  cepLog "rg-query" $ "Looking for enclosure containing " ++ show host
  g <- State.gets lsGraph
  return $ case G.connectedFrom Has host g of
    [h] -> Just h
    _ -> Nothing

-- | Find a list of all hosts in the system matching a given
--   regular expression.
findHosts :: String
          -> CEP LoopState [Host]
findHosts regex = do
  cepLog "rg-query" $ "Looking for hosts matching regex " ++ regex
  g <- State.gets lsGraph
  return $ [ host | host@(Host hn) <- G.connectedTo Cluster Has g
                  , hn =~ regex]

-- | Find all nodes running on the given host.
nodesOnHost :: Host
            -> CEP LoopState [Node]
nodesOnHost host = do
  cepLog "rg-query" $ "Looking for nodes on host " ++ show host
  State.gets $ G.connectedTo host Runs . lsGraph

-- | Register a new host in the system.
registerHost :: Host
             -> CEP LoopState ()
registerHost host = do
  cepLog "rg" $ "Registering host: "
              ++ show host
  ls <- State.get
  let rg' = G.newResource host
        >>> G.connect Cluster Has host
          $ lsGraph ls
  State.put ls { lsGraph = rg' }

-- | Record that a host is running in an enclosure.
locateHostInEnclosure :: Host
                      -> Enclosure
                      -> CEP LoopState ()
locateHostInEnclosure host enc = do
  cepLog "rg" $ "Locating host "
              ++ show host
              ++ " in enclosure "
              ++ show enc
  ls <- State.get
  let rg' = G.connect enc Has host
          $ lsGraph ls
  State.put ls { lsGraph = rg' }

-- | Record that a node is running on a host.
locateNodeOnHost :: Node
                 -> Host
                 -> CEP LoopState ()
locateNodeOnHost node host = do
  cepLog "rg" $ "Locating node " ++ (show node) ++ " on host "
              ++ show host
  ls <- State.get
  let rg' = G.connect host Runs node
          $ lsGraph ls
  State.put ls { lsGraph = rg' }

----------------------------------------------------------
-- Interface related functions                          --
----------------------------------------------------------

-- | Register an interface on a host.
registerInterface :: Host -- ^ Host on which the interface resides.
                  -> Interface
                  -> CEP LoopState ()
registerInterface host int = do
  cepLog "rg" $ "Registering interface on host " ++ show host
  ls <- State.get
  let rg' = G.newResource host
        >>> G.newResource int
        >>> G.connect host Has int
          $ lsGraph ls
  State.put ls { lsGraph = rg' }

----------------------------------------------------------
-- Drive related functions                              --
----------------------------------------------------------

-- | Find logical devices on a host
findHostLogicalDevices :: Host
                       -> CEP LoopState [LogicalDevice]
findHostLogicalDevices host = do
  cepLog "rg-query" $ "Looking for logical devices on host "
                    ++ show host
  State.gets $ (G.connectedTo host Has) . lsGraph

-- | Find physical devices in an enclosure
findEnclosureStorageDevices :: Enclosure
                       -> CEP LoopState [StorageDevice]
findEnclosureStorageDevices enc = do
  cepLog "rg-query" $ "Looking for physical devices in enclosure "
                    ++ show enc
  State.gets $ (G.connectedTo enc Has) . lsGraph

-- | Find additional identifiers for a (logical) storage device.
findLogicalDeviceIdentifiers :: LogicalDevice
                             -> CEP LoopState [DeviceIdentifier]
findLogicalDeviceIdentifiers ld = do
  cepLog "rg-query" $ "Looking for identifiers for logical device "
                    ++ show ld
  State.gets $ (G.connectedTo ld Has) . lsGraph

-- | Find additional identifiers for a (physical) storage device.
findStorageDeviceIdentifiers :: StorageDevice
                             -> CEP LoopState [DeviceIdentifier]
findStorageDeviceIdentifiers sd = do
  cepLog "rg-query" $ "Looking for identifiers for physical device "
                    ++ show sd
  State.gets $ (G.connectedTo sd Has) . lsGraph

-- | Test if a drive have a given identifier
hasLogicalDeviceIdentifier :: LogicalDevice
                           -> DeviceIdentifier
                           -> CEP LoopState Bool
hasLogicalDeviceIdentifier ld di = do
  ids <- findLogicalDeviceIdentifiers ld
  return $ elem di ids

-- | Test if a drive have a given identifier
hasStorageDeviceIdentifier :: StorageDevice
                           -> DeviceIdentifier
                           -> CEP LoopState Bool
hasStorageDeviceIdentifier ld di = do
  ids <- findStorageDeviceIdentifiers ld
  return $ elem di ids

-- | Add an additional identifier to a logical storage device.
identifyLogicalDevice :: LogicalDevice
                      -> DeviceIdentifier
                      -> CEP LoopState ()
identifyLogicalDevice ld di = do
  cepLog "rg" $ "Adding identifier "
              ++ show di
              ++ " to device "
              ++ show ld
  ls <- State.get
  let rg' = G.newResource ld
        >>> G.newResource di
        >>> G.connect ld Has di
          $ lsGraph ls
  State.put ls { lsGraph = rg' }

-- | Add an additional identifier to a logical storage device.
identifyStorageDevice :: StorageDevice
                      -> DeviceIdentifier
                      -> CEP LoopState ()
identifyStorageDevice ld di = do
  cepLog "rg" $ "Adding identifier "
              ++ show di
              ++ " to device "
              ++ show ld
  ls <- State.get
  let rg' = G.newResource ld
        >>> G.newResource di
        >>> G.connect ld Has di
          $ lsGraph ls
  State.put ls { lsGraph = rg' }

-- | Register a new drive in the system.
registerStorageDevice :: Enclosure
                      -> StorageDevice
                      -> CEP LoopState ()
registerStorageDevice enc dev = do
  cepLog "rg" $ "Registering storage device: "
              ++ show dev
              ++ " in enclosure "
              ++ show enc
  ls <- State.get
  let rg' = G.newResource enc
        >>> G.newResource dev
        >>> G.connect Cluster Has enc
        >>> G.connect enc Has dev
          $ lsGraph ls
  State.put ls { lsGraph = rg' }

-- | Register a logical device in the system.
registerLogicalDevice :: Host
                      -> LogicalDevice
                      -> CEP LoopState ()
registerLogicalDevice host dev = do
  cepLog "rg" $ "Registering logical device: "
              ++ show dev
              ++ " on host "
              ++ show host
  ls <- State.get
  let rg' = G.newResource host
        >>> G.newResource dev
        >>> G.connect host Has dev
          $ lsGraph ls
  State.put ls { lsGraph = rg' }

-- | Locate a logical storage device as being hosted on a physical device.
locateLogicalOnStorageDevice :: LogicalDevice
                             -> StorageDevice
                             -> CEP LoopState ()
locateLogicalOnStorageDevice ld sd = do
  cepLog "rg" $ "Locating logical device "
              ++ show ld
              ++ " on physical device "
              ++ show sd
  ls <- State.get
  let rg' = G.connect ld On sd
          $ lsGraph ls
  State.put ls { lsGraph = rg' }


-- | Get the status of a storage device.
driveStatus :: StorageDevice
            -> CEP LoopState (Maybe StorageDeviceStatus)
driveStatus dev = do
  cepLog "rg-query" $ "Querying status of device " ++ show dev
  ls <- State.get
  return $ case G.connectedTo dev Is (lsGraph ls) of
    [a] -> Just a
    _ -> Nothing

-- | Update the status of a storage device.
updateDriveStatus :: StorageDevice
                  -> String
                  -> CEP LoopState ()
updateDriveStatus dev status = do
  cepLog "rg" $ "Updating status for device " ++ show dev ++ " to " ++ status
  ls <- State.get
  ds <- driveStatus dev
  cepLog "rg" $ "Old status was " ++ show ds
  let statusNode = StorageDeviceStatus status
      removeOldNode = case ds of
        Just f -> G.disconnect dev Is f
        Nothing -> id
      rg' = G.newResource statusNode
        >>> G.connect dev Is statusNode
        >>> removeOldNode
          $ lsGraph ls
  State.put ls { lsGraph = rg' }
